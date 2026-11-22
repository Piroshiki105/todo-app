# todo-app

GKE + Cloud Spanner で動く簡単な TODO アプリ（Go）。デプロイは ArgoCD（GitOps）。
インターフェース仕様は [SPEC.md](SPEC.md) を参照。

```
.
├── main.go, web/index.html   アプリ本体（HTML 画面付き）
├── schema.sql                Spanner の DDL
├── Dockerfile
├── k8s/                      素の Kubernetes マニフェスト（ArgoCD が同期）
└── argocd/application.yaml   ArgoCD Application
```

## 1. ローカルで動かす（Spanner エミュレータ）

```bash
# エミュレータ起動（gRPC: 9010 / REST: 9020）
docker run -d --rm --name spanner-emu -p 9010:9010 -p 9020:9020 \
  gcr.io/cloud-spanner-emulator/emulator

# インスタンスと DB を作成（gcloud 不要）
B=localhost:9020/v1/projects/test-project
curl -s -X POST $B/instances -H 'Content-Type: application/json' -d \
 '{"instanceId":"todo-instance","instance":{"config":"projects/test-project/instanceConfigs/emulator-config","displayName":"todo","nodeCount":1}}'
DDL=$(python3 -c "import json;print(json.dumps(open('schema.sql').read().strip().rstrip(';')))")
curl -s -X POST $B/instances/todo-instance/databases -H 'Content-Type: application/json' -d \
 "{\"createStatement\":\"CREATE DATABASE \`todo-db\`\",\"extraStatements\":[$DDL]}"

# アプリ起動 → http://localhost:8080
SPANNER_EMULATOR_HOST=localhost:9010 \
SPANNER_DATABASE=projects/test-project/instances/todo-instance/databases/todo-db \
go run .
```

## 2. GCP の準備

以下の `PROJECT_ID` と `REGION` は自分の環境に置き換える。

```bash
export PROJECT_ID=your-project REGION=asia-northeast1
gcloud config set project $PROJECT_ID
gcloud services enable spanner.googleapis.com container.googleapis.com artifactregistry.googleapis.com
```

### Spanner

```bash
# 動作確認用の最小構成（100 processing units）。課金されるので不要になったら削除する
gcloud spanner instances create todo-instance \
  --config=regional-$REGION --description="todo" --processing-units=100
gcloud spanner databases create todo-db --instance=todo-instance \
  --ddl="$(cat schema.sql)"
```

### Artifact Registry とイメージ

```bash
gcloud artifacts repositories create todo-app --repository-format=docker --location=$REGION
gcloud auth configure-docker $REGION-docker.pkg.dev
IMAGE=$REGION-docker.pkg.dev/$PROJECT_ID/todo-app/todo-app:latest
docker build -t $IMAGE . && docker push $IMAGE
```

### GKE（Workload Identity 有効）

```bash
gcloud container clusters create-auto todo-cluster --region=$REGION
gcloud container clusters get-credentials todo-cluster --region=$REGION
```

Autopilot は Workload Identity が標準で有効。Standard クラスタの場合は
`--workload-pool=$PROJECT_ID.svc.id.goog` を付けて作成する。

### Workload Identity（キーファイルを使わず Spanner に接続）

```bash
gcloud iam service-accounts create todo-app
GSA=todo-app@$PROJECT_ID.iam.gserviceaccount.com

# Spanner の DB に対する権限（プロジェクト全体ではなく DB 単位で付与）
gcloud spanner databases add-iam-policy-binding todo-db --instance=todo-instance \
  --member="serviceAccount:$GSA" --role=roles/spanner.databaseUser

# k8s の ServiceAccount (todo-app/todo-app) が GSA を借用できるようにする
gcloud iam service-accounts add-iam-policy-binding $GSA \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[todo-app/todo-app]"
```

## 3. 仮置きの値を置き換える

| ファイル | 置き換える値 |
|---|---|
| `k8s/deployment.yaml` | `PROJECT_ID`（image、`SPANNER_DATABASE`） |
| `k8s/serviceaccount.yaml` | `PROJECT_ID`（`iam.gke.io/gcp-service-account`） |
| `argocd/application.yaml` | `repoURL: TODO` → このリポジトリの URL |

```bash
sed -i "s/PROJECT_ID/$PROJECT_ID/g" k8s/*.yaml
```

置き換えたら Git に push する（ArgoCD は Git の内容を同期する）。

## 4. ArgoCD でデプロイ

ArgoCD がクラスタに未導入の場合:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Application を登録する:

```bash
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application todo-app
```

private リポジトリの場合は、先に ArgoCD にリポジトリの認証情報を登録する。
同期後、`todo-app` namespace に Deployment / Service / ServiceAccount が作られる。

## 5. 動作確認

Service は ClusterIP なので、まず port-forward で確認する。

```bash
kubectl -n todo-app port-forward svc/todo-app 8080:80
# → http://localhost:8080
```

外部公開が必要な場合は、Ingress（または Gateway）を別途追加する。

## 注意

- `image: ...:latest` は動作確認向け。実運用ではタグ（コミット SHA など）を固定し、
  マニフェストのタグを更新して ArgoCD に同期させる。
- Spanner インスタンスは起動しているだけで課金される。不要になったら
  `gcloud spanner instances delete todo-instance` で削除する。
