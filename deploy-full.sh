#!/bin/bash
# あーみーのブログ 完全自動デプロイスクリプト
# 使い方: ./deploy-full.sh
#
# 【必要なもの】初回のみ設定:
#   export WP_USER="bikyaku"
#   export WP_PASS="WordPressのログインパスワード"
# または ~/.zshrc に上記を追加

set -e
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
WP_URL="https://bikyakuchallenge.com"

# 認証情報チェック
if [ -z "$WP_USER" ] || [ -z "$WP_PASS" ]; then
  echo "❌ WP_USER と WP_PASS を環境変数に設定してください"
  echo "例: export WP_USER=bikyaku && export WP_PASS=パスワード"
  exit 1
fi

echo "🔐 WordPressにログイン中..."
# Cookieを取得
COOKIE_JAR="/tmp/wp-cookies.txt"
rm -f "$COOKIE_JAR"
curl -s -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -d "log=$WP_USER&pwd=$WP_PASS&wp-submit=Log+In&redirect_to=%2Fwp-admin%2F&testcookie=1" \
  -H "Cookie: wordpress_test_cookie=WP+Cookie+check" \
  "$WP_URL/wp-login.php" -L -w "%{http_code}" -o /dev/null

if ! grep -q "wordpress_logged_in" "$COOKIE_JAR"; then
  echo "❌ ログイン失敗。WP_USER/WP_PASSを確認してください"
  exit 1
fi
echo "✅ ログイン成功"

# Redirectionルール無効化（REST API経由）
echo "🔍 RedirectionルールIDを取得中..."
REDIRECT_DATA=$(curl -s -b "$COOKIE_JAR" \
  "$WP_URL/wp-json/redirection/v1/redirect?per_page=25&page=1" 2>/dev/null || echo "")
REDIRECT_ID=$(echo "$REDIRECT_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get('items', [])
    if items:
        print(items[0]['id'])
except:
    pass
" 2>/dev/null || echo "")

if [ -z "$REDIRECT_ID" ]; then
  echo "⚠️  RedirectionルールIDが取得できません。手動確認が必要です"
  echo "手動で無効化してから y を押してください: "
  read -r confirm
  if [ "$confirm" != "y" ]; then exit 1; fi
else
  echo "🔄 Redirectionルール($REDIRECT_ID)を無効化中..."
  WP_NONCE=$(curl -s -b "$COOKIE_JAR" "$WP_URL/wp-admin/tools.php?page=redirection.php" | grep -o '"restNonce":"[^"]*"' | head -1 | cut -d'"' -f4)
  curl -s -b "$COOKIE_JAR" \
    -X POST "$WP_URL/wp-json/redirection/v1/redirect/disable" \
    -H "Content-Type: application/json" \
    -H "X-WP-Nonce: $WP_NONCE" \
    -d "{\"items\":[{\"id\":$REDIRECT_ID}]}" > /dev/null
  echo "✅ Redirection無効化完了"
fi

# Simply Static 生成
echo "⚙️  Simply Static 生成開始..."
SS_NONCE=$(curl -s -b "$COOKIE_JAR" "$WP_URL/wp-admin/admin.php?page=simply-static-generate" | grep -o '"nonce":"[^"]*"' | head -1 | cut -d'"' -f4)
curl -s -b "$COOKIE_JAR" \
  "$WP_URL/wp-admin/admin-ajax.php" \
  -d "action=simply_static_ajax&_wpnonce=$SS_NONCE&task=start" > /dev/null

echo "⏳ 生成完了を待機中（最大5分）..."
ZIP_URL=""
for i in $(seq 1 30); do
  sleep 10
  RESULT=$(curl -s -b "$COOKIE_JAR" \
    "$WP_URL/wp-admin/admin-ajax.php" \
    -d "action=simply_static_ajax&_wpnonce=$SS_NONCE&task=pulse")
  ZIP_URL=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('payload',{}).get('download_url',''))" 2>/dev/null || echo "")
  if [ -n "$ZIP_URL" ]; then
    echo "✅ 生成完了: $ZIP_URL"
    break
  fi
  echo "   待機中... ($((i*10))秒経過)"
done

if [ -z "$ZIP_URL" ]; then
  echo "❌ ZIP生成タイムアウト。Simply Staticのページを手動確認してください"
  # Redirectionを戻す
  if [ -n "$REDIRECT_ID" ] && [ -n "$WP_NONCE" ]; then
    curl -s -b "$COOKIE_JAR" \
      -X POST "$WP_URL/wp-json/redirection/v1/redirect/enable" \
      -H "Content-Type: application/json" \
      -H "X-WP-Nonce: $WP_NONCE" \
      -d "{\"items\":[{\"id\":$REDIRECT_ID}]}" > /dev/null
  fi
  exit 1
fi

# デプロイ
echo "📦 ZIPダウンロード中..."
TMP_ZIP="/tmp/simply-static-deploy.zip"
curl -s -L -b "$COOKIE_JAR" -o "$TMP_ZIP" "$ZIP_URL"

echo "🗂️  静的ファイル削除中..."
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

echo "🚀 GitHubにプッシュ中..."
cd "$REPO_DIR"
git add -A
git commit -m "deploy: Simply Staticで自動再生成 $(date '+%Y-%m-%d %H:%M')"
git push origin main

# Redirectionを再有効化
if [ -n "$REDIRECT_ID" ] && [ -n "$WP_NONCE" ]; then
  echo "🔄 Redirection再有効化中..."
  curl -s -b "$COOKIE_JAR" \
    -X POST "$WP_URL/wp-json/redirection/v1/redirect/enable" \
    -H "Content-Type: application/json" \
    -H "X-WP-Nonce: $WP_NONCE" \
    -d "{\"items\":[{\"id\":$REDIRECT_ID}]}" > /dev/null
  echo "✅ Redirection再有効化完了"
fi

rm -f "$COOKIE_JAR"
echo ""
echo "🎉 デプロイ完了！Cloudflare Pagesのビルドが始まります（1〜3分）"
