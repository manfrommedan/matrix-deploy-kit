# Matrix Server — Deployment Kit

[![Matrix](https://img.shields.io/badge/Matrix-Server-blue)]()
[![Docker](https://img.shields.io/badge/Docker-ready-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

Полный набор скриптов для быстрого развёртывания **Matrix homeserver**  
на базе:

https://github.com/spantaleev/matrix-docker-ansible-deploy

---

# Contents

- [Overview](#overview)
- [Structure](#structure)
- [Quick Start](#quick-start)
- [DNS Setup](#dns-setup)
- [Server Preparation](#server-preparation)
- [Matrix Deployment](#matrix-deployment)
- [Create Admin](#create-admin)
- [Updating](#updating)
- [Requirements](#requirements)

---

# Overview

`matrix-deploy-kit` — это набор утилит, который:

- автоматизирует установку Matrix
- подготавливает сервер
- настраивает nginx / Traefik
- добавляет landing page
- упрощает обновления

---

# Structure

```
matrix-deploy-kit/
├── deploy.sh                       # bootstrap: клон плейбука + tools/templates + генератор
├── tools/
│   ├── generate_vars.sh            # интерактивный генератор vars.yml
│   ├── prepare_server.sh           # подготовка сервера (nginx/certbot/docker/ansible/just)
│   ├── update.sh                   # обновление стека
│   ├── backup.sh                   # бэкап (pg_dumpall + конфиги)
│   ├── restore.sh                  # восстановление из снимка backup.sh
│   ├── nuke-user.sh                # полное удаление пользователя
│   ├── tune-system.sh              # тюнинг ОС
│   └── migrate-to-compose-v2.sh    # разовая миграция docker-compose v1 → v2
├── templates/
│   ├── index.html                  # landing page (matrix.DOMAIN)
│   ├── tos.html                    # Terms of Service (/tos)
│   └── error.html                  # страница 502/503/504
├── bots/
│   └── expire-bot/                 # бот авто-экспирации аккаунтов
└── docs/
```

---

# Quick Start

Выполняй по порядку, сверху вниз.

## 1. DNS (заранее)

A-записи на IP сервера — подробности в [DNS Setup](#dns-setup) ниже. Без рабочего DNS
`prepare_server.sh` не выпустит SSL.

## 2. Залить kit на сервер

```bash
scp -r matrix-deploy-kit/ root@<SERVER_IP>:/root/matrix-deploy-kit/
```

## 3. Bootstrap — клон плейбука + генератор конфига

```bash
ssh root@<SERVER_IP>
apt-get install -y git                  # если git ещё не стоит
bash /root/matrix-deploy-kit/deploy.sh
```

Клонирует `matrix-docker-ansible-deploy`, копирует в него `tools/` и `templates/`,
запускает интерактивный генератор `vars.yml`.

## 4. Подготовка сервера — Docker, nginx, SSL

```bash
bash /root/matrix-docker-ansible-deploy/tools/prepare_server.sh \
  --domain example.com [опции]
```

Флаги и режимы (nginx / Traefik-only, LiveKit-порты, ntfy, landing) — в
[Server Preparation](#server-preparation).

## 5. Деплой

```bash
cd /root/matrix-docker-ansible-deploy
export LC_ALL=C.UTF-8
just roles
just install-all
```

## 6. Создать администратора

```bash
docker exec matrix-authentication-service \
  mas-cli manage register-user --yes admin --password '<ПАРОЛЬ>' --admin
```

Готово — заходи на `https://element.example.com`.

---

# DNS Setup

> Настрой **до** шага 4 (Server Preparation) — `prepare_server.sh` выпускает SSL
> через certbot по этим записям и делает DNS-предпроверку.

Минимальные A-записи (все → IP сервера):

```
example.com
matrix.example.com
element.example.com
```

Опционально (с флагом `--with-ntfy`):

```
ntfy.example.com
```

LiveKit работает по path-маршрутизации через `matrix.example.com/livekit-jwt-service` — отдельный поддомен не нужен.

---

# Server Preparation

## nginx + certbot (recommended)

```bash
bash tools/prepare_server.sh \
  --domain example.com \
  --ketesa-port 35805 \
  --element-admin-port 35122 \
  --livekit-rtc-tcp 23249 \
  --livekit-rtc-udp 18674 \
  --livekit-turn-tls 11377 \
  --livekit-turn-udp 34556 \
  --with-ntfy \
  --with-landing-page
```

Что настраивается:

- nginx reverse proxy
- certbot SSL (включая `ntfy.example.com` если `--with-ntfy`)
- landing page
- скрытые admin панели (Ketesa, Element Admin)
- **LiveKit** (аудио/видео звонки через Element Web и Element X) — 4 нестандартных порта в файрволе
- **ntfy** (push-уведомления для Element X / FluffyChat)

Порты LiveKit можно подобрать любые свободные (1024-65535) - они выписываются в файрвол. Порядок флагов: ICE/TCP, ICE/UDP, TURN/TLS, TURN/UDP.

---

## Traefik-only mode

```bash
bash tools/prepare_server.sh \
  --domain example.com \
  --traefik-only \
  --livekit-rtc-tcp 23249 \
  --livekit-rtc-udp 18674 \
  --livekit-turn-tls 11377 \
  --livekit-turn-udp 34556 \
  --with-ntfy
```

Особенности:

- SSL через Traefik
- меньше компонентов
- проще конфигурация

---

# Matrix Deployment

```bash
cd /root/matrix-docker-ansible-deploy

export LC_ALL=C.UTF-8

just roles
just install-all
```

---

# Create Admin

```bash
docker exec matrix-authentication-service \
  mas-cli manage register-user \
  --yes admin \
  --password <PASSWORD> \
  --admin
```

---

# Updating

```bash
cd /root/matrix-docker-ansible-deploy

bash tools/update.sh
```

---

# Requirements

Минимальные требования:

- Ubuntu **20.04+**
- Debian **11+**
- **2GB RAM** минимум (4GB рекомендуется)

Открытые порты:

```
80     HTTP (certbot)
443    HTTPS
8448   Federation (если не через 443)
<LiveKit RTC TCP>    SFU TCP (по флагу --livekit-rtc-tcp)
<LiveKit RTC UDP>    SFU UDP (по флагу --livekit-rtc-udp)
<LiveKit TURN TLS>   TURN TLS (по флагу --livekit-turn-tls)
<LiveKit TURN UDP>   TURN UDP (по флагу --livekit-turn-udp)
```

`prepare_server.sh` сам открывает LiveKit порты в `ufw` если они переданы флагами.

---

# Based on

Matrix deployment stack:

https://github.com/spantaleev/matrix-docker-ansible-deploy
