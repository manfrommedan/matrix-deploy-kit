# Matrix Server — Справочник параметров vars.yml

Этот файл описывает **все параметры**, которые можно настроить в `vars.yml`.
Генератор `generate_vars.sh` создаёт этот файл автоматически, но ты можешь
редактировать его вручную.

> **Путь к файлу**: `inventory/host_vars/matrix.<domain>/vars.yml`

---

## 1. Базовые параметры (нельзя менять после деплоя!)

```yaml
# Домен сервера. Matrix ID будут: @user:example.com
# НЕЛЬЗЯ менять после первого деплоя!
matrix_domain: example.com

# Главный секрет. Из него генерируются все остальные ключи.
# НЕЛЬЗЯ менять после деплоя! Генерировать: pwgen -s 64 1
matrix_homeserver_generic_secret_key: 'xxxxxxxxxxxxxxxxxxx'
```

---

## 2. База данных (PostgreSQL)

```yaml
# Пароль суперпользователя БД. Менять нежелательно.
postgres_connection_password: 'xxxxxxxxxxxxxxxxxxx'

# Автобэкапы (ежедневно в /matrix/postgres/backup/)
postgres_backup_enabled: true
```

---

## 3. Reverse Proxy

### Вариант A: nginx + Traefik (рекомендуется)

nginx на хосте терминирует SSL (certbot), проксирует в Traefik.
Admin-панели на скрытых портах, кастомные страницы ошибок.

```yaml
matrix_playbook_reverse_proxy_type: playbook-managed-traefik
matrix_playbook_ssl_enabled: true

# Traefik слушает только на localhost (nginx фронтит)
traefik_config_entrypoint_web_secure_enabled: false
traefik_config_entrypoint_web_secure_host_bind_port: ''
devture_traefik_container_web_host_bind_port: '127.0.0.1:81'
devture_traefik_container_ssl_host_bind_port: ''
devture_traefik_config_entrypoint_web_forwardedHeaders_insecure: true

# Federation entrypoint (nginx проксирует 8448 → 8449)
matrix_playbook_public_matrix_federation_api_traefik_entrypoint_host_bind_port: '127.0.0.1:8449'
matrix_playbook_public_matrix_federation_api_traefik_entrypoint_config_http3_enabled: false
```

### Вариант B: Traefik-only

Traefik сам управляет SSL через Let's Encrypt ACME. Проще, но меньше контроля.

```yaml
matrix_playbook_reverse_proxy_type: playbook-managed-traefik
# Всё остальное — по умолчанию
```

---

## 4. Synapse (homeserver)

```yaml
# Макс размер загружаемых файлов (МБ)
matrix_synapse_max_upload_size_mb: 100

# Предпросмотр ссылок (картинка + заголовок при отправке URL)
matrix_synapse_url_preview_enabled: true

# Статусы "онлайн/оффлайн" (отключение снижает нагрузку)
matrix_synapse_presence_enabled: true

# Уровень логирования: DEBUG, INFO, WARNING, ERROR
matrix_synapse_log_level: WARNING

# Включать содержимое сообщений в push-уведомления
matrix_synapse_push_include_content: true

# Перенаправление matrix.domain → element.domain в браузере
matrix_synapse_self_check_validate_certificates: true
```

---

## 5. Федерация

```yaml
# Включить связь с другими Matrix-серверами
# false = изолированный корпоративный мессенджер
matrix_homeserver_federation_enabled: true

# Whitelist — разрешить федерацию ТОЛЬКО с этими серверами
# Пусто (~) = все разрешены
matrix_synapse_federation_domain_whitelist:
  - 'matrix.org'
  - 'mozilla.org'

# Blacklist — заблокировать конкретные серверы (через extension)
matrix_synapse_configuration_extension_yaml: |
  federation_domain_blacklist:
    - 'evil.server.com'
    - 'spam.domain.net'
```

### Federation на порт 443 (маскировка)

По умолчанию федерация на порту 8448 (легко обнаружить). Перенос на 443
маскирует под обычный HTTPS, позволяет пропускать через Cloudflare CDN.

```yaml
matrix_synapse_http_listener_resource_names: ["client","federation"]
matrix_federation_public_port: 443
matrix_synapse_federation_port_enabled: false
matrix_synapse_tls_federation_listener_enabled: false

# ОБЯЗАТЕЛЬНО: entrypoint matrix-federation не существует при federation на 443
# nginx+Traefik: web / Traefik-only: web-secure
matrix_federation_traefik_entrypoint_name: web
```

