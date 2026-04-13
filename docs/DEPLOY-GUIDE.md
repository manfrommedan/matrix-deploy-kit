# Matrix Server — Пошаговый гайд по развёртыванию

## Что ты получишь

Полноценный Matrix-сервер с:
- **Synapse** — сервер обмена сообщениями (федерация с другими серверами)
- **Element Web** — веб-клиент (как Telegram Web, только свой)
- **Аудио/видео звонки** — через LiveKit (WebRTC)
- **Push-уведомления** — через ntfy (без Google)
- **Admin-панели** — Ketesa + Element Admin
- **Мосты** — Telegram, WhatsApp, Signal, Discord и другие
- **Боты** — модерация, вебхуки, поддержка

---

## Требования

| Что | Минимум | Рекомендуется |
|-----|---------|---------------|
| ОС | Ubuntu 20.04 / Debian 11 | Ubuntu 22.04+ |
| RAM | 2 GB | 4+ GB |
| Диск | 20 GB | 50+ GB |
| CPU | 1 ядро | 2+ ядра |
| Домен | 1 домен | с настроенным DNS |
| Порты | 80, 443, 8448 | + порты для звонков (LiveKit, Coturn) |

---

## Шаг 1. DNS записи

Создай A-записи (все указывают на IP твоего сервера):

```
example.com            → IP    (базовый домен, .well-known)
matrix.example.com     → IP    (Synapse homeserver)
element.example.com    → IP    (Element Web клиент)
```

Опционально:
```
ntfy.example.com       → IP    (push-уведомления, если включишь)
```

### SRV-запись для федерации (альтернатива .well-known)

Если не хочешь обслуживать `.well-known/matrix/server` на базовом домене (например, скрыть что это Matrix-сервер), добавь SRV-запись:

```
Тип:        SRV
Имя:        _matrix-fed._tcp
Приоритет:  10
Вес:        0
Порт:       443
Цель:       matrix.example.com
```

Проверка:
```bash
dig SRV _matrix-fed._tcp.example.com
```

> **Нюансы**:
> - SRV заменяет только серверный discovery (федерация). Клиентский discovery (`.well-known/matrix/client`) SRV **не заменяет** — пользователи должны вводить `matrix.example.com` при логине вручную.
> - SRV-запись публична — `dig` покажет что на домене Matrix. Для полного скрытия это не поможет.

> **Важно**: `example.com` — это твой bare-домен. Matrix ID пользователей будет `@user:example.com`.

---

## Шаг 2. Скопируй deploy kit на сервер

```bash
scp -r matrix-deploy-kit/ root@<IP>:/root/matrix-deploy-kit/
```

---

## Шаг 3. Запусти bootstrap

```bash
ssh root@<IP>
bash /root/matrix-deploy-kit/deploy.sh
```

Что произойдёт:
1. Клонирует playbook `matrix-docker-ansible-deploy`
2. Скопирует tools/ и templates/
3. Запустит интерактивный генератор `vars.yml`

---

## Шаг 4. Генератор vars.yml

Генератор проведёт тебя через 12 шагов:

| Шаг | Что настраивается | На что влияет |
|-----|-------------------|---------------|
| 1 | Домен | Адреса всех сервисов |
| 2 | Reverse Proxy | nginx+Traefik или Traefik-only |
| 3 | Сеть и доступ | Федерация, гостевой доступ |
| 4 | Аутентификация (MAS) | Регистрация, SSO, ToS |
| 5 | Компоненты | Звонки, admin, Coturn, ntfy |
| 6 | Мосты | Telegram, WhatsApp, Signal... |
| 7 | Боты | Модерация, вебхуки |
| 8 | Хранение | Retention, auto-compressor |
| 9 | Email (SMTP) | Уведомления, сброс пароля |
| 10 | Производительность | Workers, presence, логи |
| 11 | Безопасность | Federation на 443, DPI |
| 12 | Итоги | Сводка + команды |

