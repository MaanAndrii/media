#!/usr/bin/env bash
# ============================================================
# Pi Media Services — Wizard встановлення
# Запуск: cd ~/media && bash setup.sh
# Потрібно: git (вже встановлено), sudo
# ============================================================
set -euo pipefail
IFS=$'\n\t'

R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m'
B=$'\033[0;34m' M=$'\033[1;35m' C=$'\033[0;36m'
W=$'\033[1;37m' N=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/setup.log"
STEP_NUM=0
TOTAL_STEPS=10
IS_PI=false

CFG_USER="" CFG_HOME="" CFG_NEWSMON_DIR="" CFG_WM_DIR=""
CFG_WRITER_DIR="" CFG_HUB_DIR="" CFG_NEWSMON_TOKEN=""
CFG_WRITER_PASS="" CFG_ANTHROPIC_KEY="" CFG_XAI_KEY=""
CFG_GOOGLE_KEY="" CFG_PHP_SOCK="" CFG_BACKUP=false CFG_SYSAPI_PASS=""

trap 'echo -e "\n${R}Помилка на рядку $LINENO. Деталі: $LOG_FILE${N}" >&2' ERR

# ── UI ───────────────────────────────────────────────────────

banner() {
  clear 2>/dev/null || true
  echo -e "${M}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║      Pi Media Services — Wizard встановлення            ║"
  echo "║  NewsMon · AI News Writer · Watermarker Pro · Hub       ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${N}  Лог: ${C}${LOG_FILE}${N}"
  echo
}

step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo -e "\n${W}━━━ [$STEP_NUM/$TOTAL_STEPS] $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

ok()   { echo -e "  ${G}✓${N}  $*"; }
warn() { echo -e "  ${Y}⚠${N}  $*"; }
info() { echo -e "  ${C}→${N}  $*"; }
err()  { echo -e "\n${R}ПОМИЛКА: $*${N}" >&2; exit 1; }
hr()   { echo -e "  ${B}──────────────────────────────────────────────────${N}"; }

ask() {
  local -n _ref=$1
  local prompt="$2" default="$3" val
  read -rp "  ${C}?${N} $prompt [${W}${default}${N}]: " val
  _ref="${val:-$default}"
}

ask_secret() {
  local -n _ref=$1
  local prompt="$2" val
  read -rsp "  ${C}?${N} $prompt: " val; echo
  _ref="$val"
}

ask_optional() {
  local -n _ref=$1
  local prompt="$2" val
  read -rp "  ${C}?${N} $prompt [${Y}Enter — пропустити${N}]: " val
  _ref="$val"
}

ask_yn() {
  local prompt="$1" default="${2:-y}" answer hint
  [[ "$default" == "y" ]] && hint="${W}Y${N}/n" || hint="y/${W}N${N}"
  while true; do
    read -rp "  ${C}?${N} $prompt [$hint]: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes|т|так) return 0 ;;
      n|no|н|ні)   return 1 ;;
      *) echo "    Введи y або n" ;;
    esac
  done
}

run() {
  printf '+ %s\n' "$*" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1
}

# ── 1. Перевірка вимог ───────────────────────────────────────

check_prereqs() {
  step "Перевірка вимог"
  printf '=== Pi Media Setup — %s ===\n' "$(date)" > "$LOG_FILE"

  if ! sudo -n true 2>/dev/null; then
    echo -e "\n  Потрібен sudo. Введи пароль:"
    sudo -v || err "sudo недоступний"
  fi
  ok "sudo"

  local arch; arch=$(uname -m)
  if [[ "$arch" == "aarch64" ]]; then IS_PI=true; ok "ARM64 (Raspberry Pi)"
  else IS_PI=false; ok "Архітектура: $arch"; fi

  command -v git    &>/dev/null || err "git не знайдено: sudo apt install -y git"
  command -v openssl &>/dev/null || warn "openssl не знайдено — буде встановлено на кроці 3"
  ok "git: $(git --version | awk '{print $3}')"

  if curl -fsS --max-time 5 https://github.com &>/dev/null; then
    ok "Інтернет: GitHub доступний"
  else
    warn "GitHub недоступний — клонування може не вдатись"
  fi
}

# ── 2. Збір конфігурації ─────────────────────────────────────

