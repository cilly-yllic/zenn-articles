---
title: "払い出したあとを同期する — Cloudflare DNS・Logto・証明書ゲート付き proxy・env bundle"
emoji: "🔄"
type: "tech"
topics: ["gcp", "cloudflare", "githubactions", "firebase", "logto"]
published: true
---

[settings.yml 一枚で GCP / Firebase 環境を払い出す](https://zenn.dev/cilly/articles/config-driven-gcp-provisioning) で、設定ファイルから GCP Project と Firebase Platform が自動で出来上がるところまでを書きました。ただ、それで終わりではありません。env を 1 つ増やすと、土台の外側にもやることが芋づる式に出てきます。

- Cloudflare に **DNS レコード**を足し、Firebase の custom domain に向ける
- 配信が安定したら **proxy を ON** にして CDN / WAF を効かせる
- 管理コンソール用に **Logto** の Application / API Resource / Role を整える
- 各アプリの **env 値**を集めて暗号化し、デプロイから参照できる形にする

これらは provisioning とは別レイヤーですが、放っておけば結局「env ごとの手作業」に逆戻りします。そこで、土台と同じ **設定 (source of truth) に追従させる** ための Platform Sync という仕組みを組みました。

# 全体像

![Platform Sync パイプラインの構成図](/images/platform-sync-pipeline-architecture.png)
*設定 (Git) を SoT に、Cloudflare DNS → Logto → proxy → env bundle までを一連の dispatch で繋ぎます。*

SoT は 2 枚です。`terraform.yml` が service / environments / hosting（＝ドメインと DNS の出どころ）を持ち、`platform.yml` が Logto の認証ルールと「tenant ⇄ env_group の対応」を持ちます。Platform Sync 本体は `workflow_dispatch` の手動発火で、既定は `plan`（差分表示のみ）。事故を防ぐため、実書き込みの `apply` は明示的に選んだときだけ走ります。

```yaml
# platform.yml (抜粋・抽象化)
tenants:
  - key: my-service-non-production
    env_groups: [dev, stg]      # この tenant が面倒を見る env のまとまり
    roles:
      - { name: admin, scopes: [secrets:read, secrets:write] }
      - { name: developer, scopes: [secrets:read] }
```

処理は `Cloudflare DNS → Logto` の順です。Logto の `redirectUri` はドメイン（＝DNS / hosting）に依存するので、`apply` では Cloudflare を先行させます。そして **`apply` が成功したときだけ**、後続の 2 つのワークフロー（Cloudflare Proxy / Env Bundle）を `dispatch` します。認証はすべて keyless で、各 env の read-only Service Account を Workload Identity Federation (OIDC) で impersonate します。長期クレデンシャルはどこにも置きません。

# 既定は「消さない」

`plan` と `apply` は同じ差分計算を共有し、mode で「表示だけ / 実書き込み」を切り替えます。ここで効いているのは、**env 単位の同期では削除を一切出さない**という判断です。

Cloudflare の desired は Firebase が要求する DNS 更新から作ります。ところがこの要求は、ドメインが ACTIVE になると満たされて空になります。つまり「いま存在するが desired に無いレコード」を素朴に消すと、**配信中のレコードを巻き込む**恐れがあります。だから env 単位の sync は不足分の作成だけを行い、削除は別の `reconcile` ジョブに分離しました。reconcile は env の命名規約（`<tier>-<番号>` 形）と tier 制約でマッチさせ、定義済み env と `retained_envs` に無いものだけを削除候補にします。`www` や `api` のような無関係レコードを誤検出しないための線引きです。

削除はいつでも危険なので、`allow_delete` を立てたときだけ有効になり、`plan` では「何が消えるか」をプレビューするに留めます。

# 山場：証明書が出るまで proxy を ON にしない

このパイプラインで一番気を遣ったのが、proxy の切り替えタイミングです。

![証明書 ACTIVE を待ってから proxy ON にする流れ](/images/cloudflare-cert-gated-proxy.png)
*DNS-only で作る → Firebase に cert を出させる → ACTIVE を待つ → 配信レコードだけ proxy ON。順序に意味があります。*

DNS レコードは**必ず `proxied: false`（DNS-only、グレークラウド）で作成**します。この状態だと、Firebase はドメイン所有権の検証と証明書発行のために、オリジンへ直接アクセスできます。もしここで proxy を ON にしてしまうと、検証や ACME challenge の通信が Cloudflare のプロキシ（別の証明書・別の IP）の裏に隠れ、**証明書が発行できず配信が壊れます**。

そこで Cloudflare Proxy ワークフローは、Firebase custom domain の host / cert 状態を 15 秒間隔でポーリングします。`HOST_ACTIVE && CERT_ACTIVE`（配布中の `CERT_PROPAGATING` も「発行済み＝疎通あり」とみなす）になってから、**hostname 自身を指す配信レコードだけ**を `proxied: true` に更新します。所有権 TXT や ACME challenge の CNAME は DNS-only のまま残します。

証明書の発行には時間がかかります。だからこの段を本体に埋め込まず、**独立したワークフローに切り出して後から再実行できる**ようにしました。pending でタイムアウトしても失敗にはせず、もう一度回せば続きから ACTIVE を待ちます。すでに proxied なレコードはスキップするので、何度流しても安全です。

# Logto：ドメインに依存する認証設定

Logto 側は tenant 単位で同期します。Management API へは M2M アプリの資格情報で `client_credentials` を取り、トークンを使い回します。同期するのは 3 種類です。

- **API Resources**（＋ scope / permission）
- **Roles**（＋ scope の割り当て）
- **Applications**（管理コンソール用の SPA）

書き込みには順序の制約があります。Role に scope を割り当てるには Resource 側の scope id が要るので、**API Resources → Roles → Applications** の順で進めます。

Application の `redirectUri` は、env のドメインから組み立てます（`https://<domain>/callback` など）。対象ドメインを `platform.yml` に列挙するのではなく、`terraform.yml` の hosting 定義から導出するのがポイントです。これが「`apply` で Cloudflare を先に回す」理由でもあります — ドメインが先に確定していないと、正しい `redirectUri` を作れません。削除はここでも保守的で、`<service>-` で始まり `-web-system-console` で終わる、自分が管理している Application 以外は orphan 扱いしません。

# env bundle と GPG：argv に乗せない

最後が env 値の束ね方です。env ごとに値ソース（Firebase web app config や Logto app id を含む JSON）を生成し、tar に固めて **GPG 対称暗号**で `.tar.gpg` にします。暗号化済みの bundle は commit し、復号後の平文 JSON は gitignore します。「鍵そのもの」だけを CI Secret に置く形です。

```bash
# passphrase は環境変数で受け取り、プロセス置換で fd 3 にだけ流す
set -o pipefail
tar cf - "$src" | gpg -c --batch --yes --pinentry-mode loopback \
  --passphrase-fd 3 -o "$out" 3< <(printf %s "$PASSPHRASE")
```

地味ですが大事なのが passphrase の渡し方です。コマンドライン引数に書くと `ps` で見えてしまうので、**プロセス置換で fd 3 に流し込み、`--passphrase-fd 3` で読ませます**。`printf` は bash 組み込みなので、独立プロセスにすらなりません。argv にも別プロセスにも passphrase が現れない経路です。

もう一つの工夫は diff です。GPG 暗号は**毎回バイト列が変わる**ので、bundle をそのまま git diff すると中身が同じでも常に差分が出て、無意味な PR が量産されます。そこで、既存 bundle を一度**復号して平文同士を比較**し、実際に値が変わったとき（または bundle が無いとき）だけ再暗号化します。PR も固定ブランチへ force-push する形にして、open PR があれば更新、無ければ新規作成と、重複しないようにしています。

# 開発者は秘密を持たない

この構成のいちばんの勘所は、**開発者が dev 環境の env 値も復号鍵も一度も手にしないまま、デプロイまで到達できる**ことです。値ソースを生成するのも、GPG で暗号化するのも、デプロイ時に復号するのも、すべて CI の中で完結します。passphrase は CI Secret として CI だけが保持し、Git に乗るのは暗号化済みの `.tar.gpg` だけ。値ソースの平文は generate の過程で CI のランナー上にしか現れず、gitignore されているので commit もされません。

つまり、開発者が普段触るのは設定（`terraform.yml` / `platform.yml`）と、出来上がった暗号化 bundle だけです。「dev の秘密を誰のローカルにも置かない」が、運用ルールやレビューの努力ではなく、**仕組みとして担保**されます。秘密の配布経路が存在しないので、配布段階での漏洩や、各自のマシンに散らばった古い `.env` がいつの間にか食い違う、といった事故そのものが起こりません。keyless（WIF）でクラウドへの長期クレデンシャルを無くしたのと同じ発想を、アプリの env 値にも広げた形です。

# 効いている設計判断

**keyless を存在判定にも流用しています。** 不要になった env の bundle を掃除するとき、「その GCP Project がまだあるか」を、read-only SA を `access_token` 付きで impersonate してみて成否で判定します。Project / SA が消えていれば impersonate に失敗するので、それを「存在しない」のシグナルに使います（`token_format` を付けないと認証は設定を書くだけで常に成功してしまい、判定になりません — そこだけ注意が要ります）。

**重い処理を独立ワークフローに切り出しています。** 証明書発行の待ちは本体から分離し、DNS 変更があった env だけを後続に渡します。変更ゼロのときは proxy ワークフローを起動すらしません。

# 何を捨てたか

代償は、ワークフローの `dispatch` 連鎖が増えることです。`apply` → proxy / env-bundle という分岐は、見通しの良さと引き換えに「どこで止まったか」を追う手間を生みます。Cloudflare・Logto・Firebase・GitHub Actions と関係者が多いぶん、失敗の切り分けも単一システムより難しくなります。

それでも、env を 1 つ増やすコストが「設定に数行足して `apply` を回す」に収束したことの価値は大きいです。[前回](https://zenn.dev/cilly/articles/config-driven-gcp-provisioning)は土台を設定から払い出しました。今回はその外側 — DNS・認証・配信・env — も同じ設定に追従させました。インフラを「書いて生成するもの」に倒しきると、運用の関心事は個々の環境から、生成して同期する仕組みそのものへと移っていきます。

<!-- sync: redeploy trigger -->
