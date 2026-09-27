# Changelog

## [Unreleased]

### Added

- **AS-режим lk-jwt-service (MSC4512/MSC4502) - звонки через `lk-as.yaml`**
  (ЭКСПЕРИМЕНТАЛЬНАЯ ФИЧА). Звонки проксируются Synapse'ом на jwt-сервис
  как Application Service вместо `livekit_service_url` (deprecated в
  Synapse 1.161). Три сценария:
  - С нуля: `deploy.sh --full` + `y` на вопрос wizard'а - deploy pre-seed'ит
    `lk-as.yaml` в synapse config-dir до install-all (Synapse `open()`'ит
    каждый путь из `app_service_config_files` при старте, файла нет =
    crash-loop) и гоняет `tools/install-livekit-as.sh` после.
  - Пост-deploy: `tools/install-livekit-as.sh` (кладёт registration, сверяет
    токены vars.yml с lk-as.yaml, рестартит сервисы, smoke).
  - Живой сервер: `tools/livekit-as-setup.sh` - сам добавляет блоки в
    vars.yml (PyYAML-merge, идемпотентно), генерит/сохраняет токены,
    применяет через install-all, smoke-проверки; `--uninstall` снимает.
  Требования: Synapse v1.161+, lk-jwt-service 0.7+ (kit пинит `latest`).
  Статус/ограничения/откат: `docs/LIVEKIT-AS-MODE-MSC4512.md` +
  `docs/KNOWN-LIMITATIONS.md` п.10.
- **`tools/tests/`** - собственный bash test-runner (`run-tests.sh`) без
  внешних зависимостей, совместимый с API bats-core (setup/teardown/test_*,
  assert/assert_eq/assert_fail/assert_contains/skip/pass). 20 unit-тестов
  на 2 файла: `test_lib.sh` (13 - хелперы `_lib.sh`: `gen_dynamic_port`,
  `yes_no`, `require_cmd`, `header_text`, `die`) и `test_preflight.sh`
  (7 - флаги/коды возврата). `--tap` режим для CI.
- **CI как gate, не advisory** - `shfmt -d` теперь fail-build, а не
  предупреждение. Все 16 скриптов отформатированы `shfmt -i 4 -ci`.
  Существующие файлы тоже - kit теперь enforce единый стиль.
- **`--env-file FILE` в `generate_vars.sh`** - non-interactive режим для
  CI/CD. Скип `gen_dynamic_port` + heredoc-генерация + все дефолты.
  Включается при `WIZARD_NONINTERACTIVE=1` в env, или флагом `--env-file`.
  Все wizard-переменные имеют sane defaults; в режиме non-interactive
  `set +u` временно на heredoc, чтобы не падать на не-заданных опциональных
  переменных. Выход: валидный YAML с 48 ключами (на тестовом env-file).
- **`deploy.sh --dry-run`** - безопасная проверка конфигурации без
  изменений: не требует root, эмулирует все шаги (clone плейбука,
  preflight, prepare, ansible) с префиксом `[DRY] would:`.
  Идеально для pre-prod валидации.
- **`die()` в `_lib.sh` теперь возвращает 1, а не вызывает `exit 1`** -
  позволяет тестам перехватить код возврата через `set +e`. В скриптах
  с `set -e` поведение идентично (скрипт выйдет с тем же кодом).

### Fixed

- **LiveKit TURN/TLS чинится при свежем деплое** - `prepare_server.sh` до
  `install-all` кладёт серты `root:root 640`, а Ansible владельца не правит:
  роль livekit-тлс работает в контейнере под uid пользователя matrix и
  `/certs` не читает → первый старт TURN/TLS падал. Теперь:
  - deploy.sh после `just install-all` поправляет владельца и рестартит
    `matrix-livekit-server` / `matrix-coturn`
  - `update.sh --sync-certs` правит владельца безусловно (раньше chown стоял
    только в ветке `diff -q` - на идентичных сертах никогда не выполнялся)
  - renewal-хук `restart-matrix-tls.sh` резолвит UID/GID matrix в момент
    прогона (раньше литералом ставился `0` = root)
