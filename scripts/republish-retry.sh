#!/bin/bash
# Zennのレート制限で未公開のままの記事を「1本ずつ」再公開するスクリプト。
#
# 背景: 新規記事の一斉公開はZennのスパム対策レート制限に当たる
# (デプロイ成功表示のまま該当記事だけスキップされる)。上限・解除時間は非公開のため、
# 1回の実行で未公開記事を1本だけ再デプロイし、公開を確認する。
# 全て公開済みなら何もせず終了する。使い方: ./scripts/republish-retry.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SLUGS=(multi-service-firebase-platform platform-sync-dns-logto-proxy-env)
MARKER='<!-- retry -->'

is_live() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' "https://zenn.dev/api/articles/$1")" = "200" ]
}

target=""
for slug in "${SLUGS[@]}"; do
  if is_live "$slug"; then
    echo "✔ published: $slug"
  else
    target="$slug"
    break
  fi
done

if [ -z "$target" ]; then
  echo "🎉 対象記事はすべて公開済みです。"
  exit 0
fi

file="articles/$target.md"
echo "→ retrying: $target"

# 末尾のマーカーコメントをトグルして差分を作る (Zenn上では不可視)
if grep -q "$MARKER" "$file"; then
  perl -0pi -e "s/\n\Q$MARKER\E\n\z//" "$file"
else
  printf '\n%s\n' "$MARKER" >> "$file"
fi

# 過去の疎通確認用カナリアが残っていれば掃除する
CANARY_FILE=articles/firestore-as-public-cache.md
if grep -q '<!-- canary -->' "$CANARY_FILE"; then
  perl -0pi -e "s/\n<!-- canary -->\n\z//" "$CANARY_FILE"
  git add "$CANARY_FILE"
fi

git add "$file"
git commit -m "chore: レート制限で未公開の記事を再デプロイ ($target)"
git push

echo "waiting for Zenn deploy..."
for i in $(seq 1 10); do
  sleep 15
  if is_live "$target"; then
    echo "🎉 published: https://zenn.dev/cilly/articles/$target"
    exit 0
  fi
  echo "  ...not yet ($i/10)"
done

echo "✖ まだ公開されていません (レート制限が未解除の可能性)。時間をおいて再実行してください。"
exit 1
