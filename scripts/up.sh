#!/usr/bin/env bash
# Spanner、GKE (Autopilot)、Workload Identity、ArgoCD、Application を一括で立ち上げる。
# 何度実行しても安全（存在するものは作り直さない）。所要時間の目安は 10〜15 分。
#
# 前提: gcloud にログイン済み、kubectl / helm が入っていること。
#       Artifact Registry にイメージが push 済みであること（README 参照）。
set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

log "API を有効化"
gcloud services enable spanner.googleapis.com container.googleapis.com \
  artifactregistry.googleapis.com

log "サービスアカウント $GSA_NAME を確認"
if ! gcloud iam service-accounts describe "$GSA" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$GSA_NAME" --display-name "$GSA_NAME"
fi

log "Spanner インスタンス $SPANNER_INSTANCE を確認"
if ! spanner_instance_exists; then
  gcloud spanner instances create "$SPANNER_INSTANCE" \
    --config "regional-$REGION" --description "todo" --processing-units "$SPANNER_PU"
fi

log "Spanner DB $SPANNER_DB を確認"
if ! spanner_db_exists; then
  gcloud spanner databases create "$SPANNER_DB" --instance "$SPANNER_INSTANCE" \
    --ddl "$(cat "$ROOT_DIR/schema.sql")"
fi

log "Spanner DB への権限を付与（DB を作り直すとバインドも消えるため毎回実行）"
gcloud spanner databases add-iam-policy-binding "$SPANNER_DB" \
  --instance "$SPANNER_INSTANCE" \
  --member "serviceAccount:$GSA" --role roles/spanner.databaseUser >/dev/null

log "GKE クラスタ $CLUSTER を確認"
if ! cluster_exists; then
  gcloud container clusters create-auto "$CLUSTER" --region "$REGION"
fi
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"

# Identity Pool はクラスタ作成後に存在するようになるため、クラスタの後で設定する
log "Workload Identity: k8s ServiceAccount (todo-app/todo-app) が GSA を借用できるようにする"
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[todo-app/todo-app]" >/dev/null

log "ArgoCD を Helm でインストール"
helm dependency update "$ROOT_DIR/argocd/install"
helm upgrade --install argocd "$ROOT_DIR/argocd/install" \
  -n argocd --create-namespace --wait --timeout 10m

log "Application を登録"
kubectl apply -f "$ROOT_DIR/argocd/application.yaml"

log "todo-app のデプロイを待機（最大 10 分）"
for _ in $(seq 1 60); do
  if kubectl -n todo-app get deploy todo-app >/dev/null 2>&1; then
    kubectl -n todo-app rollout status deploy/todo-app --timeout=600s
    break
  fi
  sleep 10
done

log "完了"
cat <<EOF
  kubectl -n todo-app get pods
  kubectl -n todo-app port-forward svc/todo-app 8080:80      # → http://localhost:8080
  kubectl -n argocd port-forward svc/argocd-server 8081:443  # → https://localhost:8081 (admin)
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF
