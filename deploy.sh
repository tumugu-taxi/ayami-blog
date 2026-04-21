#!/bin/bash
set -e
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ZIP_URL="$1"
if [ -z "$ZIP_URL" ]; then echo "❌ URLを渡してください"; exit 1; fi

echo "📦 ダウンロード中..."
TMP_ZIP="/tmp/simply-static-deploy.zip"
curl -L -o "$TMP_ZIP" "$ZIP_URL"

echo "🗂️  静的ファイルを削除中..."
# .git, .claude, deploy.sh, drafts, agents, logs は絶対に残す
for item in "$REPO_DIR"/*; do
  name="$(basename "$item")"
  case "$name" in
    deploy.sh|deploy-full.sh|.git|.claude|drafts|agents|logs|README.md|CLAUDE.md) ;;
    *) rm -rf "$item" ;;
  esac
done

echo "📂 展開中..."
unzip -q "$TMP_ZIP" -d "$REPO_DIR"
rm "$TMP_ZIP"

echo "🚀 プッシュ中..."
cd "$REPO_DIR"
git add -A
git commit -m "deploy: Simply Staticで再生成 $(date '+%Y-%m-%d %H:%M')"
git push origin main
echo "✅ 完了！"