gather_config() {
  step "Конфігурація"
  echo -e "\n  Натискай ${W}Enter${N} щоб прийняти значення у дужках.\n"

  hr; echo -e "  ${W}Користувач і шляхи${N}"; hr
  ask CFG_USER "Ім'я Linux-користувача для сервісів" "$(whoami)"
  CFG_HOME="$(eval echo "~${CFG_USER}")"
  [[ -d "$CFG_HOME" ]] || err "Домашній каталог $CFG_HOME не існує"
  ok "Домашній каталог: $CFG_HOME"
  echo
  ask CFG_NEWSMON_DIR "Каталог NewsMon"          "$CFG_HOME/newsmon"
  ask CFG_WM_DIR      "Каталог Watermarker Pro"   "$CFG_HOME/watermarker-pro"
  ask CFG_WRITER_DIR  "Каталог AI News Writer"    "/var/www/ainewswriter"
  ask CFG_HUB_DIR     "Каталог хаб-сторінки"     "/var/www/hub"

  hr; echo -e "  ${W}NewsMon — токен API${N}"; hr
  if ask_yn "Згенерувати токен автоматично?" "y"; then
    command -v openssl &>/dev/null \
      && CFG_NEWSMON_TOKEN=$(openssl rand -hex 32) \
      || CFG_NEWSMON_TOKEN=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64)
    ok "Токен: ${CFG_NEWSMON_TOKEN:0:16}…"
  else
    ask_secret CFG_NEWSMON_TOKEN "Введи токен NewsMon"
    [[ -n "$CFG_NEWSMON_TOKEN" ]] || err "Токен не може бути порожнім"
  fi

  hr; echo -e "  ${W}AI News Writer — адмін-пароль${N}"; hr
  ask_secret CFG_WRITER_PASS "Пароль адміністратора"
  [[ -n "$CFG_WRITER_PASS" ]] || err "Пароль не може бути порожнім"

  hr; echo -e "  ${W}API-ключі для AI${N} ${Y}(необов'язково — можна додати пізніше)${N}"; hr
  ask_optional CFG_ANTHROPIC_KEY "Anthropic API key"
  ask_optional CFG_XAI_KEY       "xAI (Grok) API key"
  ask_optional CFG_GOOGLE_KEY    "Google (Gemini) API key"

  hr; echo -e "  ${W}Пароль управління сервісами (хаб)${N}"; hr
  ask CFG_SYSAPI_PASS "Пароль адміністратора для кнопок ↺↑" "admin"

  hr; echo -e "  ${W}Автоматичні бекапи${N}"; hr
  ask_yn "Налаштувати щоденний бекап (cron 03:30)?" "y" && CFG_BACKUP=true || CFG_BACKUP=false
  echo
}

# ── Підтвердження плану ──────────────────────────────────────

confirm_plan() {
  local backup_label; $CFG_BACKUP && backup_label="щоденно 03:30" || backup_label="ні"
  echo -e "\n${W}Перевір конфігурацію перед встановленням:${N}\n"
  hr
  printf "  %-28s %s\n" "Користувач:"       "$CFG_USER"
  printf "  %-28s %s\n" "NewsMon:"           "$CFG_NEWSMON_DIR"
  printf "  %-28s %s\n" "Watermarker Pro:"   "$CFG_WM_DIR"
  printf "  %-28s %s\n" "AI News Writer:"    "$CFG_WRITER_DIR"
  printf "  %-28s %s\n" "Хаб:"              "$CFG_HUB_DIR"
  printf "  %-28s %s\n" "NewsMon токен:"     "${CFG_NEWSMON_TOKEN:0:16}…"
  printf "  %-28s %s\n" "Anthropic API key:" "${CFG_ANTHROPIC_KEY:-(не вказано)}"
  printf "  %-28s %s\n" "xAI API key:"       "${CFG_XAI_KEY:-(не вказано)}"
  printf "  %-28s %s\n" "Google API key:"    "${CFG_GOOGLE_KEY:-(не вказано)}"
  printf "  %-28s %s\n" "Бекапи:"            "$backup_label"
  hr; echo
  ask_yn "Розпочати встановлення?" "y" || { echo "Скасовано."; exit 0; }
}

# ── 3. Системні пакети ───────────────────────────────────────

