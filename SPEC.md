# todo-app インターフェース仕様

アプリ（Go）と k8s / ArgoCD 定義の間の取り決め。変更する場合は必ず合意を取ること。

## コンテナ
- イメージ: `asia-northeast1-docker.pkg.dev/PROJECT_ID/todo-app/todo-app:latest`（PROJECT_ID は仮置き）
- リッスンポート: `8080`（HTTP）
- 実行ユーザー: 非 root、読み取り専用ルートFS で動作可能

## 環境変数
| 名前 | 内容 | 例 |
|---|---|---|
| `SPANNER_DATABASE` | Spanner データベースの完全修飾名 | `projects/PROJECT_ID/instances/todo-instance/databases/todo-db` |
| `PORT` | 省略時 `8080` | `8080` |

## ヘルスチェック
- `GET /healthz` → 200（プロセス生存のみ。liveness 用）
- `GET /readyz` → 200（Spanner へ疎通できる場合のみ。readiness 用）

## HTTP エンドポイント（参考）
- `GET /` HTML 画面
- `GET /api/todos` / `POST /api/todos` / `PATCH /api/todos/{id}` / `DELETE /api/todos/{id}`

## 認証（Spanner）
- Workload Identity を使用。キーファイルは使わない。
- Kubernetes ServiceAccount 名: `todo-app`（namespace: `todo-app`）
- ServiceAccount のアノテーション `iam.gke.io/gcp-service-account: todo-app@PROJECT_ID.iam.gserviceaccount.com`（仮置き）
- GCP 側の SA には `roles/spanner.databaseUser` を付与する（README で手順化）

## k8s
- namespace: `todo-app`
- Deployment / Service / ServiceAccount の名前はすべて `todo-app`
- Service: ClusterIP、port `80` → targetPort `8080`
- レプリカ数: 2、requests/limits を設定する
- ラベル: `app.kubernetes.io/name: todo-app`

## ArgoCD
- Application 名: `todo-app`、namespace: `argocd`
- 参照元: `repoURL`（仮置き `TODO`）、`path: k8s`、`targetRevision: main`
- 同期: automated（prune / selfHeal 有効）、`CreateNamespace=true`
