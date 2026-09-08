# Matrix Server - Deployment Kit

[![Matrix](https://img.shields.io/badge/Matrix-Server-blue)]()
[![Docker](https://img.shields.io/badge/Docker-ready-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![CI](https://github.com/)]()
[![Maintained](https://img.shields.io/badge/maintained-yes-green)]()

Полный набор скриптов для поднятия **Matrix homeserver** на базе
[matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy).

Развёртывание - **одна команда**. Дефолты - лучший режим: nginx + SSL + landing +
push-уведомления + рандомные порты + fail2ban. Firewall опционален
(большинство cloud-провайдеров уже использует security group). Хочешь иначе -
флаги, без правки конфигов.

---

# TL;DR - поднять за 5 минут

```bash
# 0. На чистом Ubuntu 22.04+ / Debian 12+ от root
# 1. Домен уже настроен (A/AAAA записи см. ниже)
# 2. Скопировать kit на сервер (или curl | bash)

bash deploy.sh --full --domain example.com --email admin@example.com
```

Что произойдёт (по порядку, без прыжков):

1. **Preflight** - DNS-резолв всех поддоменов → IP сервера, проверка портов 80/443.
2. **Wizard** - 12 секций ответов на ключевые вопросы (брендинг, ntfy, мосты).
3. **Prepare** - Docker, nginx, certbot (SSL на лету), fail2ban, рандомные порты
   для LiveKit/TURN. **ufw опционален** - `--with-firewall` если нужен.
4. **Ansible** - `just install-all` поднимает Synapse + Postgres + Element Web +
   LiveKit + ntfy + MAS.
5. **Создание админа** - в конце выводится готовая команда.

После: заходи на `https://element.example.com` → логин `admin` → работает.

---

# Что нужно ДО (чеклист)

Перед `deploy.sh --full` убедись:

- [ ] **Домен делегирован на IP сервера.** A/AAAA записи (минимум):
  ```
  example.com        A    <SERVER_IP>
  matrix.example.com A    <SERVER_IP>
  element.example.com A   <SERVER_IP>
  ```
  Если `--with-ntfy` (по умолчанию):
  ```
  ntfy.example.com   A    <SERVER_IP>
  ```
- [ ] **Порт 80/443 открыт** (провайдер / cloud security group).
- [ ] **Сервер: Ubuntu 22.04+ или Debian 12+** (другие дистрибутивы могут потребовать
  правок скрипта).
- [ ] **RAM:** 2 ГБ минимум / 4 ГБ рекомендуется. Подробнее - [docs/KNOWN-LIMITATIONS.md](docs/KNOWN-LIMITATIONS.md).
- [ ] **Ты работаешь от root** (или через `sudo`).

Проверить DNS до старта:
```bash
bash deploy.sh --full --domain example.com --skip-prepare --skip-ansible
# (только preflight; если всё OK - отмена Ctrl+C, потом без --skip-*)
```

---

# Развёртывание в 1 команду (`--full`)

## Сама команда

```bash
bash deploy.sh --full --domain example.com --email admin@example.com
```

Опциональные флаги:
```bash
--skip-preflight    # пропустить DNS-проверку
--skip-ansible      # только wizard + prepare (без установки Synapse)
--skip-wizard       # если vars.yml уже есть, переустановка
```

## Что спросит wizard (12 секций)

| Секция | О чём | Дефолт |
|--------|-------|--------|
| 1/12  | Домен + IP + кастомные поддомены | bare-домен, авто |
| 2/12  | Reverse proxy (nginx / Traefik-only) | nginx |
| 3/12  | Сеть, SSH-порт, swap | 22, 2G |
| 4/12  | Регистрация, токены, email | выкл |
| 5/12  | **Сервисы** (вкл/выкл: LiveKit, ntfy, мосты, **брендинг ntfy**) | лучший режим |
| 6/12  | **Element Web** (название, тема, лого, регистрация, footer) | умные дефолты |
| 7/12  | Мосты (Telegram / WhatsApp / Discord) | выкл |
| 8/12  | Боты (expire-bot) | выкл |
| 9/12  | SMTP | выкл |
| 10/12 | **Логирование Synapse + размеры** | WARNING |
| 11/12 | Безопасность, ipset, firewall | базово |
| 12/12 | Бэкап (расписание, retention) | раз в день, 7 дней |

Если не знаешь ответ - везде Enter, дефолты = "лучший режим".

## Что делает после wizard (без твоего участия)

1. **Preflight** - проверяет что DNS резолвится, 80/443 свободны. Если FAIL -
   выведет подсказки "что делать". Можно продолжить (`y`) или прервать.
2. **Prepare** (~5-10 мин):
   - swap (если нет)
   - Docker + Ansible + just
   - nginx + certbot (`/etc/letsencrypt/live/<domain>/`)
   - fail2ban
   - landing page + `/tos` на `matrix.<domain>`
   - ntfy поддомен (если включён)
   - **Случайные порты** для LiveKit/TURN/Ketesa/ElementAdmin (выводятся в лог)
   - **ufw firewall** - опционален, включается через `--with-firewall`
     (если не передан - порты открываются в cloud security group, не в iptables)
3. **Ansible** (~10-20 мин):
   - `just roles` (загрузка ansible-ролей)
   - `just install-all` (установка Synapse + Postgres + Element + LiveKit + ntfy + MAS)
4. **Готово** - вывод "Что дальше" с командой создания админа.

## Создать админа (последний шаг)

`--full` режим НЕ создаёт админа автоматически - это ручной шаг. Команда
выводится в конце:

```bash
docker exec matrix-authentication-service \
  mas-cli manage register-user --yes admin --password '<ПАРОЛЬ>' --admin
```

> Поменяй `<ПАРОЛЬ>` на свой. Юзер `admin` станет администратором homeserver'а.

---

# Пошаговый режим (если хочешь контролировать каждый шаг)

```bash
# 1. Скопировать kit на сервер
scp -r matrix-deploy-kit/ root@<SERVER_IP>:/root/

# 2. SSH + bootstrap (только клонирует плейбук и копирует tools/templates)
ssh root@<SERVER_IP>
bash /root/matrix-deploy-kit/deploy.sh
# (без --full - интерактивный wizard и остановка)

# 3. Подготовить сервер (Docker, nginx, SSL, firewall)
bash /root/matrix-docker-ansible-deploy/tools/prepare_server.sh \
  --domain example.com --email admin@example.com
# (все флаги опциональны, дефолты = лучший режим)
# Нужно отключить компонент? --without-ntfy, --without-firewall, ...

# 4. Деплой Synapse
cd /root/matrix-docker-ansible-deploy
export LC_ALL=C.UTF-8
just roles
just install-all

# 5. Создать админа
docker exec matrix-authentication-service \
  mas-cli manage register-user --yes admin --password '<ПАРОЛЬ>' --admin
```

---

# Что после деплоя

Сразу после установки рекомендую прогнать:

```bash
# 1. Общая проверка здоровья (docker, compose, homeserver, postgres, proxy, диск)
bash /root/matrix-docker-ansible-deploy/tools/healthcheck.sh

# 2. Проверить, что ntfy-доставка работает (для push на Android/iOS)
bash /root/matrix-deploy-kit/tools/test-ntfy.sh --domain example.com

# 3. Настроить ротацию логов (иначе диск съест через 1-2 недели)
bash /root/matrix-deploy-kit/tools/logrotate-matrix.sh

# 4. На клиенте Element Android/iOS: Settings → Notifications →
#    UnifiedPush: Force custom push gateway → https://ntfy.example.com
```

## Сводка по всем скриптам (tools/)

| Скрипт | Назначение |
|--------|-----------|
| `preflight.sh` | Проверка DNS / портов / сертификатов перед деплоем |
| `healthcheck.sh` | Проверка состояния работающего сервера (`--json` для мониторинга) |
| `test-ntfy.sh` | Диагностика push-доставки (well-known, anonymous publish/subscribe) |
| `logrotate-matrix.sh` | Установка logrotate-конфига для `/var/log/matrix/`, nginx, certbot |
| `generate_vars.sh` | Wizard для генерации `vars.yml` (12 секций) |
| `prepare_server.sh` | Подготовка хоста (Docker, nginx, SSL, firewall) |
| `update.sh` | Обновление стека (git pull + ansible) |
| `backup.sh` | Бэкап (`pg_dumpall` + конфиги) |
| `restore.sh` | Восстановление из снимка |
| `nuke-user.sh` | Полное удаление пользователя (GDPR) |
| `tune-system.sh` | sysctl + ulimit для Synapse |
| `migrate-to-compose-v2.sh` | Разовая миграция docker-compose v1 → v2 |
| `_lib.sh` | Общая библиотека (log/warn/die/gen_dynamic_port) |

## Обновление

```bash
cd /root/matrix-docker-ansible-deploy
bash tools/update.sh
```

Обновит kit, плейбук и переустановит всё без потери данных. Перед апдейтом
рекомендую `git diff inventory/host_vars/matrix.<domain>/vars.yml` - если
upstream MADA поменял имена переменных, будут видны breaking changes.

## Бэкап

```bash
bash /root/matrix-docker-ansible-deploy/tools/backup.sh
# По крону: 0 4 * * *  (ежедневно в 4 утра)
```

Сохраняет `pg_dumpall` (БД Synapse + MAS) и конфиги в `/var/matrix/backup/`.
**Не сохраняет `media_store`** (загруженные файлы) - это сознательное
ограничение, см. [docs/KNOWN-LIMITATIONS.md](docs/KNOWN-LIMITATIONS.md).

## Мониторинг

```bash
# JSON для Prometheus / Zabbix / etc:
*/5 * * * *  bash /root/matrix-docker-ansible-deploy/tools/healthcheck.sh --json
```

Если healthcheck находит проблемы - выход с кодом 2 (мониторинг может
алертить).

---

# Документация

- [`docs/DEPLOY-GUIDE.md`](docs/DEPLOY-GUIDE.md) - подробное пошаговое руководство
- [`docs/PERF-TUNING.md`](docs/PERF-TUNING.md) - тюнинг Synapse / Postgres / LiveKit под нагрузку
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) - частые проблемы (включая ntfy push)
- [`docs/VARS-REFERENCE.md`](docs/VARS-REFERENCE.md) - справочник по всем переменным `vars.yml`
- [`docs/KNOWN-LIMITATIONS.md`](docs/KNOWN-LIMITATIONS.md) - что kit сознательно не покрывает (RAM-минимумы, media_store, мониторинг, multi-DC)
- [`CONTRIBUTING.md`](CONTRIBUTING.md) - как контрибьютить
- [`CHANGELOG.md`](CHANGELOG.md) - история изменений

---

# Требования

## Система

- **Ubuntu 22.04+** или **Debian 12+**
- **2 ГБ RAM** минимум, 4 ГБ рекомендуется (см. [KNOWN-LIMITATIONS](docs/KNOWN-LIMITATIONS.md))
- ~10 ГБ диска под `/matrix` (растёт с нагрузкой и media_store)

## Открытые порты

С `prepare_server.sh` "лучший режим" (по умолчанию):

```
22     SSH (настраивается)
80     HTTP (certbot ACME, редирект)
443    HTTPS (matrix/element/ntfy)
8448   Federation (если не через 443)
N     LiveKit RTC TCP  (случайный 49152-65535)
N     LiveKit RTC UDP  (случайный)
N     LiveKit TURN TLS (случайный)
N     LiveKit TURN UDP (случайный)
```

`prepare_server.sh` сам открывает всё это в `ufw` **только если передан `--with-firewall`**
(по умолчанию firewall выключен - у большинства cloud-провайдеров уже есть
security group). В остальных случаях порты нужно открыть в cloud console.
В облаке / у провайдера открой **80 и 443** как минимум, плюс federation
(8448) и LiveKit-порты (если звонки планируются).

---

# Структура репозитория

```
matrix-deploy-kit/
├── deploy.sh                       # точка входа (--full или интерактивно)
├── tools/                          # 14 скриптов (см. таблицу выше)
├── templates/                      # landing + /tos + /error
├── bots/expire-bot/                # бот авто-экспирации аккаунтов
├── docs/                           # 5 .md файлов
├── .github/workflows/ci.yml        # shellcheck + shfmt + py_compile + smoke
├── LICENSE                         # MIT
├── CHANGELOG.md
├── CONTRIBUTING.md
├── .editorconfig / .shellcheckrc / .gitignore
```

---

# Основано на

[matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy) - Slavi Pantaleev и контрибьюторы.
