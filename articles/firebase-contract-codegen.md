---
title: "contract.yml 一枚から Firebase 全レイヤーの型を生成する"
emoji: "📜"
type: "tech"
topics: ["firebase", "typescript", "zod", "graphql", "codegen"]
published: true
---

フロントエンドとバックエンドで型を共有したい、という問題は昔からあります。ひと昔前は両者のリポジトリを分けるのが一般的だったので、同じ型定義をそれぞれに手書きする — つまり重複させるしかありませんでした。私自身、当時は [hosting / functions / rules をリポジトリごと分ける構成](https://zenn.dev/cilly/articles/8d07823c268e1b) を採っていて、その記事ではリポジトリ分割のメリットを推していました。本記事は、そこから時間が経って考えが変わった側の話でもあります。

次の段階がプライベートパッケージです。共有型をパッケージに切り出せば重複は消えますが、今度はリポジトリが 1 つ増え、開発中はフロント・バックエンド・パッケージのリポジトリとエディタを行き来することになります。しかも型を 1 つ直すたびに、パッケージ側の commit → push → バージョンを上げて publish を経ないと、フロントにもバックエンドにも反映されません。動作確認のたびにこのサイクルが挟まります。さらにプライベートパッケージは、CI やデプロイのパイプラインが install するための認証も別途必要で、レジストリのトークン管理や権限まわりの解決が意外と面倒な仕組みになりがちです。パッケージの代わりに git submodule で共有リポジトリを埋め込む手もありますが、こちらは参照コミットの更新を利用側それぞれで回す運用が必要で、checkout のズレも起きやすく、手間の種類が変わるだけでした。

これを解いたのがモノレポでした。共有ライブラリを同一リポジトリから直接参照でき、フロントとバックエンドを同時進行で開発できます。「フロントとバックで同じ型を使う」だけの問題なら、ここで終わりだったはずです。

ところが、Cloud SQL (Data Connect) を SoT、Firestore を読み取り投影面 (キャッシュ) とする構成（[Firestore を Public Cache として扱う](https://zenn.dev/cilly/articles/firestore-as-public-cache)）を採ると、型共有の軸が変わります。「1 つの型を両側から参照する」では済まず、**同じモデルがレイヤーごとに別の表現で何度も書かれる** ようになるのです。モノレポは「同じ型をどこからでも参照できる」ようにはしてくれますが、「別の表現に分かれた定義を一致させ続ける」ことまでは面倒を見てくれません。

# 同じモデルが 6 回書かれる

`Product` というモデルを 1 つ足すと、手書きするファイルはこれだけあります。

- Data Connect の GraphQL スキーマ（`type Product @table(...)`）
- 共有 TypeScript 型（`interface Product`）
- Zod スキーマ（`ProductSchema`）
- Firestore 投影のスキーマ（relation は id に解決済み、`timestamp` は `Date`）
- API の request / response 型と、そのバリデーション Zod
- NestJS の class-validator DTO

どれも「同じもの」の別表現ですが、相互に検証する仕組みはありません。フィールドを 1 つ足すたびにこれらのファイルを渡り歩き、どれか 1 つを忘れても、壊れるのはずっと後 — 実行時です。手順に気をつけて防ぐ類いの問題ではなく、多重管理という構造そのものが原因です。

# 契約を書いて、残りは全部生成する

そこで、**モデル定義を YAML の契約ファイルに一本化し、すべての表現をそこから生成する** ツールを作りました。[firebase-contract](https://github.com/cilly-yllic/my-packages/blob/main/packages/firebase-contract/README.md) です。

![contract.yml を single source of truth に、コンパイラを経て各レイヤーのコードを生成するアーキテクチャ図](/images/contract-driven-firebase-codegen-architecture.png)
*契約 → コンパイラ (IR) → 生成物の一方向。生成物と契約の drift は CI の `--check` が検出します。*

```yaml
# contract.yml (抜粋)
models:
  Product:
    key: [catalog, productNo]
    fields:
      catalog: { type: Catalog, relation: true }
      productNo: int
      title: { type: string, nonempty: true, maxLength: 200 }
      status: ProductStatus
      metadata: { type: ProductMetadata, optional: true }
      createdAt: timestamp

generators:
  - { generator: typescript, out: '#contracts', split: true }
  - { generator: zod, out: '#contracts', split: true }
  - { generator: data-connect-graphql, out: src, split: true }
  - { generator: firestore, out: '#contracts', split: true }
```

`fbc generate` の一回で、TS 型・Zod・GraphQL スキーマ・Firestore 投影がすべて出力されます。`title` の `nonempty: true, maxLength: 200` のような制約は、Zod にも、API 系の generator (api-validation / api-dto) を宣言していれば request バリデーションや class-validator DTO にも、同じように流れます。「バリデーションだけ古い」が起きません。

契約は `imports` で分割でき、複数アプリのモノレポでもリポジトリ構成に沿って yml を置けます。実際に導入したプロジェクトでは、ルートの契約から 2 アプリ・9 ファイルの yml に分割し、そこから 30 個超のファイルを生成しています。

# Firestore は「別のスキーマ」ではなく「投影」

このツールで一番効いているのがここです。Firestore を読み取り投影面として使うと、そのスキーマは Data Connect と **同じではないが、無関係でもない** という微妙な位置に立ちます。relation は解決済みの文字列 id になり、`timestamp` は `Date` になり、非正規化フィールドが足される。手書きだと、この「規則的な変換 + 少しの追加」を丸ごと書き写すことになります。

契約では、投影を Data Connect モデルからの **派生** として宣言します。

```yaml
firestore:
  Product:
    from: Product
    collection: shops/{ws}/.../products/{productNo}
    omit: [catalog, log]
    fields:
      linkedCatalogTitle: { type: string, optional: true }
```

relation → id、timestamp → `z.date()` といった投影の規則は generator が一律に適用し、`pick` / `omit` と追加 `fields` だけを人が書きます。投影をまたいで共有したいプロジェクト共通のフィールドがあれば、`fragments:` として一度宣言し、各投影に `extends:` で挿し込めます。生成された Zod スキーマは、Data Connect 側とチェーンが同一のフィールドを `.pick()` で再利用するので、「表現が変わる部分」だけがファイル上に現れます。差分がそのまま設計の意図として読めます。

# Data Connect の Any 境界

Data Connect は埋め込みオブジェクトや JSON を `Any` スカラーとして保存し、論理型を消してしまいます。手書き運用だと `metadata` が「本当は何の型か」はコメントと記憶に頼ることになります。契約からの生成では、GraphQL 側に論理型をコメントとして残しつつ（`metadata: Any # logical: ProductMetadata`）、`Any` の行と論理型を相互変換する型付きアダプタも一緒に生成します。型が消える境界がどこかを、契約が知っているからできることです。

# 効いている設計判断

**Generator は YAML を見ません。** パースと import 解決を経て正規化された IR (中間表現) だけを入力にします。バリデーションも IR に対する独立したルール関数群です。generator を 1 つ足すのに既存コードの変更が要らず、OpenAPI 出力のような拡張も registry への登録だけで済みます。

**手書きファイルの byte-for-byte 再現に投資しました。** 導入対象は既に動いているプロダクトで、生成物が既存の手書きファイルと 1 バイトでも違えば diff に埋もれて検証できません。フォーマットの揺れを吸収する style オプションや `raw` エスケープハッチは、この「既存ファイルを完全一致で再現してから置き換える」という漸進的な移行のためにあります。おかげで移行は一括の書き換えではなく、ファイル単位で「生成に寄せては diff ゼロを確認する」の繰り返しにできました。

**再生成は冪等です。** 内容が変わらない限り、生成日時を含めてファイルは byte-for-byte で同じに保たれます（`generatedAt` は初回生成から引き継がれ、内容が変わったときだけ `updatedAt` が動く）。CI の `--check` で「契約とコードの drift」を機械的に検出できるのは、この冪等性があるからです。

# 代償

DSL は増えた複雑さそのものです。フィールドオプションや操作の表現力には天井があり、天井に当たるたびに generator を育てるか `raw` で逃げるかを選ぶことになります。生成コードのデバッグも 1 段間接的になります。

本来なら「チームが YAML DSL を新たに覚える」という学習コストも代償に数えるところですが、ここは AI で相殺できています。コーディングエージェントに DSL のルールとプロダクトの仕様を読み込ませておけば、「Product に在庫数フィールドを足したい」という指示から契約 yml の修正までは AI がやってくれます。宣言的な契約はモデル定義が一箇所に集まっていて差分も小さいので、AI にとっても扱いやすい対象です。出力がおかしければ `fbc generate` の diff に現れるので、検証も機械的に済みます。人が覚えるのは DSL の文法ではなく「契約を読んで意図を確認する」ことだけになりました。

残る代償は表現力の天井とデバッグの間接化ですが、それを差し引いても、フィールドを 1 つ足す作業が「契約に 1 行足して `fbc generate`」に収束した価値は大きいです。多重管理の drift は「気をつける対象」から「CI が検出する対象」に変わりました。型の整合性を人の注意力から仕組みへ移すと、レビューの関心事も個々の型定義の写経チェックから、契約そのものの設計へと移っていきます。

# 型定義ごと AI に任せればいいのでは

AI が契約を書けるなら、もう一歩進めて「LLM にルールとプロダクトの仕様を渡し、各レイヤーの型定義を直接書かせれば、契約も生成器も要らないのでは」という考えも出てきます。人が型定義を直接触らない運用にすれば、多重管理の手間ごと消えるはずだ、と。

ただ、これは分業の向きが逆だと考えています。LLM の出力は確率的なので、6 つの表現への直接編集は、毎回どこかが揃わないリスクを抱えます。より本質的なのは、契約がなければ **「揃っている」ことの機械的な定義そのものが存在しなくなる** ことです。6 つの表現が同じモデルを表しているかを検証するには、結局それらの共通の元 — 契約に相当するもの — が要ります。`--check` が drift を検出できるのは、決定的な生成器が「正しい出力はこれ」と一意に言えるからで、AI の直接編集にはこの検証可能性がありません。

レビューのコストも変わります。AI が 6 ファイルを直接編集すれば、人はその 6 ファイル分の diff を毎回疑いながら読むことになります。契約方式なら人が読むのは yml の diff だけで、残りは決定的に導出されます。曖昧な仕様を契約に落とす仕事は AI に、契約を各表現に展開する仕事は生成器に。確率的な層と決定的な層を分けているからこそ、AI に安心して書かせられます。

# 公開先

npm パッケージとして公開しています。RC シリーズで「契約が正」の厳格化（未知キーや語彙外の値をエラーにする）を進め、実プロジェクトで全機能を drift ゼロで検証した上で、v0.1.0 を最初の安定版としてリリースしました。DSL の表現力や generator の細部は、引き続き運用からのフィードバックを反映しながら改善していきます。

https://www.npmjs.com/package/firebase-contract

https://github.com/cilly-yllic/my-packages/blob/main/packages/firebase-contract/README.md