install_packages() {
  step "Системні пакети"
  info "sudo apt-get update…"
  run sudo apt-get update -q

  local pkgs=(git nginx curl openssl sqlite3
              python3 python3-venv python3-pip
              php-fpm php-cli php-curl php-sqlite3 php-mbstring)
  info "Встановлення: ${pkgs[*]}"
  run sudo apt-get install -y "${pkgs[@]}"
  ok "Системні пакети встановлено"

  # Визначити сокет php-fpm
  local sock
  sock=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1 || true)
  if [[ -z "$sock" ]]; then
    local phpver; phpver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    sock="/run/php/php${phpver}-fpm.sock"
    warn "Сокет ще не знайдено в /run/php/ — очікується: $sock"
  fi
  CFG_PHP_SOCK="$sock"
  ok "PHP-FPM сокет: $CFG_PHP_SOCK"

  # Зберегти конфіг для update-all.sh
  cat > "$SCRIPT_DIR/config.env" <<EOF
# Генерується setup.sh автоматично
SERVICE_USER=$CFG_USER
NEWSMON_DIR=$CFG_NEWSMON_DIR
WM_DIR=$CFG_WM_DIR
WRITER_DIR=$CFG_WRITER_DIR
EOF
  ok "config.env збережено"
}

# ── 4. NewsMon ───────────────────────────────────────────────

setup_newsmon() {
  step "NewsMon"

  if [[ -d "$CFG_NEWSMON_DIR/.git" ]]; then
    info "Репозиторій вже є — оновлення…"
    run git -C "$CFG_NEWSMON_DIR" pull --rebase
  else
    info "Клонування newsmon…"
    run git clone https://github.com/MaanAndrii/newsmon.git "$CFG_NEWSMON_DIR"
  fi

  local venv="$CFG_NEWSMON_DIR/backend/.venv"
  [[ -d "$venv" ]] || run python3 -m venv "$venv"
  info "Встановлення Python-залежностей…"
  run "$venv/bin/pip" install -q --upgrade pip
  run "$venv/bin/pip" install -q -r "$CFG_NEWSMON_DIR/backend/requirements.txt"
  ok "Python venv: $venv"

  local envfile="/etc/newsmon.env"
  if [[ ! -f "$envfile" ]]; then
    echo "NEWSMON_API_TOKEN=$CFG_NEWSMON_TOKEN" | sudo tee "$envfile" > /dev/null
    run sudo chmod 600 "$envfile"
    sudo chown "$CFG_USER" "$envfile" 2>/dev/null || true
    ok "Токен збережено: $envfile"
  else
    warn "$envfile вже існує — не перезаписую"
  fi

  run sudo chown -R "$CFG_USER:$CFG_USER" "$CFG_NEWSMON_DIR"
  ok "NewsMon: $CFG_NEWSMON_DIR"
}

# ── 5. AI News Writer ────────────────────────────────────────

setup_ainewswriter() {
  step "AI News Writer"

  if [[ -d "$CFG_WRITER_DIR/.git" ]]; then
    info "Репозиторій вже є — оновлення…"
    run sudo -u www-data git -C "$CFG_WRITER_DIR" pull --rebase
  else
    info "Клонування ainewswriter…"
    run sudo git clone https://github.com/MaanAndrii/ainewswriter.git "$CFG_WRITER_DIR"
  fi
  run sudo chown -R www-data:www-data "$CFG_WRITER_DIR"
  run sudo find "$CFG_WRITER_DIR" -type d -exec chmod 755 {} \;
  run sudo find "$CFG_WRITER_DIR" -type f -exec chmod 644 {} \;
  ok "Код: $CFG_WRITER_DIR"

  local envfile="$CFG_WRITER_DIR/.env.local"
  if [[ ! -f "$envfile" ]]; then
    sudo tee "$envfile" > /dev/null <<EOF
ADMIN_PASSWORD=${CFG_WRITER_PASS}
ANTHROPIC_API_KEY=${CFG_ANTHROPIC_KEY}
XAI_API_KEY=${CFG_XAI_KEY}
GOOGLE_API_KEY=${CFG_GOOGLE_KEY}
EOF
    run sudo chown www-data:www-data "$envfile"
    run sudo chmod 600 "$envfile"
    ok ".env.local: $envfile"
  else
    warn "$envfile вже існує — не перезаписую"
  fi
}

