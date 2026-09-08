# Troubleshooting

Известные грабли по работе с Matrix homeserver + Element X/Web + LiveKit + MAS.
Расписаны в порядке "как часто встретится".

---

## 1. SPA "404 / не работает" после server changes → **Service Worker cache**

**Симптом:** ты обновляешь nginx config, рестартишь synapse / mas / element-web. Через минуту пользователи жалуются что Element Web показывает белый экран / "Connection lost" / 404 на `config.json` или `oauth2/keys.json`. `curl` с сервера показывает 200 OK на эти URL - но в браузере 404.

**Причина:** Element Web (как и MAS UI, и большинство современных Matrix клиентов) - это PWA с Service Worker'ом. SW работает как локальный прокси между браузером и сервером. Когда во время твоего рестарта SW запросил какой-то ресурс и получил 404 - он **закэшировал 404 как валидный ответ**. Ctrl+Shift+R (hard refresh) **обходит обычный HTTP-кэш, но НЕ Service Worker cache**.

**Диагностика - 30 секунд:**
1. Попроси пользователя открыть проблемный URL в **режиме инкогнито**.
2. Если в инкогнито работает - на 99% это SW cache.
3. Если в инкогнито тоже 404 - копать server.

**Решение пользователю:**
- F12 → Application → Storage → Clear site data → Reload
- Или открыть в инкогнито постоянно (для технически продвинутых)

**Защита server-side** - добавь `Cache-Control: no-store` на критические endpoints (вшито в наш `templates/matrix.conf.j2`):
- `/config.json` (Element Web)
- `/` (index.html)
- `/login`, `/oauth2/*` (MAS)
- `/.well-known/matrix/{server,client}`

С таким Cache-Control SW не сможет закэшировать ни 200, ни 404 - следующий downtime не отравит клиентов.

---

## 2. Element Web показывает "Ошибка при скачивании изображения"

**Симптом:** в Element Web картинки и аватары не грузятся. DevTools Network показывает `404 {"errcode":"M_NOT_FOUND"}` на `/_matrix/media/v3/thumbnail/...` или `/_matrix/media/v3/download/...`.

**Причина:** в synapse 1.120+ legacy endpoints `/_matrix/media/v3/...` требуют `Authorization: Bearer` header. Element Web рендерит media через HTML `<img src="...">`, а браузеры не передают auth headers в `<img>` (HTML ограничение). Современный клиент должен делать `fetch()` с auth → blob → `URL.createObjectURL()` для `<img src="blob:...">`. Element Web 1.11.85+ должен это делать.

**Правильное решение** (по приоритету):

1. **Обнови Element Web до latest** - `docker pull vectorim/element-web:latest && docker compose up -d element-web`. В свежих сборках authenticated media через blob работает корректно.

2. **Проверь что synapse advertise authenticated media**:
   ```bash
   curl https://matrix.example.com/_matrix/client/versions | jq '.unstable_features'
   ```
   Должно быть `"org.matrix.msc3916.stable": true` или `"org.matrix.msc4051": true`. Если нет - обнови synapse (1.120+ должен advertise по умолчанию).

3. **Очистка Service Worker cache в браузере** - после server update SW может держать кэш старого behavior. См. пункт 1 этого документа.

### Escape hatch: `enable_authenticated_media: false`

Если клиенты/боты/бриджи на твоём setup всё ещё не поддерживают authenticated media properly (Element Web 1.12.18 у некоторых до сих пор имеет issues с blob+createObjectURL flow, mx-puppet bridges не догнали, и т.п.), Spantaleev в official CHANGELOG прямо рекомендует workaround:

```yaml
matrix_synapse_configuration_extension_yaml: |
  enable_authenticated_media: false
```

> "You can disable authenticated media at any time by setting `matrix_synapse_enable_authenticated_media: false` in your vars.yml configuration file and re-running the playbook." - Spantaleev CHANGELOG (2024-11-26)

**Что это меняет:**
- Legacy `/_matrix/media/v3/*` endpoints перестают требовать `Authorization` header → `<img src="mxc://...">` грузятся через нормальный HTTP
- Synapse продолжает поддерживать **новый** `/_matrix/client/v1/media/*` (authenticated path) для клиентов которые его умеют
- **Tradeoff:** любой кто узнает mxc:// URI (через скриншоты, share, копирование) сможет скачать media без аутентификации

