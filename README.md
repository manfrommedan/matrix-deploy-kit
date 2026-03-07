# Matrix Server — Deployment Kit

Полный набор для развёртывания Matrix homeserver на базе  
[matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy).

---

## Структура

```
matrix-deploy-kit/
├── deploy.sh             # Одна команда — полный деплой
├── tools/
│   ├── generate_vars.sh  # Интерактивный генератор vars.yml
│   ├── prepare_server.sh # Подготовка сервера (nginx, certbot, docker, etc.)
│   ├── update.sh         # Обновление + health check
│   └── nuke-user.sh      # Полное удаление пользователя
└── templates/
    ├── index.html        # Landing page (matrix.DOMAIN)
    └── tos.html          # Terms of Service
```

---

# Быстрый старт

## 1. Скопируй на сервер

```bash
scp -r matrix-deploy-kit/ \
  root@<SERVER_IP>:/root/matrix-deploy-kit/
```

## 2. Запусти деплой

```bash
ssh root@<SERVER_IP>

bash /root/matrix-deploy-kit/deploy.sh
```

Скрипт:

- клонирует playbook
- копирует `tools/`
- копирует `templates/`
- запускает интерактивный генератор `vars.yml`

---

# Подготовка сервера

## nginx + certbot (рекомендуется)

```bash
bash tools/prepare_server.sh \
  --domain example.com \
  --synapse-admin-port 35805 \
  --element-admin-port 35122 \
  --with-ntfy \
  --with-landing-page
```

Что делает:

- устанавливает nginx
- настраивает certbot
- создаёт landing page
- открывает скрытые admin-панели

---

## Traefik-only

```bash
bash tools/prepare_server.sh \
  --domain example.com \
  --traefik-only \
  --with-ntfy
```

В этом режиме:

- Traefik управляет SSL
- nginx не используется
- настройка проще

---

# Деплой Matrix

```bash
cd /root/matrix-docker-ansible-deploy

export LC_ALL=C.UTF-8

just roles
just install-all
```

---

# Создание администратора

```bash
docker exec matrix-authentication-service \
  mas-cli manage register-user \
  --yes admin \
  --password <PASSWORD> \
  --admin
```

---

# Обновление

```bash
cd /root/matrix-docker-ansible-deploy

bash tools/update.sh
```

---

# Архитектура

Поддерживаются два режима reverse proxy.

## nginx → Traefik (рекомендуется)

Преимущества:

- nginx терминирует SSL
- certbot управляет сертификатами
- admin-панели на скрытых портах
- можно использовать landing page

Используемые параметры:

```
--synapse-admin-port
--element-admin-port
```

---

## Traefik-only

Преимущества:

- меньше компонентов
- автоматический ACME SSL
- проще конфигурация

---

# Опциональные компоненты

| Флаг | Что включает |
|-----|-----|
| `--with-ntfy` | ntfy.DOMAIN — push уведомления |
| `--with-landing-page` | landing page + ToS |
| `--with-firewall` | настройка ufw |
| `--with-fail2ban` | fail2ban |
| `--with-ssh-hardening` | hardening SSH |

---

# DNS записи

Минимум:

```
example.com            → IP
matrix.example.com     → IP
element.example.com    → IP
```

Опционально:

```
ntfy.example.com → IP
```

---

# Требования

- Ubuntu **20.04+**
- Debian **11+**
- минимум **2 GB RAM** (рекомендуется 4 GB)
- настроенные DNS записи
- открытые порты:

```
80
443
8448
```
