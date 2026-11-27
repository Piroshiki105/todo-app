#!/usr/bin/env bash
# 課金を止めるため、GKE クラスタと Spanner インスタンスを削除する。
# Spanner のデータは消える。残るもの: Artifact Registry のイメージ、サービスアカウント、IAM、Git リポジトリ。
#
# 使い方: ./scripts/down.sh        （確認プロンプトあり）
#         ./scripts/down.sh -y     （確認なし）
set -euo pipefail
# shellcheck source=env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

cat <<EOF
次のリソースを削除します。
  プロジェクト       : $PROJECT_ID
  GKE クラスタ       : $CLUSTER ($REGION)
  Spanner インスタンス: $SPANNER_INSTANCE （DB $SPANNER_DB のデータも消える）
EOF

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "本当に削除しますか？ 'yes' と入力してください: " answer
  [[ "$answer" == "yes" ]] || { echo "中止しました。"; exit 1; }
fi

log "GKE クラスタを削除"
if cluster_exists; then
 echo  gcloud container clusters delete "$CLUSTER" --region "$REGION" --quiet
else
  echo "クラスタ $CLUSTER は存在しません（スキップ）"
fi

log "Spanner インスタンスを削除"
if spanner_instance_exists; then
  gcloud spanner instances delete "$SPANNER_INSTANCE" --quiet
else
  echo "Spanner インスタンス $SPANNER_INSTANCE は存在しません（スキップ）"
fi

log "完了。念のため残りを確認してください"
echo "  gcloud container clusters list"
echo "  gcloud spanner instances list"