**Когда оправдано:**
- Часть клиентов / ботов / бриджей не догнала authenticated media
- Приватность media не критична (нет sensitive вложений)
- Готов принять security tradeoff пока ecosystem не догонит

**Когда НЕ оправдано:**
- На сервере есть приватные комнаты с sensitive content (медицинские, финансовые, корп. секреты)
- Все клиенты на современных версиях - лучше fixнуть real cause (обновить bridge/client)

Долгосрочное решение - дождаться пока **все** твои клиенты и интеграции догонят authenticated media support, потом вернуть `enable_authenticated_media: true`.

---

## 3. docker-compose v1 падает с `KeyError: 'ContainerConfig'`

**Симптом:** `docker-compose up -d` падает с Python traceback при попытке пересоздать контейнер на новом Docker Engine (25+).

**Причина:** старый docker-compose v1 (Python) использует deprecated API. Новые Docker Engine версии возвращают другую структуру `Image.Config`, и Python parser крашится.

**Решение:** установи v2 plugin: `bash tools/migrate-to-compose-v2.sh`

После - использовать `docker compose` (с пробелом) вместо `docker-compose` (с дефисом).

---

## 4. Element X "не долетают сообщения" (push приходит, sync не показывает)

**Симптом:** push notification приходит, открываешь Element X - нет нового сообщения. Перезапускаешь клиент - всё равно не видит. На SchildiChat Next (использует traditional /sync) того же сообщения видно сразу.

**Причина (типичная):** sliding sync long-poll connection между Element X и synapse рвётся. Push приходит отдельным каналом, но `/sync` event'a не привозит. Это **транспортная** проблема, не client-side.

**Чек-лист:**

1. **nginx `keepalive_timeout` < `proxy_read_timeout`** - рвёт upstream раньше чем synapse держит long-poll → 502. Проверь:
   ```
   nginx http{}:  keepalive_timeout 300s   (должно быть ≥ proxy_read_timeout)
   ```

2. **`proxy_read_timeout 60s` для sync endpoint** - слишком короткий. sliding sync ждёт до 5 минут:
   ```nginx
   location ^~ /_matrix/client/unstable/org.matrix.simplified_msc3575/sync {
       proxy_read_timeout 360s;
       proxy_ignore_client_abort on;
       proxy_socket_keepalive on;
   }
   ```

3. **`tcp_keepalive_time = 7200` (default)** - NAT/proxy между клиентом и сервером закрывает idle соединение через ~5 минут, синапс не знает. Снизь:
   ```
   sysctl net.ipv4.tcp_keepalive_time=60
   ```

4. **`presence: enabled: true`** (default) - раздувает sync payload в 2-3 раза, повышает шанс таймаута. Для setup'ов с фокусом на Element X:
   ```yaml
   matrix_synapse_configuration_extension_yaml: |
     presence:
       enabled: false
   ```

5. **`use_authenticated_media`** + sliding sync - может ломать media в синхроне. См. п.2.

6. **HTTP/2 HoL blocking на lossy mobile** - если все вышеприведённое не помогло, и пользователь только мобильный с дрожащим связи - это HTTP/2 head-of-line blocking. HTTP/3 (QUIC) решает, но требует чтобы hosting **не блокировал UDP/443**. Многие small VPS hosters (vdsina и аналоги) drop UDP packets random → HTTP/3 нестабильный → лучше не включать.

См. `tools/tune-system.sh` - применяет пункты 1, 3 автоматически.

---

## 5. Звонок 10-20 секунд "гудков" до того как у callee зазвонит

**Симптом:** caller инициирует Element Call, callee получает push с большой задержкой. Иногда вообще не получает (FCM dropped).

**Причина:** Push delivery path к **Android phone в Doze mode**. Без Firebase Cloud Messaging (FCM) push гейтвей не может wake phone из глубокого сна.

- **С FCM (через Sygnal или ntfy с firebase-key-file):** Android поднимается за 1-3 сек, total delay 2-5 сек.
- **Без FCM (default ntfy на UnifiedPush / WebSocket):** phone должен сам проснуться (random check, user interaction, etc) → 10-30 сек delay.