---

## 6. Регистрация

### С MAS (рекомендуется)

```yaml
# MAS — современный сервис аутентификации
matrix_authentication_service_enabled: true

# Открытая регистрация (любой может создать аккаунт)
matrix_authentication_service_config_account_registration_enabled: true

# Обязательный email при регистрации
matrix_authentication_service_config_account_email_required: true

# Регистрация по токенам (invite-only)
matrix_authentication_service_config_account_registration_token_required: true

# ToS — чекбокс при регистрации
matrix_authentication_service_configuration_extension_yaml: |
  branding:
    tos_uri: 'https://matrix.example.com/tos'
```

### Без MAS

```yaml
# Открытая регистрация
matrix_synapse_enable_registration: true

# По токенам
matrix_synapse_registration_requires_token: true

# Создание пользователей вручную:
# docker exec matrix-synapse register_new_matrix_user \
#   -u USERNAME -p PASSWORD -a -c /data/homeserver.yaml http://localhost:8008
```

---

## 7. Гостевой доступ

```yaml
# Разрешить гостям участвовать в звонках (без аккаунта)
# Гости НЕ могут писать сообщения
matrix_synapse_allow_guest_access: true
```

---

## 8. Element Web (клиент)

```yaml
# Включить веб-клиент на element.example.com
matrix_client_element_enabled: true

# Кастомное название сервера в Element
matrix_client_element_brand: "My Matrix Server"

# Тема по умолчанию
matrix_client_element_default_theme: dark  # dark или light

# Показывать форму регистрации
matrix_client_element_registration_enabled: true
```

---

## 9. Звонки (LiveKit)

```yaml
# ГЛАВНЫЙ ПЕРЕКЛЮЧАТЕЛЬ — включает весь RTC-стек:
# LiveKit SFU → JWT-сервис → .well-known/matrix/client (rtc_foci)
matrix_rtc_enabled: true

# Кнопка звонков в Element Web (просто флаг в config.json, не отдельный сервис)
matrix_client_element_element_call_enabled: true

# Element Call Frontend — отдельная веб-страница для звонков
# НЕ нужна для звонков из Element Web/X (клиенты имеют встроенную поддержку)
matrix_element_call_enabled: false

# Порты LiveKit RTC (можно рандомизировать для защиты от сканирования)
livekit_server_container_rtc_tcp_bind_port: 7881    # ICE/TCP
livekit_server_container_rtc_udp_bind_port: 7882    # ICE/UDP
```

### LiveKit TURN TLS (nginx+Traefik режим)

В nginx+Traefik режиме Traefik не управляет ACME-сертификатами — LiveKit нужны
свои TLS-серты. `prepare_server.sh` копирует certbot-серты автоматически.

```yaml
# Встроенный TURN в LiveKit (терминирует TLS сам)
livekit_server_config_turn_enabled: true
livekit_server_config_turn_external_tls: false
livekit_server_config_turn_cert_file: /certs/fullchain.pem
livekit_server_config_turn_key_file: /certs/privkey.pem

# Монтирование сертов в контейнер
livekit_server_container_additional_volumes_custom:
  - src: /var/matrix/livekit-server/certs
    dst: /certs
    options: ro

# Порты TURN в LiveKit (рандомизация)
livekit_server_config_turn_tls_port: 15990     # TURN/TLS
livekit_server_config_turn_udp_port: 13478     # TURN/UDP
```

### LiveKit тюнинг

```yaml
livekit_server_configuration_extension_yaml: |
  room:
    empty_timeout: 30
    departure_timeout: 30
    enabled_codecs:
      - mime: audio/opus
      - mime: video/vp8
```

> **ВАЖНО**: После рандомизации TURN-портов нужно запустить `setup-traefik` тег,
> чтобы убрать порт из Traefik entrypoints (конфликт портов).

---

## 10. Ketesa

Веб-панель для управления сервером: пользователи, комнаты, медиа, статистика.

```yaml
# Включить Ketesa
matrix_ketesa_enabled: true

# По умолчанию доступен по: matrix.example.com/ketesa
# Можно изменить путь:
matrix_ketesa_path: /my-secret-admin

# В nginx-режиме: вынести на отдельный порт
# (настраивается через prepare_server.sh --ketesa-port PORT)
```

#### Доступ по внутреннему имени (nginx → Traefik)

При использовании nginx с отдельным портом, nginx подменяет Host:

