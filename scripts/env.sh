#!/usr/bin/env bash
# up.sh / down.sh 共通の設定。環境変数で上書きできる（例: CLUSTER=foo ./scripts/up.sh）。

PROJECT_ID="${PROJECT_ID:-project-ebce5089-f7cd-4559-89a}"
REGION="${REGION:-asia-northeast1}"
CLUSTER="${CLUSTER:-todo-cluster}"
SPANNER_INSTANCE="${SPANNER_INSTANCE:-todo-instance}"
SPANNER_DB="${SPANNER_DB:-todo-db}"
SPANNER_PU="${SPANNER_PU:-100}"   # processing units（100 が最小）
GSA_NAME="${GSA_NAME:-todo-app}"
GSA="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# gcloud の既定プロジェクトに依存しないよう、このスクリプト内ではこのプロジェクトを使う
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

log() { printf '\n==> %s\n' "$*"; }

cluster_exists() {
  gcloud container clusters describe "$CLUSTER" --region "$REGION" >/dev/null 2>&1
}
spanner_instance_exists() {
  gcloud spanner instances describe "$SPANNER_INSTANCE" >/dev/null 2>&1
}
spanner_db_exists() {
  gcloud spanner databases describe "$SPANNER_DB" --instance "$SPANNER_INSTANCE" >/dev/null 2>&1
}
