#!/usr/bin/env bash
# update-all.sh — оновлення всіх трьох сервісів на Pi одним запуском.
# Використання:  ./update-all.sh            (усі сервіси)
#                ./update-all.sh newsmon    (лише один)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Завантажити конфіг із wizard (якщо є), інакше — дефолти
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/config.env"
fi
NEWSMON_DIR="${NEWSMON_DIR:-/home/maan/newsmon}"
WM_DIR="${WM_DIR:-/home/maan/watermarker-pro}"
WRITER_DIR="${WRITER_DIR:-/var/www/ainewswriter}"

log() { printf '\n\033[1;35m== %s ==\033[0m\n' "$1"; }

update_newsmon() {
  log "newsmon"
  cd "$NEWSMON_DIR"
  git pull --rebase
  ./backend/.venv/bin/pip install -q -r backend/requirements.txt
  sudo systemctl restart newsmon
  systemctl is-active newsmon
}

update_watermarker() {
  log "watermarker-pro"
  cd "$WM_DIR"
  git pull --rebase
  ./.venv/bin/pip install -q -r requirements.txt
  sudo systemctl restart watermarker
  systemctl is-active watermarker
}

update_writer() {
  log "ainewswriter"
  # Визначаємо php-fpm тут, а не на старті — уникаємо помилки якщо php не встановлено
  local PHP_FPM
  PHP_FPM=$(systemctl list-units --type=service --all 'php*-fpm*' --no-legend \
            2>/dev/null | awk '{print $1}' | head -1 || true)
  [[ -n "$PHP_FPM" ]] || { echo "Помилка: php-fpm сервіс не знайдено"; exit 1; }
  cd "$WRITER_DIR"
  sudo -u www-data git pull --rebase
  sudo systemctl restart "$PHP_FPM"
  sudo systemctl reload nginx
  systemctl is-active "$PHP_FPM" nginx
}

case "${1:-all}" in
  newsmon)      update_newsmon ;;
  watermarker)  update_watermarker ;;
  writer)       update_writer ;;
  all)          update_newsmon; update_watermarker; update_writer ;;
  *) echo "Невідомий сервіс: $1 (newsmon|watermarker|writer|all)"; exit 1 ;;
esac

log "Готово"