- **Дефолты TURN-портов wizard'а 5349/3478 → 5350/3479** - старые
  пересекались с coturn (`3478/5349`). Новые - те же, что в group_vars MDAD.
- **TLS-блоки coturn/livekit только в nginx-режиме** - в traefik-only сертов
  на хосте нет (prepare их туда не кладёт), а MDAD-дефолты там рабочие
  (external_tls: true + certs-dumper). Раньше wizard писал явные пути к
  несуществующим сертам безусловно.
- **`ufw` теперь открывает LiveKit-порты при `--without-random-ports`** -
  раньше правила LiveKit добавлялись только при заполненных LK_* (т.е. только
  с рандомизацией), и стандартные порты 7881/7882/5350/3479 оставались закрыты
  при `--with-firewall` без рандома.
- **healthcheck: смоук TURN TLS** (`:5350` LiveKit и/или `:5349` coturn,
  в зависимости от того, какие сервисы установлены) - ловит self-signed
  серты на TURN-портах. Порты читаются из vars.yml, если playbook найден.
- **Коллизии рандома LiveKit ↔ coturn** - раньше генерация портов coturn
  (10000-59999) не знала о портах LiveKit (10000-49999), входящие в диапазон
  Coturn могли пересечься. Теперь coturn порты генерируются через
  `gen_dynamic_port` с исключением уже выбранных LiveKit/Coturn портов
  (включая relay-диапазон min..min+20).

- **TURN-over-TLS (TURNS) записывается в vars.yml**: wizard `generate_vars.sh`
  теперь генерирует TLS-блок coturn (`coturn_tls_enabled`, `coturn_realm`,
  явные `coturn_tls_cert_path`/`coturn_tls_key_path` + mount `/certs` в
  `coturn_container_additional_volumes`) и — при рандомизации портов —
  `matrix_synapse_turn_uris` с явными host-портами. Раньше MDAD-дефолт с
  выключенным `traefik_certs_dumper` производил пустые cert-пути, и
  Synapse рекламировал клиентам неработающие `turns:` URI. Сертификаты
  по-прежнему раскладывает `prepare_server.sh` (`${DATA_PATH}/coturn/certs`
  + renewal-хук). См. docs/VARS-REFERENCE.md §12.

### Changed

- **LiveKit убран из `matrix_server_fqn_*`** - раньше kit просил
  LiveKit-поддомен и выпускал на него отдельный SSL-сертификат. По факту
  LiveKit проксируется через `matrix.DOMAIN/livekit-jwt-service`
  (path-routing), отдельный subdomain не нужен. Удалены:
  - `matrix_server_fqn_livekit: livekit.${DOMAIN}` в vars.yml
  - Вопрос о `livekit.${DOMAIN}` в wizard'е custom subdomains
  - `livekit.${DOMAIN}` в списке subdomains для certbot/SSL
- **Element Web branding в wizard'е (секция 6/12)** - раньше секция была
  пустой, теперь: brand (умный дефолт из домена), тема (light/dark),
  регистрация, логотип, фон (с fallback на lake.jpg), country code
  (валидация ISO 3166-1), гостевой доступ, lab settings, bug-report URL,
  footer-ссылки (с дефолтом на /tos).
- **Тюнинг ntfy для доставки (секция 5/12):** `auth-default-access:
  read-write` (иначе UnifiedPush не работает), `cache-duration: 24h`
  (вместо upstream 12h), `manager-interval: 2s` (вместо 5s),
  `keepalive-interval: 20s`, лимиты посетителей, `upstream-base-url`
  опционально, `ntfy_web_root: app`. Шпаргалка по Element Android/iOS
  в конце секции.
