#!/usr/bin/env bash
# Оновлення media-репозиторію і хаб-сторінки без SSH.
# Викликається sysapi сервером — HUB_DIR береться з оточення (/etc/sysapi.env).
set -euo pipefail

MEDIA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB_DIR="${HUB_DIR:-/var/www/hub}"

echo "=== git pull: $MEDIA_DIR ==="
git -C "$MEDIA_DIR" pull --rebase
echo "OK"

echo "=== Оновлення хаб-сторінки ==="
sudo install -o www-data -g www-data -m 644 "$MEDIA_DIR/hub/index.html" "$HUB_DIR/index.html"
echo "OK → $HUB_DIR/index.html"

echo ""
echo "Готово. sysapi зараз перезапуститься з новим кодом."
