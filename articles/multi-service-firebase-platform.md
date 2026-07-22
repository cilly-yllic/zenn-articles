---
title: "マルチサービス Firebase 環境のランタイムとデリバリ"
emoji: "🗺️"
type: "tech"
topics: ["firebase", "gcp", "nx", "cloudrun", "firestore"]
published: true
---

1 つの GCP プロジェクトに複数のサービスを同居させた Firebase / GCP 環境を設計しました。ここではプロダクト固有の話は省き、構成そのものを「どう動くか（ランタイム）」と「どう届けるか（デリバリ）」の 2 つの断面から紹介します。

# ランタイム: 書き込みと読み取りを分ける

![ランタイム構成とデータフロー](/images/runtime-architecture-and-data-flow.png)
*書き込みは SQL（SoT）へ、読み取りは Firestore（再生成可能なキャッシュ）から。バックエンドが両者を同時に更新し、reconciliation が整合性を担保します。*

この環境の中心にあるのは、**書き込みと読み取りを別のデータストアに分ける**設計です。書き込みはバックエンド (Next.js / Cloud Run) が受け、SoT (Firebase Data Connect 経由の Cloud SQL) と Firestore を同じ処理で両方更新します。Cloud SQL が source of truth、Firestore は SoT から再生成できる**読み取り専用キャッシュ**です。クライアントは Firestore を `onSnapshot` で stream しているので、自分の書き込みも即座に反映されます。二重書き込みのズレは、DB 更新より先に enqueue しておいた reconciliation ジョブが SoT を正として修復します。

この「Firestore を SoT ではなくキャッシュとして扱う」判断の利点と代償は、別記事で掘り下げているので、ここでは深入りしません。

https://zenn.dev/cilly/articles/firestore-as-public-cache

本記事で伝えたいのは、この読み書き分離を**複数サービスが同居する 1 つの GCP プロジェクト**の上で成立させている、残り 2 つの構造です。

## 2 層 DB: Core と Service

データベースは **2 層**になっています。identity / 組織 / メンバーシップといった横断的な基盤エンティティを持つ **Core DB** と、各サービス固有の domain エンティティを持つ **Service DB** です。これが Cloud SQL と Firestore の両方で同じ形で繰り返されます。

Service DB は Core の識別子を参照するだけで、共有データを二重には持ちません。複数サービスを 1 プロジェクトに同居させると identity 周りが散らかりがちですが、この境界があるおかげで「どのサービスから見てもユーザーと組織の出どころは Core だけ」という状態を保てます。サービスを増やすときも、足すのは Service DB だけです。

## 認証は 2 本立て

認証も 1 つではありません。**エンドユーザー向けのアプリは Firebase Authentication**、**運営向けの管理コンソールは外部の OIDC IdP** で認証します。

後者は Firebase Auth 前提の `onCall` が使えないため、Cloud Functions を `onRequest` で公開し、関数側で JWT を JWKS 検証 + スコープ認可します。2 つの認証ドメインが、物理的に別経路で同居している形です。「エンドユーザーと運営で信頼の出どころを分けたい」とき、Firebase Auth に寄せて custom claims で頑張るのではなく、経路ごと分けてしまう方が境界としては明確でした。

# デリバリ: モノレポから環境ごとに撒く

![モノレポからのマルチターゲットデプロイ構成](/images/nx-monorepo-deployment-architecture.png)
*1 つの Nx モノレポから、鍵を持たない CI が env ごとの GCP プロジェクトへ fan-out します。*

動かし方の裏側にあるのが、**1 つの Nx モノレポから複数のデプロイ先へ撒く CI** です。

- モノレポにはサービスごとに API (Cloud Functions) / Web (SSR or SPA) / Security Rules / Data Connect スキーマが並びます。Nx が影響のあるアプリだけをビルドします。
- CI (GitHub Actions) は**鍵を持ちません**。Workload Identity Federation (OIDC) で GCP を操作し、デプロイ用 Service Account を impersonate します。SA 鍵ファイルをパイプラインに置きません。
- `firebase deploy` が、env ごとの GCP プロジェクトの各ターゲット（Cloud Functions / App Hosting / Hosting / Firestore rules・indexes / Storage rules / Data Connect スキーマ）に **fan-out** します。env はテンプレート化した設定で切り替えます。
- プロジェクト・IAM・WIF・API 有効化・Firebase Auth は、デプロイより前に **Terraform でプロビジョニング済み**です。「環境を作る」レイヤーと「コードを撒く」レイヤーを分けています。

この「環境を作る」側（Terraform + GitHub Actions で GCP / Firebase を払い出す）の仕組みは、別記事にまとめています。

https://zenn.dev/cilly/articles/config-driven-gcp-provisioning

# 効いている判断

**読み書き分離。** 関連の整合的な更新やリレーショナルな制約は SQL に任せ、realtime push は Firestore に任せます。Firestore を「壊れても rebuild できるキャッシュ」と割り切ると、読み取り側のデータモデルを自由に作れます。

**1 プロジェクト同居 + 2 層 DB。** 複数サービスを 1 GCP プロジェクトに置くと、共有 identity やランタイム（Functions の codebase）を素直に共存させられます。Core / Service の 2 層構造が、その同居を破綻させない境界として効きます。

**keyless。** SA 鍵ファイルを発行しないことで、漏えいする長期秘密がパイプラインから消えます。CI も TFC も、その瞬間だけ OIDC で権限を借ります。

# 締め

紹介、と書きましたが、この 2 枚が示しているのは結局「どこに責務を置くか」の地図です。書き込みは SQL、読み取りは Firestore、認証はユーザーと運営で別、プロビジョニングは Terraform、デプロイは firebase CLI。境界を先に決めておくと、サービスが増えても同じ地図の上に足していけます。

<!-- retry -->