- **Кастомные поддомены в wizard'е (секция 1/12)** - переопределение
  `matrix_server_fqn_matrix/element/ntfy` (без livekit). Например
  `chat.example.com` вместо `element.example.com`.
- **TROUBLESHOOTING.md: раздел 10 (ntfy push)** + раздел 11 (кастомные
  домены) + `tools/test-ntfy.sh` - диагностика push-доставки.
- **Логирование Synapse: дефолт WARNING** + `tools/logrotate-matrix.sh` -
  size-based ротация (100M/100M/10M) для `/var/log/matrix/`, nginx,
  letsencrypt.
- **nginx `http2 on;` директива** вместо устаревшего `listen 443 ssl http2;`
  (новый синтаксис обязателен для nginx 1.25.1+). Затронуто 7 server-блоков.
- **nginx `server_tokens` fix** - убрано из `matrix.conf` (был дубликат с
  `/etc/nginx/nginx.conf`), раскомментируется глобально в nginx.conf.
- **`tools/_lib.sh`** - общие `log/ok/info/warn/err/header_text/divider/die/yes_no/
  require_root/require_cmd/gen_dynamic_port`.
- **`tools/preflight.sh`** - DNS-резолв всех поддоменов, доступность
  80/443, certbot-сертификаты.
- **`tools/healthcheck.sh`** - состояние сервера, `--json` для мониторинга.
- **`tools/logrotate-matrix.sh`** - `/etc/logrotate.d/matrix-deploy-kit`.
- **`--full` режим в `deploy.sh`** - preflight → generate_vars →
  prepare_server → Ansible. `--skip-{preflight,prepare,ansible,wizard}`.
- **`--random-ports` в `prepare_server.sh` и `generate_vars.sh`** -
  автогенерация уникальных портов (49152-65535) для LiveKit/TURN/Ketesa/
  ElementAdmin. 1000 генераций - 0 коллизий.
- **`bots/expire-bot/requirements.txt`** - пины: `matrix-nio[e2e]>=0.25.0,<0.27.0`,
  `aiosqlite>=0.20.0,<1.0.0`, `aiohttp>=3.9.0,<4.0.0`, `PyYAML>=6.0,<7.0`.

### Fixed

- **`livekit-as-setup.sh` smoke не работал под `--log-driver=none`**: все
  MDAD-unit'ы создаются с `--log-driver=none` (stdout контейнера сбрасывается
  в никуда), поэтому grep'нуть строку "Using application service configuration"
  из `docker logs` нельзя by design. Проверка переведена на
  `docker inspect Config.Env` (LIVEKIT_AS_TOKEN/HS_TOKEN в живом контейнере).
  Плюс: если install-all обновил env-file, но условный restart проморгал
  (unit-файл не менялся), скрипт сам рестартит `matrix-livekit-jwt-service`
  и ждёт его подхвата (иначе AS-режим находится в полурабочем состоянии:
  vars.yml говорит "есть", а контейнер "нет").
- **`((x++))` тихо убивал скрипты под `set -e`** - post-increment возвращает
  старое значение, при 0 это статус 1. `nuke-user.sh` умирал на первой
  странице пейджинга и на первой комнате при redact, `test-ntfy.sh` - уже
  на первом warn/fail (не доходя до `exit 2`), `update.sh` - на первом
  найденном конфликте посередине. Заменено везде на `x=$((x + 1))`:
  `nuke-user.sh`, `test-ntfy.sh`, `update.sh`, `_lib.sh`.
- **`prepare_server.sh`: честный DNS-чек без внешнего IP** - если
  ifconfig.me не ответил, раньше все домены показывались `✓` просто
  по факту резолва (независимо от адреса), а certbot дальше падал без
  понятной причины. Теперь - жёлтое "не проверено" + `DNS_OK=false`
  + предупреждение в начале чека.
