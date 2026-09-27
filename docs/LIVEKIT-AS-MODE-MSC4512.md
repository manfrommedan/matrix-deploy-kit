# LiveKit JWT Service 0.7 + AS-режим (MSC4512) — инструкция

Референсы: Synapse v1.161.0, lk-jwt-service v0.7.0 (Rust, новая версия).

Подробности по исходникам:
- `docs/upgrade.md` (Synapse v1.161.0): "Deprecation of `matrix_rtc.livekit_service_url`"
- `synapse/config/experimental.py:317`: `msc4512_enabled` по умолчанию `false`
- `synapse/config/appservice.py`: читаются ТОЛЬКО namespace-ключи `io.element.msc4512.*` / `io.element.msc4502.scopes`
- README GitHub `element-hq/lk-jwt-service` (v0.7.0)

---

## 0. Диагноз типичной ошибки (форумный кейс)

Пользователь заменил в `matrix_rtc`:
```
livekit_service_url: https://servername/livekit/jwt
```
на:
```
url: wss://servername
```
— звонки отвалились.

**Четыре ошибки сразу (как проверено по исходникам):**

1. `url:` — это НЕ адрес jwt-сервиса, а **WebSocket-адрес самого LiveKit SFU** (`wss://…`). 
   Из docs Synapse (`config_documentation.md`): *"`url` (string): The WebSocket URL of the LiveKit SFU."*
   В итоге `wss://servername` вёл в nginx на корень домена, а не до LiveKit → нет рукопожатия → звонок не собирается.

2. `livekit_service_url` удалять **нельзя** — deprecated ≠ убрать.
   Из `docs/upgrade.md` v1.161: *"livekit_service_url is now deprecated **but should continue to be listed** to ensure backwards compatibility with older clients."*

3. Проксирование MSC4512 в Synapse v1.161 **по умолчанию выключено**: 
   ```python
   # synapse/config/experimental.py
   self.msc4512_enabled: bool = experimental.get("msc4512_enabled", False)
   ```
   Без `msc4512_enabled: true` роуты `/rtc/livekit/…` просто не регистрируются 
   (`synapse/rest/client/appservice_proxy.py:62: if not ... msc4512_enabled: return`).

4. AS-режим — это не только конфиг Synapse. Нужна вся связка:
   registration-файл (с правильными ключами) + `app_service_config_files` + 
   три env в самом сервисе (`LIVEKIT_AS_TOKEN`, `LIVEKIT_HS_TOKEN`, `LIVEKIT_HS_SERVER_NAME`).

---

## 1. Быстрый фикс — откат (как было)

Вернуть старую строку, убрать `url`.
Standalone-режим в 0.7 официально продолжает работать (README: 
*"still supports the deprecated standalone mode"*).

```yaml
# homeserver.yaml
matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "https://servername/livekit/jwt"
```

Никаких appservice при этом не требуется — звонки сразу назад работают.

---

## 2. Полный чек-лист AS-режима (MSC4512 + MSC4502)

Пример одного хоста: домен `matrix.example.com`, Synapse в `/etc/matrix-synapse`,
LiveKit на порт 7880 (127.0.0.1), lk-jwt-service на 127.0.0.1:8080, nginx рядом.

### 2.1. Токены приложения

```bash
AS_TOKEN=$(openssl rand -hex 32)
HS_TOKEN=$(openssl rand -hex 32)
echo "as_token: $AS_TOKEN"
echo "hs_token: $HS_TOKEN"
```

Эти же значения дальше идут и в registration-файл, и в env сервиса.

### 2.2. Registration-файл `/etc/matrix-synapse/lk-as.yaml`

⚠️ **Ключи — только namespace'ные!** В README сервиса пример пишет `proxy_prefix:`
и `proxy_url:` — Synapse v1.161 читает только `io.element.msc4512.proxy_*`.
Та же ловушка со scope: в README он написан под ключами `scopes:`/`io.element.msc4502.scope:`
(не читаются) и с URN **без** `io.element.msc4502:` внутри — а Synapse при разборе скоупов
сверяет их с enum (`appservice/__init__.py:71`) и с неизвестным **падает при старте**
(`Unknown application service scope(s)`). Правильно ровно так:

