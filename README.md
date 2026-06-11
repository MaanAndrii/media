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

## Швидкий старт

Повна покрокова інструкція — у [DEPLOY.md](DEPLOY.md). Якщо коротко:

```bash
cd /home/maan
git clone https://github.com/MaanAndrii/media.git
# далі — за DEPLOY.md, розділи 2–8
```

## Оновлення вже розгорнутої системи

```bash
cd /home/maan/media && git pull
./update-all.sh              # усі сервіси
./update-all.sh watermarker  # або вибірково: newsmon | watermarker | writer
```

> Конфіги nginx/systemd/hub після `git pull` цього репо **не** застосовуються
> автоматично — їх треба скопіювати і перезапустити сервіси (DEPLOY.md, розділ 10).
