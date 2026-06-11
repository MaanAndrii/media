# Розгортання трьох сервісів на одному Raspberry Pi 5 (єдина точка входу)

> Оновлено: 11 червня 2026 · версія 1.0
> Ціль: підняти NewsMon, AI News Writer і Watermarker Pro на одному Raspberry Pi 5
> за спільним nginx із хаб-сторінкою як проміжним інтерфейсом.

---

## 0) Архітектура

```
                        Браузер (LAN)
                             │
              ┌──────────────┼──────────────────┐
              │              │                  │
        http://IP/     http://IP/wm/      http://IP:8000/
              │              │                  │
        ┌─────▼──────────────▼─────┐            │
        │       nginx :80          │            │
        │  /          → хаб        │            │
        │  /public/   → PHP        │            │
        │  /admin/    → PHP        │            │
        │  /api/*.php → PHP        │            │
        │  /wm/       → :8501 (WS) │            │
        │  /health/*  → статуси    │            │
        └─────┬──────────────┬─────┘            │
              │              │                  │
        ┌─────▼─────┐  ┌─────▼───────┐  ┌───────▼───────┐
        │  php-fpm  │  │  Streamlit  │  │    uvicorn    │
        │ainewswriter│ │ watermarker │  │    newsmon    │
        │unix socket│  │127.0.0.1:8501│ │  0.0.0.0:8000 │
        └───────────┘  └─────────────┘  └───────────────┘
              ▲              ▲                  ▲
              └──────── systemd: автозапуск, рестарти, journalctl
```

**Чому NewsMon не за проксі-підшляхом.** Його фронтенд (dashboard.html,
settings.html) звертається до API за абсолютними шляхами `/api/...`, а шлях
`/api/` на порту 80 вже зайнятий PHP-папкою `api/` проєкту ainewswriter.
Тому NewsMon працює на власному порту 8000 — хаб приховує це від
користувача (картка на хабі веде одразу на потрібну адресу).

---

## 1) Вимоги

### Апаратні

- Raspberry Pi 5 (4+ GB RAM, рекомендовано 8 GB).
- SSD через USB 3.0 (бажано) або microSD.
- Стабільне живлення (офіційний БЖ 5V/5A для Pi 5).
- Статична IP-адреса в локальній мережі (DHCP reservation на роутері).

### Програмні

- Raspberry Pi OS Lite (64-bit).
- Python 3.11+, PHP 8.3/8.4, Git, nginx.
- Для NewsMon: Telegram `API ID`, `API Hash`, номер телефону.
- Для AI-функцій: API-ключі Anthropic / xAI / Google (за потреби).

### Припущення щодо шляхів

У всіх конфігах цього репозиторію зашиті такі шляхи. Якщо у вас інший
користувач — замініть `maan` у юнітах systemd і в `update-all.sh`.

| Що | Де |
|---|---|
| Цей репо (media) | `/home/maan/media` |
| NewsMon | `/home/maan/newsmon` |
| Watermarker Pro | `/home/maan/watermarker-pro` |
| AI News Writer | `/var/www/ainewswriter` |
| Хаб-сторінка | `/var/www/hub` |

---

## 2) Підготовка системи

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y git nginx php-fpm php-cli php-curl \
  python3 python3-venv python3-pip sqlite3
```

Перевір версії — версія PHP знадобиться у розділі 6:

```bash
python3 --version
php -v
nginx -v
```

Клонуй цей репозиторій:

```bash
cd /home/maan
git clone https://github.com/MaanAndrii/media.git
```

---

## 3) NewsMon

### 3.1. Клонування і залежності

```bash
cd /home/maan
git clone https://github.com/MaanAndrii/newsmon.git
cd newsmon/backend
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
```

### 3.2. Перенесення стану зі старого Pi (якщо мігруєш)

**Важливо:** перенеси БД і Telethon-сесію — тоді не доведеться заново
проходити авторизацію Telegram і не втратиться історія повідомлень.

На **старому** Pi:

```bash
sudo systemctl stop newsmon
scp /home/maan/newsmon/backend/newsmon.db \
    /home/maan/newsmon/backend/telegram_user.session \
    maan@<IP_НОВОГО_PI>:/home/maan/newsmon/backend/