- **`prepare_server.sh --max-upload` валидируется** - раньше `abc`, `0`
  или `-3` молча попадали в три nginx-конфига как `abcM` и nginx не вставал.
  Теперь скрипт ругается сразу, до любых изменений на хосте.
- Дублирование `server_tokens` между `matrix.conf` и `/etc/nginx/nginx.conf`.
- `prepare_server.sh` defaults перевёрнуты в "лучший режим" (nginx,
  landing, ntfy, fail2ban, random ports ON; ufw ON, но отключаемый
  `--without-firewall` для cloud security group).
- `LANG_LEVEL` вывод в vars.yml безусловный (раньше блок опускался
  при WARNING, что маскировало настройку).
- Добавлены `matrix_server_fqn_*` overrides в vars.yml.

### Security

- **`nuke-user.sh`: `$USER_ID` больше не интерполируется в python-строку**
  для URL-экранирования - передаётся в `urllib.parse.quote` через argv.
  Раньше двойная кавычка в user id закрывала строку и позволяла выполнить
  произвольный python-код в контексте скрипта. `check_deps` теперь требует
  `python3` - он использовался на той же строке, но на наличие никогда не
  проверялся (на сервере без python3 скрипт бы умер посередине redact).
- **`generate_vars.sh`: `vars.yml` теперь создаётся с правами 0600** - в нём
  `matrix_homeserver_generic_secret_key`, пароль PostgreSQL и Cloudflare-
  токены, а при типичном umask файл падал 0644. Owner-only достаточно:
  ansible по kit-флоу запускается от того же пользователя. Заодно temp-файл
  `--dry-run` теперь удаляется по `trap EXIT` - раньше копился в `/tmp`.
- **`bots/expire-bot`: `session.json` пишется 0600** (был по umask 0644) -
  там access_token бота, доступный любому локальному юзеру на хосте через
  bind-mount `data/`.
- `--random-ports` устраняет предсказуемость сервисных портов
  (снижает шансы обнаружения сканерами, но не защищает от DPI).
- `preflight.sh` явно предупреждает, если 80 (ACME) не слушается -
  иначе обновление сертификатов сломается через 60-90 дней.
- `nuke-user.sh` - typed-подтверждение ("Введи 'DELETE'") + `--force`
  для автоматизации.

### Notes

- 19 shell-скриптов проходят `shellcheck -S error` (gate), `shfmt -d -i 4 -ci`
  (gate), `bash -n`. Включая `tools/livekit-as-setup.sh` и
  `tools/install-livekit-as.sh` (AS-режим) - оба под shfmt.
- 20 unit-тестов проходят (0.5s на этом ноуте). Запуск: `bash tools/tests/run-tests.sh`.
- 14 тестов на `_lib.sh` (gen_dynamic_port, yes_no, require_cmd, header_text,
  die) + 6 на `preflight.sh` (флаги, валидация, коды возврата).
- Python bot `bots/expire-bot/bot.py` проходит `py_compile`.
- env-file mode генерирует валидный YAML с 48 ключами верхнего уровня
  (проверено `yaml.safe_load`).

### Known limitations (см. docs/KNOWN-LIMITATIONS.md)

- **AS-режим (MSC4512) - экспериментальная фича**: при ручной установке
  блоков в vars.yml без pre-seed'а есть окно crash-loop Synapse (см.
  п.10 KNOWN-LIMITATIONS). В normal-потоке `deploy.sh` окно закрыто.
- Бэкап `media_store` Synapse пока не автоматизирован (требует target
  для restic/rsync).
- Нет multi-host/workers поддержки из коробки (MADA поддерживает, kit
  не предоставляет wizard).
- Нет встроенного мониторинга (только healthcheck.sh + можно
  подключить Prometheus).
- Нет поддержки Dendrite/Conduit.
- `generate_vars.sh` - 2.3k строк монолит, рефакторинг в модули
  требует отдельного захода.