```yaml
# Внутренний роутинг через Traefik labels
matrix_ketesa_container_labels_traefik_hostname: ketesa.internal
```

---

## 11. Element Admin

Современная панель управления через MAS Admin API.

```yaml
# Требует MAS!
matrix_authentication_service_config_admin_api_enabled: true

# Включить Element Admin
matrix_client_element_admin_enabled: true

# В nginx-режиме: nginx → Traefik с подменой Host
matrix_client_element_admin_container_labels_traefik_hostname: element-admin.internal
```

---

## 12. Coturn (TURN/STUN)

Помогает установить звонки через NAT и файрвол. **Без него звонки могут не работать**.
Coturn — общий TURN для legacy VoIP, LiveKit TURN — для SFU-connectivity (разные сервисы).

```yaml
# Включить Coturn
coturn_enabled: true

# ОБЯЗАТЕЛЬНО: публичный IP твоего сервера
coturn_turn_external_ip_address: '1.2.3.4'

# Порты STUN/TURN (стандартные)
coturn_container_stun_plain_host_bind_port_tcp: 3478
coturn_container_stun_plain_host_bind_port_udp: 3478
coturn_container_stun_tls_host_bind_port_tcp: 5349
coturn_container_stun_tls_host_bind_port_udp: 5349

# Рандомизация портов (защита от сканирования)
coturn_container_stun_plain_host_bind_port_tcp: 19563
coturn_container_stun_plain_host_bind_port_udp: 19563
coturn_container_stun_tls_host_bind_port_tcp: 37782
coturn_container_stun_tls_host_bind_port_udp: 37782

# Relay диапазон UDP
coturn_container_stun_relay_min_port: 49152
coturn_container_stun_relay_max_port: 49172
```

### Coturn TLS (nginx+Traefik режим)

В nginx+Traefik режиме Traefik не даёт серты через ACME. `prepare_server.sh`
автоматически копирует certbot-серты и создаёт renewal-хук.

```yaml
# Пути к сертам ВНУТРИ контейнера
coturn_tls_cert_path: /certs/fullchain.pem
coturn_tls_key_path: /certs/privkey.pem

# Монтирование сертов (ВАЖНО: использовать coturn_container_additional_volumes,
# НЕ _custom — group_vars перезаписывает combined переменную напрямую!)
coturn_container_additional_volumes:
  - src: /var/matrix/coturn/certs
    dst: /certs
    options: ro
```

### TURN URIs с кастомными портами

Плейбук **не добавляет** номера портов в TURN URIs автоматически. При использовании
нестандартных портов нужно явно переопределить `matrix_synapse_turn_uris`:

```yaml
# Пример: STUN на 19563, TURNS на 37782
matrix_synapse_turn_uris:
  - 'turns:matrix.example.com:37782?transport=udp'
  - 'turns:matrix.example.com:37782?transport=tcp'
  - 'turn:matrix.example.com:19563?transport=udp'
  - 'turn:matrix.example.com:19563?transport=tcp'
```

> **Стандартные порты** (3478/5349) не требуют переопределения URI — клиенты
> используют их по умолчанию.

---

## 13. ntfy (push-уведомления)

Приватные push-уведомления для Android через UnifiedPush (замена Google FCM).

```yaml
# Включить ntfy на ntfy.example.com
ntfy_enabled: true

# Требует A-запись: ntfy.example.com → IP
```

---

## 14. Synapse Auto-Compressor

Сжимает историю состояний комнат в БД. Ускоряет сервер, уменьшает объём базы.

```yaml
matrix_synapse_auto_compressor_enabled: true
```

---

## 15. Retention (автоудаление сообщений)

```yaml
# Включить автоудаление старых сообщений
matrix_synapse_retention_enabled: true

# Хранить сообщения от 1 дня до 90 дней
matrix_synapse_retention_default_policy_min_lifetime: 1d
matrix_synapse_retention_default_policy_max_lifetime: 90d

# Допустимый диапазон для настройки комнат
matrix_synapse_retention_allowed_lifetime_min: 1d
matrix_synapse_retention_allowed_lifetime_max: 365d

# Расписание очистки
matrix_synapse_retention_purge_jobs:
  - longest_max_lifetime: 90d
    interval: 3h
```

---

## 16. Media Repo (внешнее хранилище медиа)

Отдельный медиа-сервис с S3-хранилищем, дедупликацией, thumbnails.

```yaml
# Включить внешний media-repo
matrix_synapse_ext_media_repo_enabled: true
```

