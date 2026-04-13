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
  --with-ntfy \
  --with-landing-page
```

Что настраивается:

- nginx reverse proxy
- certbot SSL
- landing page
- скрытые admin панели

---

## Traefik-only mode

```bash
bash tools/prepare_server.sh \
  --domain example.com \
  --traefik-only \
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

Минимальные записи:

```
example.com
matrix.example.com
element.example.com
```

Опционально:

```
ntfy.example.com
```

Все записи должны указывать на IP сервера.

---

# Requirements

Минимальные требования:

- Ubuntu **20.04+**
- Debian **11+**
- **2GB RAM** минимум (4GB рекомендуется)

Открытые порты:

```
80
443
8448
```

---

# Based on

Matrix deployment stack:

https://github.com/spantaleev/matrix-docker-ansible-deploy
