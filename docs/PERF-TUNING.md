# Performance Tuning — рекомендации

Дополнительные настройки для оптимизации Matrix homeserver под современные клиенты (Element X с sliding sync, Element Call с LiveKit). Применяй после базового deploy.

## Quick apply

```bash
# 1) System-level tuning (sysctl + nginx + systemd)
bash tools/tune-system.sh

# 2) Synapse + LiveKit vars — добавь в vars.yml перед перезапуском плейбука
```

---

## Synapse — добавь в `matrix_synapse_configuration_extension_yaml`

```yaml
matrix_synapse_configuration_extension_yaml: |
  # Главный кит для Element X — снижает sync payload x2-3
  # У пользователей пропадут "online/offline" status, но typing notifications
  # продолжат работать (это другая фича).
  presence:
    enabled: false

  # Увеличенные кэши — меньше hits в Postgres
  caches:
    global_factor: 1.5
    sync_response_cache_duration: 2m

  # Optionally: отключение требования auth на legacy media endpoints.
  # Используй ТОЛЬКО если клиенты/бриджи/боты не догнали authenticated media.
  # Spantaleev в CHANGELOG (2024-11-26) явно описал как escape hatch для совместимости.
  # См. docs/TROUBLESHOOTING.md секцию 2 для tradeoff details.
  # enable_authenticated_media: false

  # Faster joins — default true с 1.107+, но прописываем явно
  experimental_features:
    faster_joins: true

  # Опционально: устранить FederationDeniedError noise при федерации только
  # с whitelist-доменами (раскомментируй если federation_domain_whitelist задан):
  # trusted_key_servers:
  #   - server_name: "matrix.example.com"
  # suppress_key_server_warning: true
```

## LiveKit — добавь в `livekit_server_configuration_extension_yaml`

```yaml
livekit_server_configuration_extension_yaml: |
  rtc:
    # UDP mux на один порт — проще для firewall, меньше state.
    # Закомментировать port_range_start/end если они в default vars.
    udp_port: 7882
    tcp_port: 7881            # TCP fallback для NAT-locked clients
    allow_tcp_fallback: true
    use_external_ip: true     # auto-discover публичный IP через STUN
    use_ice_lite: true        # faster ICE на public-IP host (без NAT)

    # CPU/RAM friendly tuning для small VPS (1-2 CPU, 2-4 GB RAM)
    batch_io:
      batch_size: 128
      max_flush_interval: 2ms
    packet_buffer_size_video: 300   # default 500
    packet_buffer_size_audio: 100   # default 200

    congestion_control:
      enabled: true
      allow_pause: true       # smart pause low-priority streams под нагрузкой

  audio:
    # Opus RED — redundancy encoding для lossy mobile. ~1.5× bandwidth, но
    # opus так мало жрёт (10-30 → 15-45 kbps) что незаметно. Звук не битый.
    active_red_encoding: true

  room:
    # Apple-устройства (iOS Safari, Mac Safari) предпочитают H.264 hw-accel.
    # Меньше нагрев телефона при звонках.
    enabled_codecs:
      - mime: audio/opus
      - mime: video/vp8
      - mime: video/h264

  # Safety limits — защита от accidental overload
  limit:
    num_tracks: 800                 # 1 CPU реалистично ~400, 800 запас
    bytes_per_sec: 50000000         # 50 MB/s — realistic VPS ceiling
    subscription_limit_video: 30    # один user ≤ 30 video подписок
    subscription_limit_audio: 50

  logging:
    level: info                     # с debug — жирно
```

## Embedded TURN в LiveKit (для жёстких corporate firewall)

Если ожидаются пользователи за corporate NAT (только TCP/443 outgoing):

```yaml
livekit_server_configuration_extension_yaml: |
  turn:
    enabled: true
    udp_port: 3478              # стандарт STUN/TURN
    tls_port: 5349              # стандарт TURN-TLS
    domain: livekit.example.com
    cert_file: /etc/letsencrypt/live/livekit.example.com/fullchain.pem
    key_file: /etc/letsencrypt/live/livekit.example.com/privkey.pem
    external_tls: false
```

Требует чтобы livekit container имел mount `/etc/letsencrypt:/etc/letsencrypt:ro`.

---

## Что НЕ рекомендуется (потратил время — не работало или маржинально)

### HTTP/3 / QUIC через nginx
На small VPS hosters (vdsina, kimsufi, contabo, и аналоги) UDP пакеты на :443 часто **random drops** — handshake success rate ~50%. Это **хуже стабильного HTTP/2**. Включать только если ты на enterprise hosting (Hetzner Cloud, OVH, AWS) и протестировал через http3check.net со 100% success.

### proxy_cache для /_matrix/media/
Звучит привлекательно (immutable URIs!), но:
1. **Authenticated media** ломает простой кэш по URI — нужен сложный key с user_id.
2. **streaming** для больших media с buffering on может задерживать первый byte.
3. Synapse сам кэширует media в `media_store` — двойной кэш = только trade-off без выигрыша.

### ssl_early_data on (0-RTT TLS 1.3)
Default off. Часто конфликтует с QUIC handshake. Включать только если протестировал — иначе reconnect'ы могут падать.

### Disable presence для всех setups
Если у тебя пользователи в основном на Element Web/desktop — presence (online/offline status) для них polezна. Отключать только если фокус на Element X (mobile, где presence не показывается видно user'у).

---

## Verification — после применения

```bash
# 1) sysctl
sysctl net.ipv4.tcp_congestion_control     # ожидаем: bbr
sysctl net.ipv4.tcp_keepalive_time         # ожидаем: 60

# 2) nginx
grep keepalive_timeout /etc/nginx/nginx.conf
# ожидаем: keepalive_timeout 300s

# 3) Synapse presence
docker exec matrix-synapse curl -s http://localhost:8008/_matrix/client/versions \
  | grep -o '"presence"' | head -1
# (presence не появится в unstable_features если отключен)

# 4) LiveKit
docker logs matrix-livekit-server 2>&1 | grep -iE "starting|ICE Lite|TURN"
# ожидаем: "Starting TURN server" + "rtc.portUDP: {Start: 7882}"

# 5) Real test — открой Element X на mobile через 4G/LTE
#    Sliding sync delay должен быть <3 сек, push notification <5 сек
#    (если Firebase настроен — <2 сек)
```