**Решение для production:**
1. Зарегистрируй Firebase project (бесплатный, без Google Cloud billing).
2. Скачай service account JSON.
3. Прокинь в push gateway:
   - **Sygnal:** настрой через `pushers:` в config.
   - **ntfy:** `firebase-key-file: /etc/ntfy/firebase.json` в server.yml.

Element X на Android при регистрации pusher автоматически использует FCM topic.

**Если Firebase не вариант (privacy / RKN):**
- **UnifiedPush distributor** - пользователи устанавливают `ntfy app` или `NextPush` на phone. Этот app держит WebSocket к твоему ntfy серверу (потребление батареи выше), но push доставляется быстро. Element X поддерживает UnifiedPush из коробки.

Element Web push в браузере - через WebPush API (VAPID keys). Это работает по умолчанию, если `web-push-public-key` / `web-push-private-key` сгенерены и прописаны в ntfy server.yml.

---

## 6. LiveKit звонок "не подключается" / drops после 10 секунд

**Симптом:** Element Call показывает "Connecting..." → "Failed". Логи livekit показывают ICE failure.

**Диагностика:**
```bash
docker logs livekit | grep -iE "ICE|failed|disconnected"
```

**Чек-лист:**

1. **UDP RTC порт заблокирован у hoster** - открой в их firewall panel или через тикет. Проверь `ss -ulnp` на сервере что livekit слушает.

2. **`use_external_ip: false`** - livekit не знает свой публичный IP, отдаёт клиентам internal docker IPs (172.x.x.x), клиенты не достигают. Включи:
   ```yaml
   rtc:
     use_external_ip: true
   ```

3. **`use_ice_lite: false`** на public-IP setup - ICE Lite ускоряет connect 30-50% когда server имеет публичный IP без NAT. Включи:
   ```yaml
   rtc:
     use_ice_lite: true
   ```

4. **Только UDP port range без mux** - на small VPS лучше один порт через `udp_port:` вместо `port_range_start/end` (default 50000-60000):
   ```yaml
   rtc:
     udp_port: 7882   # single port multiplexed
   ```

5. **Нет TCP fallback** - корпоративные NAT блокируют UDP. Должно быть:
   ```yaml
   rtc:
     tcp_port: 8443
     allow_tcp_fallback: true
   ```

6. **Embedded TURN не настроен** - нужен для жёстких firewall (только TCP/443-like outgoing). Включи:
   ```yaml
   turn:
     enabled: true
     udp_port: 3478
     tls_port: 5349
     domain: livekit.example.com
     cert_file: /etc/letsencrypt/live/livekit.example.com/fullchain.pem
     key_file: /etc/letsencrypt/live/livekit.example.com/privkey.pem
   ```
   И mount `/etc/letsencrypt` в livekit container readonly.

---

## 7. Synapse "FederationDeniedError 403" в логах

**Симптом:** WARNING/ERROR при старте synapse: `FederationDeniedError 403: Federation denied with matrix.org`.

**Причина:** у тебя в config есть `federation_domain_whitelist`, и matrix.org в него **не входит**. Synapse при старте пытается дернуть ключи с matrix.org (default trusted key server) - получает 403 от своей же конфигурации.

**Это не баг и не error для работы** - synapse продолжит работу. Просто пытается раз и потом помнит что нельзя.

**Если хочешь убрать warning:**
```yaml
matrix_synapse_configuration_extension_yaml: |
  trusted_key_servers:
    - server_name: "your-domain.tld"  # только себя
  suppress_key_server_warning: true
```
Tradeoff: server-to-server federation сигнатур станет проверять только локально. Для closed homeserver - OK.

---

## 8. Element Admin показывает "Failed to load" для Synapse version / Rooms

**Симптом:** Element Admin dashboard загружается, видит users (через MAS API), но **Synapse version** и **Rooms total** показывают "Failed to load".

**Причина:** ты закрыл `/_synapse/admin/*` через nginx ACL (`allow 127.0.0.1; deny all`) для security. Element Admin - это SPA в браузере пользователя, делает запросы к synapse admin API **с IP пользователя**, не с loopback → попадает в `deny all`.

**Решение:** убрать ACL. Synapse сам авторизует admin endpoints через access_token с флагом `admin: true`. nginx-level ACL поверх - избыточно и вредно. Если хочешь дополнительный gate - поставь HTTP basic auth, но не `allow/deny` по IP.

---

