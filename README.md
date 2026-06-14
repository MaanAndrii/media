# media — деплой-конфігурація Raspberry Pi 5

Інфраструктурний репозиторій, що об'єднує три незалежні проєкти на одному Raspberry Pi 5 за єдиною точкою входу (nginx + хаб-сторінка):

| Сервіс | Репозиторій | Стек | Доступ |
|---|---|---|---|
| Хаб | цей репо (`hub/`) | static HTML | `http://<IP_PI>/` |
| NewsMon | [MaanAndrii/newsmon](https://github.com/MaanAndrii/newsmon) | FastAPI + Telethon + SQLite | `http://<IP_PI>:8000/dashboard.html` |
| AI News Writer | [MaanAndrii/ainewswriter](https://github.com/MaanAndrii/ainewswriter) | PHP + nginx + php-fpm | `http://<IP_PI>/public/newswriter.html` |
| Watermarker Pro | [MaanAndrii/watermarker-pro](https://github.com/MaanAndrii/watermarker-pro) | Streamlit + Pillow | `http://<IP_PI>/wm/` |

## Структура

```
media/
├── nginx/
│   └── pi-services.conf      # єдиний конфіг nginx: хаб, PHP, /wm/, /health/*
├── systemd/
│   ├── newsmon.service       # юніт NewsMon (uvicorn :8000)
│   └── watermarker.service   # юніт Watermarker (streamlit :8501, baseUrlPath=wm)
├── hub/
│   └── index.html            # хаб-сторінка зі статус-індикаторами сервісів
├── update-all.sh             # оновлення всіх сервісів одним запуском
├── README.md
└── DEPLOY.md                 # повна інструкція розгортання
```

## Швидкий старт — wizard встановлення

Встанови `git`, клонуй репо і запусти wizard:

```bash
sudo apt install -y git
git clone https://github.com/MaanAndrii/media.git
cd media
bash setup.sh
```

Wizard у режимі питання–відповідь:
- встановить системні пакети (nginx, php, python3…)
- склонує та налаштує всі три сервіси
- згенерує токени і запише `.env`-файли
- застосує nginx-конфіг та systemd-юніти
- перевірить, що всі сервіси запустились

Після завершення: залишається лише авторизувати Telegram у NewsMon через веб-інтерфейс.

Повна покрокова інструкція (без wizard) — у [DEPLOY.md](DEPLOY.md).

## Оновлення вже розгорнутої системи

```bash
cd ~/media && git pull
./update-all.sh              # усі сервіси
./update-all.sh watermarker  # або вибірково: newsmon | watermarker | writer
```

> Конфіги nginx/systemd/hub після `git pull` **не** застосовуються автоматично —
> скопіюй і перезапусти (DEPLOY.md, розділ 10) або запусти `bash setup.sh` повторно.