```yaml
id: "lk-jwt"
as_token: "AS_TOKEN_ИЗ_2.1"
hs_token: "HS_TOKEN_ИЗ_2.1"
sender_localpart: "_lk_jwt_service"
url: null                # event-traffic не нужен, но ключ обязателен
namespaces:
  users:
    - exclusive: false
      regex: ".*"        # покрыть всех локальных юзеров (нужен для is_joined)
io.element.msc4502.scopes:
  - "urn:matrix:client:io.element.msc4502:rooms:is_joined"   # URN с io.element.msc4502: внутри!
io.element.msc4512.proxy_prefix: "rtc/livekit"
io.element.msc4512.proxy_url: "http://127.0.0.1:8080"
```

Права:

```bash
sudo chown matrix-synapse /etc/matrix-synapse/lk-as.yaml
sudo chmod 640 /etc/matrix-synapse/lk-as.yaml
```

### 2.3. `homeserver.yaml` — три места

```yaml
experimental_features:
  msc4512_enabled: true            # проксирование C-S -> AS (default false даже в v1.161!)
  msc4143_enabled: true            # отдача /rtc/transports клиентам — без него url: вообще
                                   # не доходит (сервлет регистрируется только при флаге,
                                   # matrixrtc.py:51). В MDAD включается автоматически
                                   # при ненулевых transports, в ручной сборке — только так.

app_service_config_files:
  - /etc/matrix-synapse/lk-as.yaml

matrix_rtc:
  transports:
    - type: livekit
      url: "wss://matrix.example.com/livekit-sfu"            # WebSocket LiveKit SFU (см. nginx)
      livekit_service_url: "https://matrix.example.com/livekit/jwt"   # старую строку оставляем
```

### 2.4. env lk-jwt-service (systemd-юнит `/etc/systemd/system/lk-jwt-service.service`)

```ini
[Unit]
Description=lk-jwt-service
After=network.target

[Service]
Environment=LIVEKIT_URL=wss://matrix.example.com/livekit-sfu
Environment=LIVEKIT_KEY=devkey
Environment=LIVEKIT_SECRET=secret
Environment=LIVEKIT_JWT_BIND=127.0.0.1:8080
Environment=LIVEKIT_FULL_ACCESS_HOMESERVERS=matrix.example.com
Environment=LIVEKIT_HS_SERVER_NAME=matrix.example.com
Environment=LIVEKIT_AS_TOKEN=AS_TOKEN_ИЗ_2.1
Environment=LIVEKIT_HS_TOKEN=HS_TOKEN_ИЗ_2.1
ExecStart=/usr/local/bin/lk-jwt-service
Restart=always

[Install]
WantedBy=multi-user.target
```

⚠️ **`LIVEKIT_URL` обязан побуквенно совпадать с `url:` из п. 2.3** — в 0.7 AS-режиме клиентское
поле `url` сверяется с этой строкой как текст (`handler.rs:813`, `require_matching_lk_url`),
любое несовпадение → `400 M_INVALID_PARAM: The request url does not match this service's LiveKit URL`.
Никаких внутренних `ws://127.0.0.1:7880` рядом с публичным `wss://` — **один и тот же адрес**,
публичный, побуквенно. Путь в `url:` — это просто метка маршрута в nginx (п. 2.5), хоть `/livekit-sfu`,
хоть `/livekit/sfu`, хоть `/banana` — единственное правило: **одна строка в трёх местах**
(`url:` в homeserver.yaml, `LIVEKIT_URL` в env сервиса, location в nginx).
Room-creation сервером тоже идёт через этот же адрес (`create_livekit_room` строит клиента на
`livekit_auth.lk_url`, helper.rs:656) — nginx проксирует location-ом в 7880, отдельный локальный
ws туда не нужен.