## 9. nginx warn `"ssl_stapling" ignored, no OCSP responder URL`

**Симптом:** при `nginx -s reload` или старте - много warnings про ssl_stapling.

**Причина:** Let's Encrypt с 2024 года **больше не публикует OCSP responder URL** в сертификатах (transition to CT/staple-less). Директива `ssl_stapling on` становится бесполезной и просто шумит.

**Решение:** убрать `ssl_stapling` и `ssl_stapling_verify` из nginx config полностью.

---

## 10. ntfy: Element Android/iOS не получает push-уведомления

**Симптом:** в Element Android `Settings → Troubleshoot → Troubleshoot notifications` показывает
"distributor: FCM" (а не ntfy), либо "no distributors available", либо уведомления не приходят
вовсе.

**Диагностика (от простого к сложному):**

1. **ntfy-сервер жив и доступен снаружи:**
   ```bash
   curl -fsS https://ntfy.example.com/v1/health
   # → {"healthy":true}
   ```

2. **Kit-помощник для проверки:**
   ```bash
   bash tools/test-ntfy.sh --domain example.com
   # Проверит health, отправит тестовое сообщение и проверит /v1/topics
   ```

3. **Element Android должен видеть ntfy через well-known:**
   ```bash
   curl -fsS https://example.com/.well-known/matrix/client | jq
   # Должно содержать "m.push": { "kind": "up", "url": "https://ntfy.example.com" }
   ```
   Если этого нет - MADA не подключил ntfy к Synapse. Проверь, что `ntfy_enabled: true`
   в `vars.yml` и перезапусти `ansible-playbook setup.yml --tags=setup-all,start`.

4. **Element Android → настройка вручную:**
   `Settings → Notifications → UnifiedPush: Force custom push gateway`
   → вводишь `https://ntfy.example.com`
   → `Settings → Troubleshoot → Re-register push distributor`
   → `Settings → Troubleshoot → Troubleshoot notifications` (должен показать ntfy)

5. **Проверить топик через браузер:** открой `https://ntfy.example.com/app`, подпишись на
   топик `element-*` (или конкретный, который видишь в логах ntfy:
   `docker logs matrix-ntfy 2>&1 | grep -i publish`) и пошли тестовое сообщение.

**Типичные причины:**

| Симптом | Причина | Решение |
|---------|---------|---------|
| `auth-default-access` в логах ntfy "topic forbidden" | kit ставит `deny-all` (старая версия) | обнови kit, пересобери vars.yml с `auth-default-access: read-write` |
| "no upstream" в логах homeserver | MADA не знает про ntfy | проверь `ntfy_enabled: true` и `matrix_server_fqn_ntfy: "ntfy.X"` |
| Android не находит дистрибьютора | старая версия Element | обнови Element Android до 1.4.26+ (1.5.x рекомендуется) |
| Push приходят с задержкой 5+ минут | `manager-interval` слишком большой | понизь в vars.yml: `manager-interval: "2s"` и перезапусти ntfy |
| Уведомления не доходят до оффлайн-клиентов | `cache-duration` мал | увеличь: `cache-duration: "24h"` (по дефолту 12h) |

**Если ничего не помогло:**
```bash
# Проверить, что ntfy вообще стартовал
docker ps | grep matrix-ntfy
docker logs --tail 100 matrix-ntfy 2>&1 | tail -30

# Проверить, что homeserver использует ntfy
docker exec matrix-synapse cat /data/homeserver.yaml | grep -A 5 pushers
# Должен быть блок pusher/email_pusher указывающий на ntfy

# Проверить в БД homeserver, что pushers настроены
docker exec matrix-postgres psql -U matrix -d synapse \
  -c "SELECT app_id, kind, app_display_name, url FROM pushers LIMIT 5;"
```

---

## 11. Хочу поднять ntfy на своём домене (например `push.example.com`)

**Симптом:** по дефолту ntfy живёт на `ntfy.example.com`, но ты хочешь другое имя.

**Решение:** в wizard'е (секция 1/12) ответь "Да" на "Переопределить какие-то поддомены" и
укажи нужное имя. Kit пропишет `matrix_server_fqn_ntfy: "push.example.com"` в `vars.yml`.
**Не забудь добавить DNS A/CNAME** запись для нового имени до запуска деплоя, иначе
certbot не получит сертификат.