```

На **новому** Pi перевір права:

```bash
sudo chown maan:maan /home/maan/newsmon/backend/newsmon.db
chmod 600 /home/maan/newsmon/backend/telegram_user.session
```

Якщо розгортаєш з нуля — пропусти цей крок і пройди Telethon-авторизацію
через UI після запуску (див. INSTALL.md у репозиторії newsmon, розділ 6).

### 3.3. Адмін-токен (обов'язково)

```bash
openssl rand -hex 32
sudo install -m 600 -o maan -g maan /dev/null /etc/newsmon.env
echo 'NEWSMON_API_TOKEN=ВСТАВ_СЮДИ_ЗГЕНЕРОВАНИЙ_ТОКЕН' | sudo tee /etc/newsmon.env > /dev/null
sudo chmod 600 /etc/newsmon.env
```

### 3.4. systemd

Юніт із цього репо вже містить `EnvironmentFile=/etc/newsmon.env`,
окремий override не потрібен:

```bash
sudo cp /home/maan/media/systemd/newsmon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now newsmon
sudo systemctl status newsmon --no-pager
```

### 3.5. Перевірка

```bash
curl -s http://127.0.0.1:8000/api/monitor/status | python3 -m json.tool
curl -s http://127.0.0.1:8000/api/telethon/session/health | python3 -m json.tool
```

---

## 4) AI News Writer

### 4.1. Клонування і права

```bash
sudo mkdir -p /var/www
cd /var/www
sudo git clone https://github.com/MaanAndrii/ainewswriter.git
sudo chown -R www-data:www-data /var/www/ainewswriter
sudo find /var/www/ainewswriter -type d -exec chmod 755 {} \;
sudo find /var/www/ainewswriter -type f -exec chmod 644 {} \;
```

### 4.2. Локальні змінні

```bash
sudo bash -c 'cat > /var/www/ainewswriter/.env.local <<EOF
ADMIN_PASSWORD=зміни-мене-зараз
ANTHROPIC_API_KEY=
XAI_API_KEY=
EOF'
sudo chown www-data:www-data /var/www/ainewswriter/.env.local
sudo chmod 600 /var/www/ainewswriter/.env.local
```

> Конфіг nginx із README ainewswriter **не створюй** — замість нього
> у розділі 6 підключається спільний `pi-services.conf` з цього репо.

---

## 5) Watermarker Pro

```bash
cd /home/maan
git clone https://github.com/MaanAndrii/watermarker-pro.git
cd watermarker-pro
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
```

systemd:

```bash
sudo cp /home/maan/media/systemd/watermarker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now watermarker
sudo systemctl status watermarker --no-pager
```

Перевірка:

```bash
curl -s http://127.0.0.1:8501/wm/_stcore/health
# очікуваний вивід: ok
```

**Два критичні прапорці в юніті** (вже прописані, нічого міняти не треба):

- `--server.baseUrlPath wm` — без нього Streamlit не працює на підшляху
  `/wm/`: фронтенд формує неправильні URL для WebSocket.
- `--server.address 127.0.0.1` — сервіс доступний лише через nginx,
  прямий порт 8501 назовні не відкритий.

---

## 6) Хаб і єдиний nginx

### 6.1. Хаб-сторінка

```bash
sudo mkdir -p /var/www/hub
sudo cp /home/maan/media/hub/index.html /var/www/hub/
```

### 6.2. Конфіг nginx

```bash
sudo cp /home/maan/media/nginx/pi-services.conf /etc/nginx/sites-available/
```

У конфігу зашитий сокет `php8.4-fpm.sock`. Якщо `php -v` показав 8.3:

```bash
sudo sed -i 's/php8.4-fpm.sock/php8.3-fpm.sock/' /etc/nginx/sites-available/pi-services.conf
```

Увімкнення:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/pi-services.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

### 6.3. Що робить конфіг

| Локація | Призначення |
|---|---|
| `/` | хаб-сторінка з `/var/www/hub` |
| `/public/`, `/admin/`, `*.php` | ainewswriter за його рідними шляхами |
| `/wm/` | проксі на Streamlit :8501 з WebSocket-заголовками і `client_max_body_size 500m` |
| `/health/news` | проксі на `:8000/api/monitor/status` (для статус-крапки хаба) |
| `/health/wm` | проксі на `:8501/wm/_stcore/health` |
| `/health/writer` | віддає головний HTML PHP-проєкту (живість nginx-стека) |

Хаб опитує `/health/*` кожні 15 секунд. Оскільки запити йдуть на той самий
домен, CORS-проблем немає.

---

## 7) Наскрізна перевірка після деплою

З самого Pi:

```bash
curl -I  http://127.0.0.1/                           # 200 — хаб
curl -s  http://127.0.0.1/health/news | head -c 200  # JSON від NewsMon
curl -s  http://127.0.0.1/health/wm                  # ok
curl -I  http://127.0.0.1/health/writer              # 200
curl -I  http://127.0.0.1/public/newswriter.html     # 200
curl -I  http://127.0.0.1/wm/                        # 200
curl -s  http://127.0.0.1:8000/api/messages?limit=3  # повідомлення NewsMon
```

З робочого комп'ютера в LAN:

1. Відкрий `http://<IP_PI>/` — три картки, всі крапки зелені
   (`active (running)`).
2. NewsMon: дашборд показує стрічку, у `settings.html` працює вхід
   за адмін-токеном.
3. AI News Writer: відкривається `/public/newswriter.html` і адмінка
   `/admin/admin.php`.
4. Watermarker: завантаж 2–3 зображення через `/wm/` і прожени повну
   обробку — це перевіряє WebSocket через проксі (найвразливіше місце).

---

## 8) Порядок міграції зі старих Pi

1. Підніми все на новому Pi **паралельно** зі старими (розділи 2–7).
2. Поганяй обидві системи день-два, порівнюй результати.
3. Переключи закладки/колег на новий хаб.
4. Вимкни сервіси на старих Pi, але не стирай їх ще тиждень — це твій
   план відкату.

---

## 9) Бекапи

Усі дані тепер на одному диску — достатньо одного завдання:

```bash
mkdir -p /home/maan/backups
cat > /home/maan/backup.sh <<'EOF'
#!/usr/bin/env bash
set -e
TS=$(date +%F_%H-%M-%S)
DEST=/home/maan/backups/$TS
mkdir -p "$DEST"
sqlite3 /home/maan/newsmon/backend/newsmon.db ".backup '$DEST/newsmon.db'"
cp /home/maan/newsmon/backend/telegram_user.session "$DEST/" 2>/dev/null || true
sudo cp /etc/newsmon.env "$DEST/"
sudo cp /var/www/ainewswriter/.env.local "$DEST/ainewswriter.env.local"
sudo chown -R maan:maan "$DEST"
# тримати останні 14 бекапів
ls -dt /home/maan/backups/*/ | tail -n +15 | xargs -r rm -rf
EOF
chmod +x /home/maan/backup.sh
```

Щоденний запуск о 03:30 через cron:

```bash
(crontab -l 2>/dev/null; echo "30 3 * * * /home/maan/backup.sh") | crontab -
```

> `sqlite3 .backup` робить консистентну копію навіть під час роботи
> сервісу — на відміну від простого `cp` живого файлу БД.
> Бажано періодично копіювати `/home/maan/backups` на інший носій.

---

## 10) Оновлення

### Оновлення сервісів (код трьох проєктів)

```bash
cd /home/maan/media && git pull
./update-all.sh              # усі три
./update-all.sh newsmon      # або вибірково: newsmon | watermarker | writer
```

Скрипт для кожного проєкту: `git pull --rebase` → оновлення pip-залежностей
→ рестарт сервісу → перевірка `is-active`. Для ainewswriter pull іде від
`www-data`, версію php-fpm скрипт визначає сам.

### Оновлення конфігурації (файли цього репо)

`git pull` репозиторію media **не застосовує** конфіги автоматично.
Після зміни відповідного файлу:

```bash
# nginx або хаб:
sudo cp /home/maan/media/nginx/pi-services.conf /etc/nginx/sites-available/
sudo cp /home/maan/media/hub/index.html /var/www/hub/
sudo nginx -t && sudo systemctl reload nginx