# ── 6. Watermarker Pro ───────────────────────────────────────

setup_watermarker() {
  step "Watermarker Pro"

  if [[ -d "$CFG_WM_DIR/.git" ]]; then
    info "Репозиторій вже є — оновлення…"
    run git -C "$CFG_WM_DIR" pull --rebase
  else
    info "Клонування watermarker-pro…"
    run git clone https://github.com/MaanAndrii/watermarker-pro.git "$CFG_WM_DIR"
  fi

  local venv="$CFG_WM_DIR/.venv"
  [[ -d "$venv" ]] || run python3 -m venv "$venv"
  info "Встановлення Python-залежностей…"
  run "$venv/bin/pip" install -q --upgrade pip
  run "$venv/bin/pip" install -q -r "$CFG_WM_DIR/requirements.txt"
  ok "Python залежності встановлено"

  # ARM: piwheels не має React-збірки — ставимо wheel з PyPI
  if [[ "$IS_PI" == "true" ]]; then
    info "ARM: перевстановлення streamlit-sortables з PyPI (обхід piwheels)…"
    "$venv/bin/pip" uninstall -y streamlit-sortables >> "$LOG_FILE" 2>&1 || true
    PIP_CONFIG_FILE=/dev/null \
      "$venv/bin/pip" install --no-cache-dir --only-binary=:all: \
        streamlit-sortables==0.3.1 >> "$LOG_FILE" 2>&1
    local pyver build_dir
    pyver=$("$venv/bin/python3" -c \
      'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')
    build_dir="$venv/lib/$pyver/site-packages/streamlit_sortables/frontend/build"
    if [[ -d "$build_dir" ]]; then
      ok "streamlit-sortables: PyPI wheel OK"
    else
      warn "streamlit-sortables build dir не знайдено: $build_dir"
      warn "Якщо при завантаженні фото падає — дивись DEPLOY.md §12.A"
    fi
  fi

  run sudo chown -R "$CFG_USER:$CFG_USER" "$CFG_WM_DIR"
  ok "Watermarker Pro: $CFG_WM_DIR"
}

# ── 7. Хаб і nginx ───────────────────────────────────────────

setup_hub_nginx() {
  step "Хаб і nginx"

  run sudo mkdir -p "$CFG_HUB_DIR"
  run sudo cp "$SCRIPT_DIR/hub/index.html" "$CFG_HUB_DIR/"
  run sudo chown -R www-data:www-data "$CFG_HUB_DIR"
  ok "Хаб: $CFG_HUB_DIR"

  local nginx_dst=/etc/nginx/sites-available/pi-services.conf
  local php_base; php_base=$(basename "$CFG_PHP_SOCK")

  sed \
    -e "s|php[0-9]*\.[0-9]*-fpm\.sock|$php_base|g" \
    -e "s|/var/www/ainewswriter|$CFG_WRITER_DIR|g" \
    -e "s|/var/www/hub|$CFG_HUB_DIR|g" \
    "$SCRIPT_DIR/nginx/pi-services.conf" | sudo tee "$nginx_dst" > /dev/null
  ok "nginx конфіг: $nginx_dst (PHP: $php_base)"

  run sudo rm -f /etc/nginx/sites-enabled/default
  run sudo ln -sf "$nginx_dst" /etc/nginx/sites-enabled/pi-services.conf

  if sudo nginx -t >> "$LOG_FILE" 2>&1; then
    run sudo systemctl restart nginx
    ok "nginx: перезапущено"
  else
    err "nginx -t не пройшов! Деталі: $LOG_FILE"
  fi
}

# ── 8. systemd ───────────────────────────────────────────────