### 2.5. nginx — два location

```nginx
# 1. legacy-путь jwt-сервиса — ОСТАВЛЯЕМ (старые клиенты + webhook)
location /livekit/jwt/ {
    proxy_pass http://127.0.0.1:8080/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# 2. WebSocket LiveKit SFU (то, что в `url:` из matrix_rtc) — добавляем
location /livekit-sfu/ {
    proxy_pass http://127.0.0.1:7880/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
```

C-S прокси через MSC4512 nginx трогать **не нужно**: 
`/_matrix/client/unstable/io.element.msc4195/rtc/livekit/*` проходит в Synapse вместе с
остальными `/_matrix/...` запросами, дальше Synapse сам пробрасывает в `proxy_url`.

### 2.6. Webhook в `config.yaml` LiveKit SFU

```yaml
webhook:
  api_key: devkey    # == LIVEKIT_KEY поля env-сервиса
  urls:
    - https://matrix.example.com/livekit/jwt/sfu_webhook
```

Для работы звонка в моменте НЕ обязательно; без этого не отрабатывается delegated delayed
leave (MSC4140) — клиент может «зависнуть» в комнате при обрыве. Для прода — желательно.

### 2.7. Рестарт

```bash
sudo systemctl daemon-reload --quiet
sudo systemctl enable --now lk-jwt-service
sudo systemctl restart matrix-synapse lk-jwt-service livekit-server nginx
```

---

## 3. Проверка за 2 минуты

Токен пользователя из Element Web: Settings → Help & About → Access Token.

```bash
AT="вставь токен сюда"

# 1) transports отдаются с обоими полями:
curl -s -H "Authorization: Bearer $AT" \
  https://matrix.example.com/_matrix/client/unstable/org.matrix.msc4143/rtc/transports \
  | python3 -m json.tool

# 2) прокси жив: на пустом body должен прийти JSON-ошибка ОТ СЕРВИСА
#    (400 / M_NOT_JSON / M_MISSING_PARAM), а не M_UNRECOGNIZED от Synapse:
curl -s -X POST -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -d '{}' \
  https://matrix.example.com/_matrix/client/unstable/io.element.msc4195/rtc/livekit/get_token \
  | python3 -m json.tool

# 3) логи (MDAD: у matrix-юнитов docker log-driver=none, `docker logs` сломан -
#    журнал идёт из `docker start --attach` прямо в journald)
journalctl -fu matrix-livekit-jwt-service
journalctl -u matrix-synapse 2>&1 | grep -iE "appservice|livekit" | tail
```

Если второй curl вернул `M_UNRECOGNIZED` (404) — проксирование не поднялось. 
Частые причины: забыт `msc4512_enabled: true`, не-namespace'ные ключи в registration, 
или synapse не подхватил `app_service_config_files` (в логе при запуске будет ошибка чтения файла).

---

## 4. Шпаргалка при работе через MDAD-плейбука (matrix-docker-ansible-deploy)

Если сервер развёрнут через MDAD (`setup-all`) — нужная версия уже в `matrix_synapse_version: v1.161.0`.
Но **сам плейбук AS-режима не настраивает** (ни одного `msc4512` в MDAD master на момент проверки).
Чистый способ добавить через `vars.yml`:

```yaml
# экспериментальные флаги (merge, чужие auto-флаги не трогаем)
matrix_synapse_experimental_features_custom:
  msc4512_enabled: true
  # msc4143_enabled НЕ нужен — MDAD включает его автоматически при ненулевых transports
  # (roles/custom/matrix-synapse/main.yml: msc4143 = transports | length > 0)

# AS-режим есть с 0.7. latest — образ сам обновляется (ghcr :latest; self-build
# на arm при latest чеканит main). Kit (wizard + livekit-as-setup.sh) ставит его сам.
matrix_livekit_jwt_service_version: latest

# transports: ПОЛНЫЙ override (не _custom!) - MDAD-default даёт запись с ТОЛЬКО
# livekit_service_url, добавив переход через custom получим ДВЕ livekit-записи.
# url: берём Jinja-ссылкой на переменную, из которой MDAD выставляет LIVEKIT_URL
# (group_vars:6694) - иначе при смене path-префикса они разъедутся (400 при get_token).
matrix_synapse_matrix_rtc_transports:
  - type: livekit
    url: "{{ livekit_server_websocket_public_url }}"
    livekit_service_url: "{{ matrix_livekit_jwt_service_public_url }}"

# registration-файл грузим с диска в контейнер синапсы (он уже там, /matrix/synapse/config/
# mdad молча монтирует в /data)
matrix_synapse_app_service_config_files:
  - "/data/lk-as.yaml"

# доп. env в контейнер jwt-service:
matrix_livekit_jwt_service_environment_variables_extension: |
  LIVEKIT_AS_TOKEN=...
  LIVEKIT_HS_TOKEN=...
  LIVEKIT_HS_SERVER_NAME=matrix.example.com
```

⚠️ Ручные правки `/matrix/synapse/config/homeserver.yaml` после run-плейбука **затираются** —
`homeserver.yaml.j2` регенерируется из шаблона, поэтому постоянные правки делаются через vars.

⚠️ **Окно crash-loop при ручной установке**: Synapse на старте делает `open()` на
каждый путь из `app_service_config_files` (`synapse/config/appservice.py:
load_appservices`) — файла нет = ошибка конфигурации = ретраи до бесконечности.
Поэтому `lk-as.yaml` надо положить в `${DATA_PATH}/synapse/config/` **до** первого
`just install-all`. Kit закрывает окно сам: `deploy.sh` pre-seed'ит файл до
install-all (шаг 6.A), `livekit-as-setup.sh` кладёт registration на шаге 4,
install-all — на шаге 6.

### 4.1. Три сценария kit'а

| Сценарий | Команда | Для кого |
|----------|---------|----------|
| С нуля через deploy | `bash deploy.sh --full --domain X`, в wizard ответить `y` на AS-режим | новый сервер целиком |
| Пост-deploy (vars уже есть, AS не включался) | `bash deploy.sh --full --skip-ansible ...` + добавить блоки в vars (см. выше) + `just install-all` + `bash tools/install-livekit-as.sh` | уже развёрнутый wizard'ом |
| Самодостаточный онбординг | `bash tools/livekit-as-setup.sh` (или `--dry-run` / `--uninstall`) | любой развёрнутый сервер, vars.yml не трогали руками |

`livekit-as-setup.sh` делает merge vars.yml через PyYAML (идемпотентно, чужие
значения не трогает), кладёт `lk-as.yaml` рядом с vars.yml (там хранятся токены)
и в synapse config-dir, гоняет `just roles && just install-all` и живые
smoke-проверки (federation/version, rtc/transports, MSC4512-прокси,
`LIVEKIT_AS_TOKEN/HS_TOKEN` в env контейнера через `docker inspect Config.Env`).
Если контейнер jwt-сервиса сидит на устаревшем env (`docker create` перечитывает
env-file только при пересоздании, а conditional restart мог пройти мимо),
скрипт рестартит сервис сам.

---

## 5. Откат

Через kit (любой сценарий):

```bash
bash tools/livekit-as-setup.sh --uninstall    # убирает блоки из vars.yml,
                                              # registration + переустанавливает
```

Вручную (MDAD-развёрнутый сервер):

```bash
# vars.yml: убрать строку в app_service_config_files, убрать "url" из transports,
# убрать LIVEKIT_AS_TOKEN/LIVEKIT_HS_TOKEN/LIVEKIT_HS_SERVER_NAME из env-расширения,
# убрать matrix_livekit_jwt_service_version: latest (возврат на mdad-default)
rm /matrix/synapse/config/lk-as.yaml   # ${DATA_PATH}/synapse/config/, НЕ /etc
just install-all                       # или systemctl restart matrix-synapse matrix-livekit-jwt-service
```

Звонки через `livekit_service_url` снова работают по-старому.
