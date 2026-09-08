# Contributing

Спасибо за интерес к `matrix-deploy-kit`. Здесь - минимум правил, чтобы ревью проходило быстро.

## Перед PR

1. Запусти `shellcheck -S error` и `shfmt -d -i 4 -ci` на изменённых `*.sh`.
2. Если меняешь `bots/expire-bot/bot.py` - `python -m py_compile` обязателен.
3. Обнови `docs/`, если меняешь поведение wizard'а или CLI-флаги.
4. Не коммить сгенерированные `vars.yml`, секреты, `data/`.

## Стиль

- Bash: `set -euo pipefail`, `#!/usr/bin/env bash`, 4 пробела, нижние регистры для локальных переменных, `UPPER_SNAKE` - только для констант/env.
- Python: PEP 8, type hints, dataclasses для конфигов, asyncio-first.
- Markdown: 120 символов мягкий предел, относительные ссылки.

## Коммиты

Conventional Commits (`fix:`, `feat:`, `refactor:`, `docs:`). В теле - почему, а не что.

## Политика

PR с разумным объёмом (< 500 строк diff) рассматриваются за 2-3 дня. Большие архитектурные изменения - сначала issue с обсуждением.
