# Known Limitations

Этот документ описывает, что **не входит** в `matrix-deploy-kit`, чтобы не было
сюрпризов. Если что-то из списка ниже - это ваш случай, нужно либо
самостоятельно, либо через внешние инструменты.

## Что НЕ входит

### 1. Бэкап `media_store` Synapse
`tools/backup.sh` снимает `pg_dumpall` (база Synapse + MAS) - это критично и
восстановимо. **Но он не снимает `media_store`** - каталог с загруженными
картинками/аудио/файлами, который обычно занимает десятки гигабайт и часто
дороже БД. **Без него restore восстановит переписку, но не вложения.**

Что делать:
- Настройте отдельный бэкап `/matrix/synapse/storage` через `restic` / `borg`
  / `rsync` в S3-совместимое хранилище.
- В `backup.sh` запланирована вторая стадия (`media_store` через restic), но
  требует решения о target-сторадже.

### 2. Мониторинг и алертинг
Kit не отправляет уведомления "что-то сломалось". Используйте внешние системы:
- Prometheus + node_exporter + cAdvisor (для docker-метрик)
- Uptime Kuma / Healthchecks.io - для внешних пингов
- `tools/healthcheck.sh --json` готов для крона и парсинга в мониторинг

### 3. Auto-scaling / multi-host
Kit разворачивает всё на **одном хосте**. Synapse workers, sharding БД, несколько
homeserver-нод за load balancer - это уровень MADA, но kit не предоставляет
wizard для этого. По умолчанию подходит для ~500-1000 активных пользователей.

### 4. Multi-DC / disaster recovery
Активный/пассивный failover между дата-центрами, geo-DNS, поднятие Matrix
в Kubernetes - за пределами kit. Для прод-критичных инсталляций используйте
infrastructure-as-code (Terraform + Ansible) и внешние DR-процедуры.

### 5. Matrix <-> XMPP / IRC federations
`matrix-appservice-irc` поддерживает входящий IRC-мост (юзеры IRC видят
Matrix-комнаты), но **исходящий** федеративный XMPP-шлюз kit не покрывает.
Если нужен XMPP-федерация - отдельный проект.

### 6. Масштабирование одного бота `expire-bot`
Бот работает по принципу "один процесс = один homeserver-юзер = один
event-loop". На homeserver с тысячами комнат:
- rate limit Matrix API становится узким местом;
- SQLite-стейт нормально до ~10k комнат, потом стоит переходить на Postgres.

Для больших инсталляций переписывайте на **appservice** (получает все
events через dedicated stream, без rate limit).

### 7. Поддержка Dendrite / Conduit
Kit жёстко завязан на Synapse (через MADA). Если upstream MADA добавит
первоклассную поддержку Dendrite - добавим; сейчас переход на другой
homeserver = ручная работа.

### 8. Версионирование `vars.yml`-схемы
При обновлении MADA spantaleev может поменять имена переменных. Kit
автоматически подставляет `matrix_playbook_migration_validated_version:
"{{ matrix_playbook_migration_expected_version }}"`, чтобы Ansible не падал,
но **это маскирует breaking changes**. Перед `update.sh` рекомендуется
пробежаться по `CHANGELOG.md` upstream-плейбука.

### 9. UI для всего `matrix_client_element_*`
Секция `6/12` wizard'а покрывает самые частые брендинг-настройки (название,
тема, лого, фон, регистрация, footer-ссылки). **Полный** список переменных
Element Web (~50+) - в MADA defaults; если нужна тонкая настройка - правьте
`inventory/host_vars/matrix.<domain>/vars.yml` руками.

## RAM-минимумы (для дефолтного набора сервисов)

| Сервисы | RAM минимум | Рекомендуется |
|---------|-------------|---------------|
| Synapse (только) | 1 ГБ | 2 ГБ |
| + Postgres | 1.5 ГБ | 2.5 ГБ |
| + Element Web | 1.5 ГБ | 2.5 ГБ |
| + LiveKit (звонки) | 2 ГБ | 3 ГБ |
| + ntfy (push) | 2.5 ГБ | 4 ГБ |
| + Expire-bot | +50 МБ | незначительно |
| + Bridges (каждый) | +100-300 МБ | по нагрузке |
| + Element Admin (Ketesa) | +200 МБ | 512 МБ |

**Дефолтный kit** (Synapse + Postgres + Element Web + LiveKit + ntfy) - 4 ГБ
рекомендуется, 3 ГБ - нижний предел с отключённым swap'ом.

## Что НЕ нужно чинить руками

- Certbot-обновление сертификатов - `certbot.timer` systemd + cron-скрипт в
  playbook'е, автообновляются каждые 60 дней для сертификатов короче 30 дней.
- Логи - `docker compose logs` (или Portainer / Dozzle / Loki, если настроите
  сами).
- PostgreSQL-бэкапы - `tools/backup.sh` через `pg_dumpall`, читает все
  базы (включая MAS).