# юніти systemd:
sudo cp /home/maan/media/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart newsmon watermarker
```

---

## 11) Безпека

- Система розрахована на **локальну мережу**. Не пробрасуй порти 80/8000
  назовні через роутер без додаткового захисту (VPN/WireGuard, basic auth,
  HTTPS) — Watermarker і дашборд NewsMon не мають автентифікації.
- Адмін-функції захищені: NewsMon — токеном (`/etc/newsmon.env`),
  ainewswriter — `ADMIN_PASSWORD` у `.env.local`. Обидва файли мають
  права `600`.
- Ротація токена NewsMon: новий `openssl rand -hex 32` →
  правка `/etc/newsmon.env` → `sudo systemctl restart newsmon`.

---

## 12) Типові проблеми

### 1. На хабі червона крапка, але сервіс працює напряму

Перевір саме health-локацію і логи nginx:

```bash
curl -v http://127.0.0.1/health/news
sudo tail -n 50 /var/log/nginx/error.log
```

Найчастіша причина — сервіс слухає не ту адресу/порт, що в
`pi-services.conf`, або юніт не запущений (`systemctl status newsmon`).

### 2. `/wm/` відкривається, але "крутиться" і не вантажиться

Це WebSocket. Перевір, що в локації `/wm/` є рядки `proxy_http_version 1.1`,
`Upgrade` і `Connection "upgrade"`, і що юніт містить
`--server.baseUrlPath wm`. Після правок:

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart watermarker
```