На каждом шаге — подсказки и значения по умолчанию. Просто жми Enter для рекомендуемых значений.

---

## Шаг 5. Подготовка сервера

```bash
bash tools/prepare_server.sh --domain example.com \
  --ketesa-port 35805 \
  --element-admin-port 35122 \
  --with-landing-page \
  --with-ntfy
```

Что произойдёт:
- Обновит систему
- Создаст deploy-пользователя
- Установит Docker, Ansible, nginx, certbot
- Получит SSL-сертификаты
- Настроит nginx (reverse proxy → Traefik)
- Скопирует landing page и страницу ошибок

### Флаги prepare_server.sh

| Флаг | Что делает |
|------|-----------|
| `--domain DOMAIN` | **(обязательно)** Домен сервера |
| `--ketesa-port PORT` | Ketesa на скрытом порту |
| `--element-admin-port PORT` | Element Admin на скрытом порту |
| `--with-landing-page` | Landing page на matrix.DOMAIN |
| `--with-ntfy` | Поддомен ntfy.DOMAIN |
| `--traefik-only` | Без nginx (Traefik сам управляет SSL) |
| `--with-firewall` | Настроить ufw |
| `--with-fail2ban` | Установить fail2ban |
| `--with-ssh-hardening` | Укрепить SSH |
| `--skip-docker` | Не ставить Docker (плейбук поставит) |
| `--skip-swap` | Не создавать swap |
| `--swap-size SIZE` | Размер swap (по умолчанию 2G) |
| `--federation-on-443` | Федерация на 443 (не генерировать 8448 nginx-блок) |
| `--coturn-stun PORT` | Кастомный STUN порт для ufw (по умолчанию 3478) |
| `--coturn-turns PORT` | Кастомный TURNS порт для ufw (по умолчанию 5349) |
| `--livekit-rtc-tcp PORT` | LiveKit RTC TCP порт для ufw |
| `--livekit-turn-tls PORT` | LiveKit TURN TLS порт для ufw |
| `--dry-run` | Показать план без выполнения |

### Шаг 5.1. TLS-сертификаты для звонков (nginx-режим)

В nginx+Traefik режиме Traefik не управляет ACME-сертификатами, поэтому LiveKit
и Coturn не могут получить TLS-серты от Traefik. `prepare_server.sh` решает это
автоматически:

1. Копирует certbot-серты в `${DATA_PATH}/livekit-server/certs/` и `${DATA_PATH}/coturn/certs/`
2. Устанавливает владельца `matrix:matrix` (UID/GID определяется динамически)
3. Создаёт certbot renewal hook (`/etc/letsencrypt/renewal-hooks/post/restart-matrix-tls.sh`), который при обновлении сертов автоматически копирует их и перезапускает LiveKit, Coturn, nginx

> **Если `prepare_server.sh` запускается до первого деплоя** (пользователь `matrix`
> ещё не создан), серты получат владельца `root:root`. Ansible исправит владельца
> при деплое.

> **Если запускаете повторно после деплоя**, используйте `--data-path` для указания
> расположения данных Matrix (по умолчанию `/matrix`).

---

## Шаг 6. Деплой

```bash
cd /root/matrix-docker-ansible-deploy
export LC_ALL=C.UTF-8
just roles        # скачать Ansible-роли
just install-all  # развернуть всё
```

Займёт 5-15 минут в зависимости от сервера. Ansible:
- Скачает Docker-образы
- Создаст контейнеры и systemd-юниты
- Настроит Traefik, Synapse, Element Web, PostgreSQL
- Запустит все сервисы

---

## Шаг 7. Создание администратора

```bash
# С MAS (рекомендуется):
docker exec matrix-authentication-service \
  mas-cli manage register-user --yes admin --password '<ПАРОЛЬ>' --admin

# Без MAS:
docker exec matrix-synapse \
  register_new_matrix_user -u admin -p '<ПАРОЛЬ>' -a -c /data/homeserver.yaml http://localhost:8008
```

