# Matrix Server — Deployment Kit

Полный набор для развёртывания Matrix homeserver на базе
[matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy).

## Структура

```
matrix-deploy-kit/
├── deploy.sh              # Одна команда — полный деплой
├── tools/
│   ├── generate_vars.sh        # Интерактивный генератор vars.yml
│   ├── prepare_server.sh         # Подготовка сервера (nginx, certbot, docker, etc.)
│   ├── update.sh          # Обновление + health check
│   └── nuke-user.sh       # Полное удаление пользователя
└── templates/
    ├── index.html         # Landing page (matrix.DOMAIN)
    └── tos.html           # Terms of Service
```

## Быстрый старт

### 1. Скопируй на сервер

```bash
scp -r matrix-deploy-kit/ root@<SERVER_IP>:/root/matrix-deploy-kit/
```

### 2. Запусти деплой

```bash
ssh root@<SERVER_IP>
bash /root/matrix-deploy-kit/deploy.sh
```

Скрипт:
- Клонирует плейбук
- Копирует tools/ и шаблоны
- Запустит интерактивный генератор vars.yml

### 3. Подготовь сервер

```bash
# nginx + certbot (рекомендуется):
bash tools/prepare_server.sh --domain example.com \
  --synapse-admin-port 35805 \
  --element-admin-port 35122 \
  --with-ntfy \
  --with-landing-page

# Или traefik-only:
bash tools/prepare_server.sh --domain example.com --traefik-only --with-ntfy
```

### 4. Деплой

```bash
cd /root/matrix-docker-ansible-deploy
export LC_ALL=C.UTF-8
just roles
just install-all
```

### 5. Создай администратора

```bash
docker exec matrix-authentication-service \
  mas-cli manage register-user --yes admin --password <ПАРОЛЬ> --admin
```

## Обновление

```bash
cd /root/matrix-docker-ansible-deploy
bash tools/update.sh
```

## Архитектура

Два режима reverse proxy:

**nginx → Traefik** (рекомендуется):
- nginx терминирует SSL (certbot)
- Admin-панели на скрытых портах
- Landing page + ToS
- `--synapse-admin-port`, `--element-admin-port`

**Traefik-only**:
- Traefik управляет SSL через ACME
- Admin-панели через пути/поддомены
- Проще в настройке

## Опциональные компоненты

| Флаг | Что включает |
|------|-------------|
| `--with-ntfy` | ntfy.DOMAIN — push-уведомления |
| `--with-landing-page` | Landing page + ToS на matrix.DOMAIN |
| `--with-firewall` | Настройка ufw |
| `--with-fail2ban` | fail2ban |
| `--with-ssh-hardening` | Hardening SSH |

## DNS записи

Минимум (A-записи → IP сервера):
```
example.com            → IP   (stub + .well-known)
matrix.example.com     → IP   (Synapse homeserver)
element.example.com    → IP   (Element Web)
```

Опционально:
```
ntfy.example.com           → IP   (--with-ntfy)
```

## Требования

- Ubuntu 20.04+ / Debian 11+
- 2+ GB RAM (4+ рекомендуется)
- Домен с настроенными DNS записями
- Открытые порты: 80, 443, 8448
