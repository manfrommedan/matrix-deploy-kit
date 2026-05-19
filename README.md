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
- [Server Preparation](#server-preparation)
- [Matrix Deployment](#matrix-deployment)
- [Create Admin](#create-admin)
- [Updating](#updating)
- [DNS Setup](#dns-setup)
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
├── deploy.sh
├── tools/
│   ├── generate_vars.sh
│   ├── prepare_server.sh
│   ├── update.sh
│   └── nuke-user.sh
└── templates/
    ├── index.html
    └── tos.html
```

---

# Quick Start

## 1. Upload to server

```bash
scp -r matrix-deploy-kit/ \
  root@<SERVER_IP>:/root/matrix-deploy-kit/
```

---

## 2. Run deployment

```bash
ssh root@<SERVER_IP>

bash /root/matrix-deploy-kit/deploy.sh
```

Скрипт:

- клонирует matrix playbook
- копирует tools
- копирует templates
- запускает генератор `vars.yml`

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

# DNS Setup

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

LiveKit работает по path-маршрутизации через `matrix.example.com/livekit-jwt-service` - отдельный поддомен не нужен.

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