---

## Шаг 8. Проверка

Открой в браузере:
- `https://element.example.com` — веб-клиент (войди как admin)
- `https://matrix.example.com:35805` — Ketesa (если настроил)
- `https://matrix.example.com:35122` — Element Admin (если настроил)

Проверка федерации:
- https://federationtester.matrix.org — введи свой домен

---

## Обновление

```bash
cd /root/matrix-docker-ansible-deploy
bash tools/update.sh
```

Скрипт:
- Сделает бэкап текущей конфигурации
- Обновит playbook (git pull)
- Запустит `just install-all`
- Синхронизирует TLS-серты для LiveKit/Coturn (nginx-режим)
- Проверит что все контейнеры живы
- При ошибке — откатит автоматически

Только синхронизация сертов (без обновления):
```bash
bash tools/update.sh --sync-certs
```

---

## Удаление пользователя

```bash
bash tools/nuke-user.sh @user:example.com
```

Полностью удалит пользователя: аккаунт, сессии, устройства, данные.

---

## Полезные команды

```bash
# Статус контейнеров
docker ps --format "table {{.Names}}\t{{.Status}}"

# Логи конкретного сервиса
journalctl -fu matrix-synapse
journalctl -fu matrix-authentication-service

# Перезапуск одного сервиса
systemctl restart matrix-synapse

# Перезапуск всего
cd /root/matrix-docker-ansible-deploy
just run-tags start

# Обновить только Synapse (быстро)
just run-tags setup-synapse,start

# Бэкап базы данных
docker exec matrix-postgres pg_dumpall -U matrix > /root/matrix-backup.sql
```

---

## Структура на сервере

```
/root/matrix-docker-ansible-deploy/    # Ansible-плейбук
├── inventory/host_vars/matrix.*/
│   └── vars.yml                       # ← ТВОЯ КОНФИГУРАЦИЯ
├── tools/
│   ├── generate_vars.sh               # Генератор vars.yml
│   ├── prepare_server.sh              # Подготовка сервера
│   ├── update.sh                      # Обновление
│   └── nuke-user.sh                   # Удаление пользователя
├── templates/
│   ├── index.html                     # Landing page
│   ├── tos.html                       # Terms of Service
│   └── error.html                     # Страница ошибки 502/503
└── ansible.cfg                        # Оптимизации Ansible

/matrix/                               # Данные сервисов (Docker volumes)
├── synapse/                           # Synapse homeserver
├── postgres/                          # PostgreSQL
├── traefik/                           # Traefik reverse proxy
├── element-web/                       # Element Web
├── coturn/                            # TURN/STUN сервер
└── ...

/etc/nginx/sites-available/matrix.conf # nginx конфиг (если nginx режим)
/var/www/matrix-landing/               # Landing page + error page
/etc/letsencrypt/                      # SSL сертификаты (certbot)
```

---

## Решение проблем

### MAS не запускается
```bash
journalctl -fu matrix-authentication-service --no-pager -n 50
```
Частая причина: `tos_uri: y` (вместо URL). Исправь в vars.yml.

### Долгий restart (Workers)
Много воркеров на слабой машинке. Смени пресет:
```yaml
matrix_synapse_workers_preset: little-federation-helper
```

### 502 Bad Gateway
Synapse или Traefik ещё не стартовали:
```bash
docker ps | grep matrix
systemctl restart matrix-synapse
```

### Федерация не работает
1. Проверь DNS: A-запись для `matrix.example.com`
2. Проверь порт 8448 открыт (если не `--federation-on-443`)
3. Проверь `.well-known/matrix/server` или SRV-запись `_matrix-fed._tcp.example.com`
4. Тест: https://federationtester.matrix.org

### Ускорение Ansible
```bash
pip3 install mitogen
# В ansible.cfg раскомментировать strategy = mitogen_linear
```