setup_systemd() {
  step "systemd"

  sed \
    -e "s|User=maan|User=$CFG_USER|g" \
    -e "s|Group=maan|Group=$CFG_USER|g" \
    -e "s|/home/maan/newsmon|$CFG_NEWSMON_DIR|g" \
    "$SCRIPT_DIR/systemd/newsmon.service" \
    | sudo tee /etc/systemd/system/newsmon.service > /dev/null
  ok "newsmon.service"

  sed \
    -e "s|User=maan|User=$CFG_USER|g" \
    -e "s|Group=maan|Group=$CFG_USER|g" \
    -e "s|/home/maan/watermarker-pro|$CFG_WM_DIR|g" \
    "$SCRIPT_DIR/systemd/watermarker.service" \
    | sudo tee /etc/systemd/system/watermarker.service > /dev/null
  ok "watermarker.service"

  run sudo systemctl daemon-reload

  for svc in newsmon watermarker; do
    run sudo systemctl enable --now "$svc"
  done

  sleep 4

  for svc in newsmon watermarker; do
    if systemctl is-active --quiet "$svc"; then
      ok "$svc: active (running)"
    else
      warn "$svc: не запустився — journalctl -u $svc -n 30"
    fi
  done

  local php_fpm
  php_fpm=$(systemctl list-units --type=service --all 'php*-fpm*' --no-legend \
            2>/dev/null | awk '{print $1}' | head -1 || true)
  if [[ -n "$php_fpm" ]]; then
    run sudo systemctl enable --now "$php_fpm"
    ok "php-fpm: $php_fpm"
  else
    warn "php-fpm юніт не знайдено"
  fi
}

# ── 8. Sysapi ────────────────────────────────────────────────

setup_sysapi() {
  step "System API (управління сервісами з хабу)"

  local envfile="/etc/sysapi.env"
  if [[ ! -f "$envfile" ]]; then
    printf 'SYSAPI_PASSWORD=%s\nMEDIA_DIR=%s\n' "$CFG_SYSAPI_PASS" "$SCRIPT_DIR" \
      | sudo tee "$envfile" > /dev/null
    run sudo chmod 600 "$envfile"
    sudo chown "$CFG_USER" "$envfile" 2>/dev/null || true
    ok "Пароль збережено: $envfile"
  else
    warn "$envfile вже існує — оновлення пароля"
    sudo sed -i "s|^SYSAPI_PASSWORD=.*|SYSAPI_PASSWORD=$CFG_SYSAPI_PASS|" "$envfile"
    ok "Пароль оновлено в $envfile"
  fi

  sed \
    -e "s|User=maan|User=$CFG_USER|g" \
    -e "s|Group=maan|Group=$CFG_USER|g" \
    -e "s|/home/maan/media|$SCRIPT_DIR|g" \
    "$SCRIPT_DIR/systemd/sysapi.service" \
    | sudo tee /etc/systemd/system/sysapi.service > /dev/null
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now sysapi
  sleep 2

  if systemctl is-active --quiet sysapi; then
    ok "sysapi: active (running) на 127.0.0.1:8502"
  else
    warn "sysapi: не запустився — journalctl -u sysapi -n 30"
  fi
}

# ── Бекапи (опційно) ─────────────────────────────────────────

