---
title: "settings.yml 一枚で GCP / Firebase 環境を払い出す"
emoji: "🏗️"
type: "tech"
topics: ["gcp", "firebase", "terraform", "githubactions"]
published: true
---

GCP と Firebase でサービスを増やすたびに、同じ手作業が繰り返されます。Project を作り、Billing を紐付け、API を有効化し、Terraform 実行用の Service Account と Workload Identity を整え、Firestore / Auth / Storage / App Hosting を設定します。env (dev / stg / prd) の数だけこれを掛け算します。手順書をどれだけ丁寧に書いても、人の手が入る限り環境差は生まれます。

そこで、**サービスごとに `settings.yml` を一枚置けば、あとは全部自動で払い出される** 基盤を組みました。設定が source of truth で、インフラはその投影でしかない、という形にしています。

# 何が出来上がるのか

まずは「生成される側」の全体像から見ていきます。

![マルチ環境 GCP / Firebase 基盤の構成図](/images/multi-environment-gcp-firebase-platform-architecture.png)
*共有 Bootstrap プロジェクトを起点に、env ごとのサービスプロジェクトへ keyless で権限を貸します。*

構造は 3 層になっています。

- **Identity & Trust** — Terraform Cloud と GitHub Actions は、Workload Identity Federation (OIDC) で GCP を操作します。Service Account の鍵ファイルは一切発行しません。
- **共有 Bootstrap プロジェクト** — WIF Pool / Provider、Terraform 実行用 SA、後述の Cloud Run Router、Secret Manager をまとめた「基盤の基盤」です。組織に一度だけ作ります。
- **env ごとのサービスプロジェクト** — `my-service-dev-001` のように env 単位で独立した GCP Project です。中に Firebase (Auth / Firestore / Storage / App Hosting / Data Connect / Functions …) が機能フラグに応じて並びます。

鍵を持たないことが効いています。各 env の Terraform SA は Bootstrap の SA から **impersonate** され、その権限は OIDC のトークン交換でしか発火しません。漏れて困る長期クレデンシャルがどこにも存在しません。

# どうやって生成するのか

次は「生成する側」です。`settings.yml` の merge から GCP への apply までを、ポーリングなしの連鎖で繋ぎます。

![インフラ自動生成パイプラインの構成図](/images/gcp-firebase-platform-architecture.png)
*1 本の設定ファイルが、GitHub Actions → Terraform Cloud → GCP まで一直線に流れます。*

流れは大きく 2 段です。

```yaml
# service repo の terraform/settings.yml (抜粋)
service: my-service
environments:
  dev-001:
    labels: [tier:dev]
    firebase_platform:
      firebase: true
      firestore: true
      app_hosting:
        - { backend_id: web, location: asia-northeast1 }
      notifications:
        - url: https://hooks.slack.com/services/...  # apply 結果を通知
```

1. **Action A (project-bootstrap)** が `settings.yml` を読み、`status` / `labels` で対象 env を絞り、**1 Run でまとめて** GCP Project / SA / WIF を作ります。
2. その Run の完了通知 (HMAC 署名付き) を **Cloud Run Router** が受け、検証してから GitHub の `repository_dispatch` を発火します。
3. それをトリガーに **Action B (firebase-platform)** が起動し、env ごとの Workspace を立てて Firebase リソースを apply します。

ポーリングするオーケストレーターを常駐させる代わりに、Terraform Cloud の通知 → Cloud Run → GitHub という webhook の連鎖にしました。状態を知っているのは TFC だけなので、結果通知も apply の成否を知っている TFC から Slack に送らせています。

# 効いている設計判断

**機能フラグが API と IAM まで決めます。** `settings.yml` に `firestore: true` と書けば、対応する API 有効化・リソース作成・CI SA への role 付与までが芋づる式に決まります。逆に未指定なら何も作りません (zero side-effect)。利用者は「どの GCP API が要るか」を覚える必要がありません。

**設定の所有権はサービスチームに置きます。** どの機能を使うかはアプリの都合なので、`settings.yml` はサービス側リポジトリに置き、基盤側はそれを読むだけにしました。基盤が中央集権的に全サービスの構成を抱え込みません。

**削除の安全網を別に持ちます。** env を設定から消すと基本は destroy されますが、`retained_envs` に名前があれば state からだけ外して GCP リソースは残します。本番を設定ミスで巻き込みません。

# 何を捨てたか

代償もあります。webhook の連鎖は、間に Cloud Run Router という運用対象を 1 つ増やします。HMAC secret のローテーションや、通知が落ちたときの再実行経路を考える必要があります。Terraform Cloud / GitHub Actions / GCP の三者にまたがるので、失敗の切り分けは単一リポジトリより難しくなります。

それでも、env を 1 つ増やすコストが「`settings.yml` に数行足して Action を回すだけ」に収束したことの価値は大きいです。手作業の差分が構造的に消え、誰がやっても同じ環境が出来ます。インフラを「書いて生成するもの」に倒しきると、運用の関心事は個々の環境から、生成する仕組みそのものへと移っていきます。

# 公開先

この基盤は OSS として公開しています。Terraform Module と GitHub Actions のモノレポで、誰でも利用できます。

https://github.com/cilly-yllic/terraform-google-platform

https://registry.terraform.io/modules/cilly-yllic/platform/google/latest

:::message
以前書いた [Firebase ProjectをTerraformを使って管理](https://zenn.dev/cilly/articles/a405afee95c515) では、gcloud + Makefile で下準備をして Terraform Cloud で Run する構成を紹介していました。本記事はそこから「設定ファイルを SoT に、払い出しまで全部自動化する」方向へ進めた内容です。
:::
