#!/usr/bin/env bash
# tools/newsmon-db-restore.sh — безпечне відновлення БД newsmon без web-UI.
#
# Використання:
#   bash tools/newsmon-db-restore.sh /шлях/до/backup.db
#
# Обходить баг newsmon web-UI (WAL-файл від поточної БД залишається після
# checkpoint і псує новий файл при відкритті через init_db).
set -euo pipefail

BACKUP="${1:-}"
[[ -n "$BACKUP" ]] || { echo "Використання: $0 <backup.db>"; exit 1; }
[[ -f "$BACKUP" ]]  || { echo "Файл не знайдено: $BACKUP"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/config.env"
fi
NEWSMON_DIR="${NEWSMON_DIR:-/home/maan/newsmon}"
DB="$NEWSMON_DIR/backend/newsmon.db"

echo "=== Перевірка резервної копії ==="
if ! sqlite3 "$BACKUP" "PRAGMA integrity_check;" 2>&1 | grep -q "^ok$"; then
  echo "ПОМИЛКА: файл $BACKUP пошкоджений або не є SQLite БД"
  exit 1
fi
echo "OK — backup цілий"

echo ""
echo "=== Зупиняємо newsmon ==="
sudo systemctl stop newsmon
echo "OK"

echo ""
echo "=== Checkpoint WAL і очищення ==="
if [[ -f "$DB" ]]; then
  sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
  rm -f "${DB}-wal" "${DB}-shm"
  echo "OK — WAL/SHM видалено"
else
  echo "Поточна БД не знайдена — продовжуємо"
fi

echo ""
echo "=== Резервна копія поточної БД ==="
if [[ -f "$DB" ]]; then
  BAK="${DB}.bak.$(date +%F_%H-%M-%S)"
  cp "$DB" "$BAK"
  echo "OK → $BAK"
fi

echo ""
echo "=== Відновлення з backup ==="
# Використовуємо .backup замість простого cp — коректно обробляє WAL-mode
sqlite3 "$BACKUP" ".backup '$DB'"
rm -f "${DB}-wal" "${DB}-shm"  # на випадок якщо backup містив WAL
echo "OK → $DB"

echo ""
echo "=== Перевірка відновленої БД ==="
RESULT=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1)
if echo "$RESULT" | grep -q "^ok$"; then
  echo "OK — БД цілісна"
else
  echo "УВАГА — integrity_check повернув:"
  echo "$RESULT"
fi

echo ""
echo "=== Запускаємо newsmon ==="
sudo systemctl start newsmon
sleep 2
if systemctl is-active --quiet newsmon; then
  echo "OK — newsmon запущено"
else
  echo "УВАГА — newsmon не запустився: journalctl -u newsmon -n 30"
fi

echo ""
echo "Готово. Відновлена БД: $DB"
