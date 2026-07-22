---
title: "Firestore を Public Cache として扱う"
emoji: "🗃️"
type: "tech"
topics: ["firebase", "firestore", "cloudsql", "gcp"]
published: true
---

Firestore を「アプリの主データベース」として使う設計は、最初は楽です。書き込みと読み取りが同じ場所で完結し、`onSnapshot` で realtime push もそのまま手に入ります。一方で、サービスが育つにつれて、Firestore を SoT (source of truth) のままにしておくと、いくつかの致命的な制約が顔を出します。

# SoT のままだと困る場面

トランザクション境界の弱さ、複雑なクエリの不足、コスト構造、移行のしづらさ。なかでも厳しいのは「関連の更新を `WHERE` で絞れない」ことです。「ある条件を満たすドキュメント群を、まとめて整合的に更新する」というユースケースで、Firestore は構造的に弱いです。

# Public Cache としての再定義

あるプロジェクトでは、Cloud SQL を SoT、Firestore を「読み取りに最適化された投影面」として扱う構成にしました。書き込みはバックエンド (Next.js / Cloud Run) が担い、**SoT (Data Connect 経由の Cloud SQL) と Firestore を同じ書き込み処理の中で両方更新します**。これとは別に Cloud Run の reconciliation が走り、SoT を正として Firestore との **整合性をチェック・修復します**。この reconciliation ジョブは処理の冒頭、DB 更新よりも **先に** enqueue します。先に積んでおくことで、書き込みが途中で落ちても整合性チェックは必ず後追いで走り、状態が修復されます。クライアントから見ると Firestore は **再生成可能なキャッシュ** であり、最悪 SoT から rebuild できます。

```ts
// 書き込みはバックエンド経由。バックエンドが SoT(Data Connect→Cloud SQL) と
// Firestore を両方更新する。クライアントは Firestore に直接書かない。
await backend.updateEntity({ id, title });

// 反映は Firestore の onSnapshot で realtime に押し返される
unsubscribe = onSnapshot(entityRef, (snap) => render(snap.data()));
```

# 利点と代償

利点は明らかです。SoT 側 (SQL) のトランザクション整合性と複雑なクエリ、読み取り側 (Firestore) のデータモデルの自由度と realtime push、そして外部システム (OpenSearch / BigQuery 等) との一貫した同期が、無理なく同居します。書き込み時にバックエンドが Firestore も更新するので、フロントは `onSnapshot` の stream でそのまま **即時反映** されます。「書き込み直後に、自分が変えた値を UI で抱えておく」ような optimistic な小細工は要りません。

代償はレイテンシではなく、**二重書き込みと整合性** に移ります。バックエンドは SoT と Firestore の 2 か所を書くので、片方が失敗すれば両者はズレ得ます (単一の分散トランザクションではありません)。そのズレを埋めるのが Cloud Run の reconciliation で、SoT を正として Firestore を検証・修復します。Firestore を「壊れても rebuild できるキャッシュ」と割り切れるのは、この整合性チェックが背後にあるからです。運用コストは、この二重書き込みと reconciliation の経路に集約されます。

# どちらを取るか

「Firestore を SoT」と「Firestore を Cache」の選択は、サービスの寿命の長さで決まります。短命なプロトタイプなら前者、長く育てる予定なら後者です。中間にいるとき、後で寄せ替えるコストは、最初から Cache として扱うコストよりずっと高くつきます。

<!-- canary -->