---

## 17. Email (SMTP)

Нужен для: уведомлений, сброса пароля, подтверждения email.

```yaml
# Включить отправку email
exim_relay_relay_use: true

# SMTP-сервер
exim_relay_relay_host_name: 'smtp.gmail.com'
exim_relay_relay_host_port: 587

# Авторизация
exim_relay_relay_auth: true
exim_relay_relay_auth_username: 'user@gmail.com'
exim_relay_relay_auth_password: 'app-password'

# Адрес отправителя
exim_relay_sender_address: 'matrix@example.com'

# Имя отправителя
matrix_synapse_email_notif_from: 'Matrix Server <matrix@example.com>'
```

---

## 18. Workers (масштабирование)

Распределяет нагрузку Synapse на несколько процессов (контейнеров).

```yaml
# Включить workers
matrix_synapse_workers_enabled: true

# Пресет:
#   little-federation-helper — 1 воркер (для слабых VPS, <50 юзеров)
#   one-of-each             — 12 воркеров (50-200 юзеров, 4+ GB RAM)
#   specialized-workers     — 14 воркеров (200+ юзеров, 8+ GB RAM)
matrix_synapse_workers_preset: little-federation-helper
```

### Сколько контейнеров создаёт каждый пресет

| Пресет | Контейнеров | RAM | Для кого |
|--------|-------------|-----|----------|
| little-federation-helper | +1 | 2 GB | Маленький сервер |
| one-of-each | +12 | 4+ GB | Средний сервер |
| specialized-workers | +14 | 8+ GB | Нагруженный сервер |

> **Совет**: Если сервер тормозит при деплое — уменьши пресет или отключи workers.

---

## 19. Мосты (Bridges)

Мосты позволяют писать из Matrix в другие мессенджеры и наоборот.

### Telegram

```yaml
matrix_mautrix_telegram_enabled: true

# API credentials (получить на https://my.telegram.org/apps):
matrix_mautrix_telegram_api_id: '12345678'
matrix_mautrix_telegram_api_hash: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
```

После деплоя: написать `@telegrambot:example.com`, команда `login`.

### WhatsApp

```yaml
matrix_mautrix_whatsapp_enabled: true
```

После деплоя: написать `@whatsappbot:example.com`, команда `login` (QR-код).

### Signal

```yaml
matrix_mautrix_signal_enabled: true
```

После деплоя: написать `@signalbot:example.com`, команда `link`.

### Discord

```yaml
matrix_mautrix_discord_enabled: true
```

После деплоя: написать `@discordbot:example.com`, команда `login`.

### Slack

```yaml
matrix_mautrix_slack_enabled: true
```

### Instagram

```yaml
matrix_mautrix_meta_instagram_enabled: true
```

### Facebook Messenger

```yaml
matrix_mautrix_meta_messenger_enabled: true
```

### Google Chat

```yaml
matrix_mautrix_googlechat_enabled: true
```

### LinkedIn

```yaml
matrix_beeper_linkedin_enabled: true
```

### Bluesky

```yaml
matrix_mautrix_bluesky_enabled: true
```

### IRC

```yaml
matrix_appservice_irc_enabled: true
```

### Email (Email ↔ Matrix)

```yaml
matrix_email2matrix_enabled: true
```

### Webhooks (входящие)

```yaml
matrix_appservice_webhooks_enabled: true
```

---

### Общие команды мостов

После деплоя моста, напиши в Element личное сообщение боту:

| Мост | Бот | Первая команда |
|------|-----|---------------|
| Telegram | `@telegrambot:domain` | `login` |
| WhatsApp | `@whatsappbot:domain` | `login` (QR) |
| Signal | `@signalbot:domain` | `link` |
| Discord | `@discordbot:domain` | `login` |
| Slack | `@slackbot:domain` | `login` |
| Instagram | `@instagrambot:domain` | `login` |
| Messenger | `@messengerbot:domain` | `login` |

> **Как это работает**: Мост создаёт "портал" — комнату в Matrix,
> которая отзеркаливает чат из другого мессенджера. Сообщения идут в обе стороны.

---

## 20. Боты

### Mjolnir (модерация)

Защита от спама, бана пользователей, автомодерация комнат.

```yaml
matrix_bot_mjolnir_enabled: true

# ID комнаты управления (создай пустую комнату, скопируй ID)
matrix_bot_mjolnir_management_room: '!xxxxx:example.com'
```

### Maubot (платформа для ботов)