setup_backup() {
  [[ "$CFG_BACKUP" == "true" ]] || return 0

  local backup_dir="$CFG_HOME/backups"
  local script="$CFG_HOME/backup.sh"
  run sudo -u "$CFG_USER" mkdir -p "$backup_dir"

  sudo -u "$CFG_USER" tee "$script" > /dev/null <<BEOF
#!/usr/bin/env bash
set -e
TS=\$(date +%F_%H-%M-%S)
DEST=${backup_dir}/\$TS
mkdir -p "\$DEST"
sqlite3 ${CFG_NEWSMON_DIR}/backend/newsmon.db ".backup '\$DEST/newsmon.db'"
cp ${CFG_NEWSMON_DIR}/backend/telegram_user.session "\$DEST/" 2>/dev/null || true
sudo cp /etc/newsmon.env "\$DEST/"
sudo cp ${CFG_WRITER_DIR}/.env.local "\$DEST/ainewswriter.env.local" 2>/dev/null || true
sudo chown -R ${CFG_USER}:${CFG_USER} "\$DEST"
ls -dt ${backup_dir}/*/ 2>/dev/null | tail -n +15 | xargs -r rm -rf
echo "Бекап: \$DEST"
BEOF

  run chmod +x "$script"

  local cron_line="30 3 * * * $script >> $CFG_HOME/backup.log 2>&1"
  ( sudo crontab -u "$CFG_USER" -l 2>/dev/null | grep -v 'backup\.sh' || true
    echo "$cron_line"
  ) | sudo crontab -u "$CFG_USER" -
  ok "Бекап: $script (cron 03:30)"
}

# ── 10. Перевірка ────────────────────────────────────────────

verify_all() {
  step "Перевірка"
  echo
  local pass=0 fail=0

  check_url() {
    local label="$1" url="$2"
    local code
    code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
      ok "$label → HTTP $code"; pass=$((pass + 1))
    else
      warn "$label → HTTP $code"; fail=$((fail + 1))
    fi
  }

  sleep 3
  check_url "Хаб /"                     "http://127.0.0.1/"
  check_url "AI Writer /public/"         "http://127.0.0.1/public/newswriter.html"
  check_url "Watermarker /wm/"           "http://127.0.0.1/wm/"
  check_url "/health/writer"             "http://127.0.0.1/health/writer"
  check_url "/health/wm"                 "http://127.0.0.1/health/wm"
  check_url "NewsMon :8000 /api/status"  "http://127.0.0.1:8000/api/monitor/status"
  check_url "/health/news"               "http://127.0.0.1/health/news"
  check_url "sysapi /health"             "http://127.0.0.1/sysapi/health"

  echo
  local total=$((pass + fail))
  if [[ $fail -eq 0 ]]; then
    echo -e "  ${G}✓ Всі $total перевірок пройдено${N}"
  else
    echo -e "  ${Y}⚠ $pass/$total OK${N} — частина сервісів ще не готова"
    echo -e "  ${C}→ NewsMon: потрібна авторизація Telegram (це очікувано)${N}"
    echo -e "  ${C}→ Деталі: journalctl -u newsmon -n 30${N}"
    echo -e "  ${C}→ Nginx: sudo tail /var/log/nginx/error.log${N}"
  fi
}

# ── Підсумок ─────────────────────────────────────────────────

show_summary() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
  echo
  echo -e "${M}╔══════════════════════════════════════════════════════════╗"
  echo    "║               Встановлення завершено!                    ║"
  echo -e "╚══════════════════════════════════════════════════════════╝${N}"
  echo
  echo -e "  ${W}Адреси (відкрий у браузері в LAN):${N}"
  echo -e "  ${G}http://${ip}/${N}                       ← Хаб"
  echo -e "  ${G}http://${ip}/public/newswriter.html${N}  ← AI News Writer"
  echo -e "  ${G}http://${ip}/wm/${N}                    ← Watermarker Pro"
  echo -e "  ${G}http://${ip}:8000/dashboard.html${N}    ← NewsMon"
  echo
  echo -e "  ${W}Наступний крок — авторизація Telegram (NewsMon):${N}"
  echo -e "  1. Відкрий ${C}http://${ip}:8000/dashboard.html${N}"
  echo -e "  2. Пройди авторизацію через веб-інтерфейс"
  echo -e "  3. Або дивись: ${C}${CFG_NEWSMON_DIR}/INSTALL.md${N}"
  echo
  echo -e "  ${W}Корисні команди:${N}"
  echo -e "  ${C}journalctl -u newsmon -f${N}           ← логи NewsMon"
  echo -e "  ${C}journalctl -u watermarker -f${N}       ← логи Watermarker"
  echo -e "  ${C}sudo tail -f /var/log/nginx/error.log${N}"
  echo -e "  ${C}${SCRIPT_DIR}/update-all.sh${N}        ← оновити всі сервіси"
  echo
  echo -e "  ${W}NewsMon API токен (/etc/newsmon.env):${N}"
  echo -e "  ${Y}${CFG_NEWSMON_TOKEN}${N}"
  echo
  echo -e "  ${W}Пароль управління хабом (/etc/sysapi.env):${N}"
  echo -e "  ${Y}${CFG_SYSAPI_PASS}${N}"
  echo -e "  ${C}→ вводиш у хабі при першому натисканні ↺ або ↑${N}"
  echo -e "  ${C}→ змінити: sudo nano /etc/sysapi.env → sudo systemctl restart sysapi${N}"
  echo
  echo -e "  Лог встановлення: ${C}${LOG_FILE}${N}"
  echo
}

# ── Main ─────────────────────────────────────────────────────

main() {
  banner
  check_prereqs
  gather_config
  confirm_plan
  install_packages
  setup_newsmon
  setup_ainewswriter
  setup_watermarker
  setup_hub_nginx
  setup_sysapi
  setup_systemd
  setup_backup
  verify_all
  show_summary
}

main "$@"