### 3. `502 Bad Gateway` на PHP-сторінках

Не той сокет php-fpm. Подивись фактичний:

```bash
ls /run/php/
```

і випр. шлях у `pi-services.conf` (розділ 6.2), потім
`sudo nginx -t && sudo systemctl reload nginx`.

### 4. NewsMon: `503 «Сервер не налаштовано»`

Процес не бачить `NEWSMON_API_TOKEN`. Перевір:

```bash
sudo systemctl cat newsmon | grep EnvironmentFile
ls -l /etc/newsmon.env        # має бути 600, власник maan
PID=$(pgrep -f 'uvicorn app:app' | head -1)
sudo tr '\0' '\n' < /proc/$PID/environ | grep NEWSMON_API_TOKEN
```

Після правок — `sudo systemctl daemon-reload && sudo systemctl restart newsmon`.

### 5. NewsMon: помилки Telethon-сесії після міграції

Найчастіше — права на session-файл:

```bash
sudo chown maan:maan /home/maan/newsmon/backend/telegram_user.session*
chmod 600 /home/maan/newsmon/backend/telegram_user.session
sudo systemctl restart newsmon
curl -s http://127.0.0.1:8000/api/telethon/session/health | python3 -m json.tool
```

Якщо сесія невалідна — видали session-файли і пройди авторизацію заново
(детально: newsmon/INSTALL.md, розділ 13).

### 6. Watermarker: помилка при завантаженні великого пакета файлів

Перевищено ліміт тіла запиту. У `pi-services.conf` в локації `/wm/`
збільш `client_max_body_size` (типово 500m) і перезавантаж nginx.

### 7. Хаб відкривається, а `/public/newswriter.html` — 404

Перевір, що проєкт зклоновано саме у `/var/www/ainewswriter` і права
виставлені (розділ 4.1):

```bash
ls -l /var/www/ainewswriter/public/newswriter.html
```

### Логи — головний інструмент діагностики

```bash
journalctl -u newsmon -f
journalctl -u watermarker -f
journalctl -u php8.4-fpm -f      # або php8.3-fpm
sudo tail -f /var/log/nginx/error.log
```