Фреймворк для создания и запуска ботов. Веб-панель для управления.

```yaml
matrix_bot_maubot_enabled: true

# Админ-доступ к веб-панели maubot
matrix_bot_maubot_initial_password: 'secret-password'

# Доступ: matrix.example.com/_matrix/maubot/
```

### Reminder Bot (напоминания)

```yaml
matrix_bot_matrix_reminder_bot_enabled: true
```

### Honoroit (поддержка)

Бот для тикетов и поддержки пользователей.

```yaml
matrix_bot_honoroit_enabled: true
matrix_bot_honoroit_roomid: '!support:example.com'
```

### Buscarron (формы)

Принимает данные из HTML-форм и отправляет в Matrix-комнату.

```yaml
matrix_bot_buscarron_enabled: true
```

### Go-NEB (вебхуки)

Универсальный бот для интеграций: GitHub, Jira, RSS, вебхуки.

```yaml
matrix_bot_go_neb_enabled: true
```

---

## 21. Welcome Room (приветственная комната)

Автоматически приглашает новых пользователей в комнату.

```yaml
# Создай комнату в Element, скопируй alias
matrix_synapse_auto_join_rooms:
  - '#welcome:example.com'

# Автоматически принять приглашение
matrix_synapse_auto_join_mxid_localpart: bot.welcome
```

---

## 22. Безопасность

### Скрытие от сканирования

```yaml
# Federation на 443 (вместо 8448)
matrix_synapse_http_listener_resource_names: ["client","federation"]
matrix_federation_public_port: 443
matrix_synapse_federation_port_enabled: false
matrix_federation_traefik_entrypoint_name: web  # nginx / web-secure для Traefik-only

# Рандомизация портов LiveKit и Coturn
livekit_server_container_rtc_tcp_bind_port: 27483
coturn_turn_udp_port: 39521
```

### Регистрация по токенам

```yaml
# MAS:
matrix_authentication_service_config_account_registration_token_required: true

# Synapse (без MAS):
matrix_synapse_registration_requires_token: true
matrix_registration_admin_secret: 'xxxxxxxxxxxxxxxxxxx'
```

---

## 23. Ускорение Ansible

В файле `ansible.cfg`:

```ini
# Mitogen — ускоряет в 3-5 раз
# pip3 install mitogen
strategy_plugins = /path/to/ansible_mitogen/plugins/strategy
strategy = mitogen_linear

# Кэш фактов (экономит 10-30 сек)
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/.ansible_fact_cache
fact_caching_timeout = 3600

# Параллелизм
forks = 10

# Pipelining
[connection]
pipelining = True
```

---

## 24. Быстрые теги (вместо full install-all)

```bash
# Только Synapse
just run-tags setup-synapse,start

# Только Element Web
just run-tags setup-client-element,start

# Только мосты
just run-tags setup-mautrix-telegram,start
just run-tags setup-mautrix-whatsapp,start

# Только Traefik
just run-tags setup-traefik,start

# Только базу
just run-tags setup-postgres,start

# Создать пользователя
just run-tags register-user --extra-vars='username=USER password=PASS admin=yes'
```

---

## 25. Структура vars.yml (порядок секций)

Генератор создаёт vars.yml в таком порядке:

```
1.  Базовые параметры (домен, секрет, пароль БД)
2.  Reverse proxy (nginx/Traefik настройки)
3.  Сеть и доступ (федерация, регистрация, гости)
4.  MAS (аутентификация, ToS)
5.  Element Web (клиент)
6.  Ketesa
7.  Element Admin
8.  Звонки (LiveKit, порты)
9.  Coturn (TURN/STUN)
10. ntfy (push-уведомления)
11. Auto-Compressor
12. Media Repo
13. Мосты (Telegram, WhatsApp, Signal...)
14. Боты (Mjolnir, Maubot...)
15. Хранение (retention)
16. Email (SMTP)
17. Производительность (workers, presence, логи)
18. Welcome Room
19. Безопасность (federation на 443)
20. Бэкапы
```

---

## Полезные ссылки

- [Официальная документация плейбука](https://github.com/spantaleev/matrix-docker-ansible-deploy/blob/master/docs/README.md)
- [Список всех переменных](https://github.com/spantaleev/matrix-docker-ansible-deploy/blob/master/docs/configuring-playbook.md)
- [Matrix Spec](https://spec.matrix.org/)
- [Element Web](https://element.io/)
- [Проверка федерации](https://federationtester.matrix.org/)
