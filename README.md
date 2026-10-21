
# DSH Agent Stack

Локальный агентный стек на базе **DeepSeek Harness (DSH)** с автоматической установкой плагинов, бесплатными моделями через **OpenCode Zen**, локальным мостом к аккаунтам **DeepSeek** и **Qwen**, аутентификацией через встроенный браузер DSH по CDP и полной изоляцией на `127.0.0.1`.

Проект собран с нуля как альтернатива самодельным мостам на официальном фреймворке DSH, где «всё есть плагин».

---

## Содержание

- [Архитектура](#архитектура)
- [Требования](#требования)
- [Структура проекта](#структура-проекта)
- [Быстрый старт](#быстрый-старт)
- [Управление (dsh.sh)](#управление-dshsh)
- [Аутентификация](#аутентификация)
- [Плагины](#плагины)
- [Модели](#модели)
- [Мост](#мост)
- [Конфигурация (.env)](#конфигурация-env)
- [Безопасность](#безопасность)
- [Troubleshooting](#troubleshooting)
- [TODO](#todo)
- [Ссылки](#ссылки)

---

## Архитектура

```
┌──────────────────────────────────────────────────────────────┐
│                     macOS (хосте)                            │
│                                                              │
│  ┌──────────────┐  127.0.0.1:3080  ┌─────────────────────┐   │
│  │   Браузер    │ ───────────────► │      Docker         │   │
│  └──────────────┘                  │                     │   │
│                                    │  ┌───────────────┐  │   │
│  ┌──────────────┐  127.0.0.1:6080  │  │  dsh          │  │   │
│  │ noVNC/браузер│ ───────────────► │  │  ┌──────────┐ │  │   │
│  └──────────────┘                  │  │  │ socat    │ │  │   │
│                                    │  │  │  :3079   │ │  │   │
│                                    │  │  └────┬─────┘ │  │   │
│                                    │  │       │       │  │   │
│                                    │  │  ┌────▼─────┐ │  │   │
│                                    │  │  │ DSH      │ │  │   │
│                                    │  │  │  :3080   │ │  │   │
│                                    │  │  │ Playwright│ │  │   │
│                                    │  │  │   CDP     │ │  │   │
│                                    │  │  └────┬─────┘ │  │   │
│                                    │  └───────┼───────┘  │   │
│                                    │          │ session  │   │
│                                    │  ┌───────▼───────┐  │   │
│                                    │  │  bridge       │  │   │
│                                    │  │  :8000        │  │   │
│                                    │  │  (DeepSeek +  │  │   │
│                                    │  │   Qwen HTTP)  │  │   │
│                                    │  └───────────────┘  │   │
│                                    └─────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**Поток данных:**

1. **DSH Web UI** доступен на `127.0.0.1:3080` (через `socat` внутри контейнера, чтобы обойти привязку DSH только к `127.0.0.1`).
2. **Встроенный браузер DSH** (кнопка «Браузер») открывается в noVNC на `127.0.0.1:6080`. Он же используется для входа в аккаунты.
3. **Аутентификация** запускается скриптом `start-auth-dsh.sh` **внутри контейнера DSH**. Playwright подключается к уже запущенному Chromium DSH по CDP (`http://127.0.0.1:9222`) и извлекает токен.
4. **Сессия** сохраняется в общий том `bridge-session` (в контейнере DSH — `/app/session`).
5. **Мост** (`bridge`) читает сессию из того же тома и предоставляет OpenAI-совместимый API на `http://bridge:8000/v1` внутри Docker-сети.
6. **DSH** через провайдера `local-browser-bridge` обращается к мосту и получает доступ к моделям DeepSeek и Qwen.

---

## Требования

- **macOS** (протестировано на MacBook Pro 2019 Intel) или Linux
- **Docker Desktop** с поддержкой Compose V2
- Свободные порты на `127.0.0.1`: `3080`, `6080`, `8000`
- Аккаунты: DeepSeek, Qwen (бесплатные или платные)
- ~2 GB свободного места в Docker

---

## Структура проекта

```
my-dsh-agent/
├── Dockerfile                      # Образ DSH: socat + Python + auth-файлы
├── entrypoint.sh                   # Установка плагинов при старте контейнера
├── docker-compose.yml              # DSH + bridge
├── start.sh                        # Главный оркестратор
├── dsh.sh                          # Утилита управления DSH
├── .gitignore                      # Исключения секретов и данных
├── workspace/                      # Рабочая директория агента
└── bridge/                         # Локальный мост (DmitrL-dev/opencode-deepseek)
    ├── Dockerfile                  # Облегчённый образ моста (без Chromium)
    ├── requirements.txt            # Зависимости моста
    ├── .env                        # Конфигурация провайдеров (НЕ КОММИТИТЬ)
    ├── settings.py                 # ROOT-путь + загрузка .env
    ├── setup.sh                    # Установка провайдера в DSH
    ├── merge_patch.py              # Слияние патча с cordis.patch.yml
    ├── start-auth-dsh.sh           # Аутентификация через CDP
    ├── deepseek/
    │   ├── auth.py                 # Playwright + CDP для DeepSeek
    │   └── __init__-dsh.py         # Ленивый __init__ (без client.py)
    └── qwen/
        └── auth.py                 # Playwright + CDP для Qwen
```

**Тома (volumes):**

- `dsh-home` — профили, плагины, `cordis.patch.yml`, сессии DSH, `node_modules`. **Никогда не удалять** — иначе придётся переустанавливать все плагины.
- `bridge-session` — сессии аккаунтов DeepSeek/Qwen и `api-token`. Общий для `dsh` и `bridge`. Можно очистить при необходимости перелогина.

---

## Быстрый старт

### 1. Клонирование и подготовка

```bash
git clone <ваш-репозиторий> my-dsh-agent
cd my-dsh-agent
cp bridge/.env.example bridge/.env
# Отредактируйте bridge/.env (см. раздел «Конфигурация»)
chmod +x start.sh dsh.sh bridge/start-auth-dsh.sh bridge/setup.sh
```

### 2. Запуск полного цикла

```bash
./start.sh
```

Скрипт последовательно:

1. Запускает контейнер `dsh`.
2. Ждёт готовности CDP-интерфейса браузера.
3. Открывает VNC и запускает аутентификацию (`start-auth-dsh.sh`).
4. Запускает мост.
5. Настраивает провайдера `local-browser-bridge` в DSH.
6. Перезапускает DSH и открывает Web UI в браузере.

**Во время аутентификации** (шаг 3) откройте в браузере:

```
http://127.0.0.1:6080/novnc-debian-1.6.0-2/vnc.html?autoconnect=1&resize=scale&view_only=0&reconnect=1
```

Внутри увидите Chromium с открытой страницей DeepSeek. Войдите в аккаунт, дождитесь, пока скрипт переключится на Qwen, войдите в Qwen. Сессия сохранится в `bridge-session`.

### 3. Повторный запуск

Если сессии уже есть, аутентификация всё равно попросит войти заново — просто пройдите её ещё раз (это быстро) или закомментируйте `start-auth-dsh.sh` в `start.sh`, если хотите пропустить.

### 4. Остановка

```bash
./dsh.sh down         # Только DSH
./dsh.sh down-all     # DSH + bridge + auth
```

---

## Управление (`dsh.sh`)

Утилита для ежедневной работы с DSH.

| Команда | Что делает |
| :--- | :--- |
| `./dsh.sh up` | Запустить DSH, дождаться токена, открыть Web UI |
| `./dsh.sh restart` | Перезапустить DSH и открыть **новый** URL (по смещению в логах) |
| `./dsh.sh rebuild` | Пересобрать образ и запустить |
| `./dsh.sh url` | Вывести текущий URL с токеном |
| `./dsh.sh open` | Открыть Web UI в браузере |
| `./dsh.sh status` | Показать статус контейнера и URL |
| `./dsh.sh logs` | Следить за логами (Ctrl+C для выхода) |
| `./dsh.sh down` | Остановить DSH |
| `./dsh.sh down-all` | Остановить все сервисы (DSH + bridge + auth) |

Если `dsh.sh` не исполни́м (`Permission denied`), используйте `bash dsh.sh <команда>` — это не зависит от прав файла.

---

## Аутентификация

Аутентификация выполняется **внутри контейнера DSH** через Playwright, подключённый по **CDP** к Chromium, который использует встроенный браузер DSH.

Перелогин без перезапуска всего стека:

Вариант A — из встроенного терминала DSH (в Web UI)
Если браузер DSH ещё не открыт — сначала откройте в Web UI кнопку «Браузер»

```bash
cd /app
python3 -m deepseek.auth --cdp-url http://127.0.0.1:9222
python3 -m qwen.auth --cdp-url http://127.0.0.1:9222
```

Вариант B — с хоста, одной командой

docker compose exec dsh bash -c "cd /app && python3 -m deepseek.auth --cdp-url http://127.0.0.1:9222"
docker compose exec dsh bash -c "cd /app && python3 -m qwen.auth --cdp-url http://127.0.0.1:9222"


### Как это работает

1. `start-auth-dsh.sh` вызывает `python3 -m deepseek.auth --cdp-url http://127.0.0.1:9222`.
2. `auth.py` через `p.chromium.connect_over_cdp(...)` подключается к уже запущенному Chromium DSH.
3. Открывает страницу `chat.deepseek.com`, ждёт, пока вы войдёте, и извлекает токен из `localStorage.userToken` + cookies.
4. Сохраняет сессию в `/app/session/session.json` (это общий том `bridge-session`).
5. Затем то же самое для Qwen (`qwen/auth.py` → `/app/session/qwen/session.json`).

### Вход через Google / Qwen

Иногда Google и Qwen блокируют автоматизированный браузер с сообщением **«This browser or app may not be secure»**. Причины и текущее состояние:

- **DeepSeek через Google** — проходит, если используется **Google Chrome**, установленный в контейнере (а не bundled Chromium Playwright).
- **Qwen через Google** — может блокироваться; вход через **GitHub** обычно работает.
- **Капча Qwen** — иногда не засчитывается; помогает повторная попытка или смена способа входа.

В `Dockerfile` DSH используется именно **системный Chromium**, а Playwright подключается через CDP, поэтому этот риск минимизирован. Если проблема повторится, см. раздел [TODO](#todo).

### Формат сессии

Мост ожидает **свой** формат, отличный от профиля Chrome:

- `/app/session/session.json` — DeepSeek (token, cookies, user-agent).
- `/app/session/qwen/session.json` — Qwen.
- `/app/session/api-token` — токен доступа к `/v1` моста (создаёт сам мост).

> **Важно:** просто зайти в браузере DSH и ожидать, что мост подхватит сессию, — **не сработает**. Мост читает только `session.json` в своём формате. Поэтому аутентификация запускается скриптом `start-auth-dsh.sh`, а не вручную.

---

## Плагины

Все плагины устанавливаются автоматически через `entrypoint.sh` при старте контейнера DSH. Список — в массиве `PLUGINS` в `entrypoint.sh`.

### Устанавливаемые плагины

| Плагин | Назначение |
| :--- | :--- |
| `@opencode2dsh/dsh-plugin` | Бесплатные модели OpenCode Zen (DeepSeek V4.1 Flash Free и др.) |
| `dsh-command-context-trim` | Ручная команда `/trim` + порог сжатия контекста (`thresholdRatio: 0.75`) |
| `dsh-context@latest` | Мониторинг контекста (панель `/context`) |
| `dshmarket` | Визуальный магазин плагинов внутри DSH |
| `dsh-locale-russian` | Полная русская локализация интерфейса |
| `@hytime/dsh-thinking-effort` | Управление «уровнем рассуждений» для моделей |
| `@hawk2048/oh-my-dsh` | 29 навыков + 12 слэш-команд из oh-my-claudecode |
| `@goodandready/dsh-messenger-gateway` | Мост в Telegram (уведомления, чат) |
| `dsh-mnemon` | Трёхуровневая система памяти агента |
| `@shengsheng/dsh-taskboard` | Канбан-доска для задач |
| `dsh-rss-digest` | RSS/Atom агрегатор с ежедневными сводками |

### Плагины с несовместимыми версиями

Некоторые плагины собраны под более старую версию DSH. Для них используется `dsh plugin allow-version` — это явное принятие риска:

- `dsh-rss-digest@0.1.0` — собран под `0.1.0-rc.6`, работает на `0.2.1-rc.2` с ограничениями.

Список — в массиве `EXEMPT_PLUGINS` в `entrypoint.sh`. Если плагин падает при загрузке (`SyntaxError: does not provide an export`), значит, он несовместим — уберите его из `PLUGINS`.

### Настройка `dsh-command-context-trim`

Автоматически прописывается в `cordis.patch.yml` профиля `web`:

```yaml
- id: dsh-command-context-trim
  name: dsh-command-context-trim
  config:
    thresholdRatio: 0.75
```

`thresholdRatio: 0.75` означает, что сжатие начинается при заполнении контекста на 75% (примерно 150K токенов из 200K у бесплатной модели). Оставшийся запас нужен, чтобы избежать резких обрывов.

---

## Модели

После запуска в Model Picker DSH появятся группы:

### `opencode2dsh` — бесплатные модели OpenCode Zen

- `deepseek-v4.1-flash-free` — бесплатная, 200K токенов контекста.

### `Local account bridge` — через локальный мост

| Модель | Провайдер | Контекст |
| :--- | :--- | :--- |
| `deepseek-chat` | DeepSeek web | 32K |
| `deepseek-expert` | DeepSeek web | 32K |
| `qwen3.8-max` | Qwen web | 32K |
| `qwen3.8-omni-flash` | Qwen web | 32K |
| `qwen3.7-plus` | Qwen web | 32K |

**Выбор модели по умолчанию** — `deepseek-expert` (настраивается через `--default-model` в `bridge/setup.sh`).

### Автоматическое сжатие контекста

Плагин `dsh-command-context-trim` отслеживает заполнение и запускает сжатие при достижении 75%. Ручная команда `/trim` доступна в любой момент.

Для бесплатной модели `deepseek-v4.1-flash-free` (200K токенов) это даёт запас ~50K токенов на сжатие и ответ.

---

## Мост

Мост основан на [DmitrL-dev/opencode-deepseek](https://github.com/DmitrL-dev/opencode-deepseek). Отличия от оригинального образа:

- **Нет Chromium** — Playwright не запускается, браузеры не устанавливаются. Аутентификация выполняется в контейнере DSH.
- **Минимальные зависимости** — только то, что нужно для HTTP-транспортов DeepSeek и Qwen.
- **`setup.sh` + `merge_patch.py`** — автоустановка провайдера в DSH с корректной заменой `127.0.0.1` → `bridge` в `cordis.patch.yml`.

### Как настроен провайдер

`setup.sh` выполняет:

1. `python -m integrations.harness --output /tmp/bridge.patch.yml ... --base-url http://127.0.0.1:8000/v1` — генерирует патч.
2. `sed` заменяет `http://127.0.0.1:8000/v1` → `http://bridge:8000/v1` — установщик требует loopback, но внутри Docker нужен сервис-хост.
3. `merge_patch.py` сливает патч в `/dsh-home/profiles/web/cordis.patch.yml`, удаляя дубликаты моделей.
4. `harness_shell_safety` устанавливает страховку от опасных shell-команд.

### Запуск только моста

```bash
docker compose --profile bridge up -d bridge
```

Проверка:

```bash
TOKEN=$(docker compose exec bridge cat /app/session/api-token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8000/v1/models
```

### Отладка

- Порт `127.0.0.1:8000` открыт **только для отладки**. Из DSH мост доступен по внутреннему имени `bridge:8000`.
- Логи: `docker compose logs bridge -f`.
- Токен: `docker compose exec bridge cat /app/session/api-token`.

---

## Конфигурация (`.env`)

Файл `bridge/.env` — конфигурация моста. **Не коммитится в git.**

### Минимальный набор для DeepSeek + Qwen (HTTP)

```ini
# --- Общие ---
HOST=0.0.0.0
PORT=8000
API_ALLOW_PUBLIC_BIND=1
API_ALLOWED_HOSTS=dsh-bridge,dsh-bridge:8000,bridge,localhost,127.0.0.1

# --- Таймауты ---
PROVIDER_RESPONSE_TIMEOUT=1800
PROVIDER_MIN_INTERVAL=30
CONVERSATION_MAX_REPLIES=20
DEEPSEEK_CONTEXT_ROLLOVER=1

# --- Инструкции инструментов ---
TOOL_INSTRUCTIONS_HTTP=light
TOOL_INSTRUCTIONS_BROWSER=light
TOOLCALL_MAX_CONTINUATIONS=0
TOOLCALL_FORMAT_REPAIR=0

# --- DeepSeek (http) ---
DEEPSEEK_ENABLED=1
DEEPSEEK_MAX_GENERATIONS_PER_HOUR=12
DEEPSEEK_MAX_GENERATIONS_PER_DAY=60
DEEPSEEK_MAX_CHATS_PER_HOUR=3
DEEPSEEK_MAX_CHATS_PER_DAY=6
DEEPSEEK_MAX_HTTP_PER_HOUR=40
DEEPSEEK_MAX_HTTP_PER_DAY=200

# --- Qwen (http) ---
QWEN_ENABLED=1
QWEN_TRANSPORT=http
QWEN_MODELS={"qwen3.8-omni-flash":"qwen3.8-omni-flash","qwen3.8-max":"qwen3.8-max","qwen3.7-plus":"qwen3.7-plus"}
QWEN_RENEW_SESSION=1

# --- Отключённые провайдеры (browser-транспорты нестабильны) ---
GEMINI_ENABLED=0
KIMI_ENABLED=0
GROK_ENABLED=0
MISTRAL_ENABLED=0
GLM_ENABLED=0
CHATGPT_ENABLED=0
CLAUDE_ENABLED=0
BROWSER_BRIDGE_ENABLED=0
```

### Транспорты

- **`http`** (DeepSeek, Qwen) — прямой HTTP к внутреннему API после однократного `python -m *.auth`. **Рекомендуется.**
- **`cli`** (Gemini) — через официальный CLI `agy`. Требует установки.
- **`browser`** (Grok, Mistral, GLM, ChatGPT, Claude) — эмуляция через вкладку браузера. **Нестабильно**, не используйте для агентных циклов.

---

## Безопасность

### Порты

Все публикуются **только на `127.0.0.1`** хоста. Сервисы недоступны из локальной сети.

| Порт | Сервис | Примечание |
| :--- | :--- | :--- |
| `127.0.0.1:3080` | DSH Web UI | Через `socat` внутри контейнера |
| `127.0.0.1:6080` | noVNC (браузер DSH) | Для входа в аккаунты |
| `127.0.0.1:8000` | Мост API | Только для отладки |

### Секреты (не коммитить!)

`.gitignore` **должен** содержать:

```gitignore
.env
bridge/.env
bridge-session/
dsh-home/
data/
*.log
workspace/
```

Никогда не коммитьте:

- `bridge/.env` — токены и настройки провайдеров.
- `bridge-session/` — cookies, токены, `session.json`, `api-token`.
- `dsh-home/` — профили, `cordis.patch.yml`, `.credentials.yaml`.

Если эти данные случайно попали в git — **немедленно смените пароли** и пересоздайте токены (`rm -rf bridge-session/*` и повторная аутентификация).

### WAF и детекция

Аутентификация через Playwright + CDP к системному Chromium минимизирует риск детекции:

- Используется **реальный Chromium** (не bundled Chrome for Testing).
- Отключён `navigator.webdriver` (флаг `--disable-blink-features=AutomationControlled`).
- CDP-подключение к живому браузеру DSH делает профиль «живым» (есть история, cookies).

Тем не менее, **не запускайте долгие автономные циклы** без присмотра — аккаунт может быть ограничен.

### Ограничения `dsh-context-control` (не используется)

Плагин `sxwer001/dsh-context-control` **несовместим** с DSH `0.2.1-rc.2` (требует `SessionSeq`, которого нет в старых `@deepseek-ai/dsh-session`). Заменён на `dsh-command-context-trim` + `dsh-context`.

---

## Troubleshooting

### `Permission denied` на `/app/session`

Том `bridge-session` смонтировался как `root:root`, а DSH работает от `node`. Убедитесь, что в `Dockerfile` **до** `USER node` есть:

```dockerfile
RUN mkdir -p /app/session && chown node:node /app/session
```

Затем пересоберите: `docker compose build --no-cache dsh`.

### `Bind for 127.0.0.1:6080 failed: port is already allocated`

Порт занят другим контейнером. Проверьте: `lsof -nP -iTCP:6080 -sTCP:LISTEN`. Если это старый `bridge-auth` — удалите его: `docker compose --profile auth rm -f bridge-auth`.

### `Could not reach http://.../v1/models`

Base URL в `cordis.patch.yml` указывает не туда. Проверьте:

```bash
docker compose exec dsh grep baseURL /home/node/.dsh/profiles/web/cordis.patch.yml
```

Должно быть `http://bridge:8000/v1` (не `127.0.0.1`). Если не так — перезапустите `setup.sh`:

```bash
docker compose exec bridge /app/setup.sh
```

### `421 Request Host is not served by this bridge`

В `bridge/.env` в `API_ALLOWED_HOSTS` нет имени, по которому DSH обращается к мосту. Добавьте `dsh-bridge,dsh-bridge:8000`:

```ini
API_ALLOWED_HOSTS=dsh-bridge,dsh-bridge:8000,bridge,localhost,127.0.0.1
```

Перезапустите мост: `docker compose --profile bridge restart bridge`.

### `error: --profile <name> is required`

В `entrypoint.sh` в `exec` не передан профиль `web`. Убедитесь, что последняя строка:

```bash
exec /usr/local/bin/deepseek-harness-entrypoint web \
  --patch /opt/deepseek-harness/web.cordis.patch.yml \
  --no-open
```

### `ERR_EMPTY_RESPONSE` в браузере

DSH слушает `127.0.0.1` внутри контейнера, а Docker не может туда достучаться. Решение — `socat` внутри контейнера:

```bash
socat TCP-LISTEN:3079,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:3080 &
```

Плюс маппинг порта в `docker-compose.yml`: `"127.0.0.1:3080:3079"`.

### `ModuleNotFoundError: No module named 'deepseek'` / `'providers'`

Проверьте `Dockerfile`: должны копироваться `bridge/deepseek/auth.py`, `bridge/deepseek/__init__-dsh.py` (как `__init__.py`), `bridge/qwen/auth.py`, `bridge/settings.py`. Ленивый `__init__` убирает зависимость от `providers/` и `client.py`.

### `This browser or app may not be secure` (Google)

См. раздел [Аутентификация](#аутентификация). В большинстве случаев помогает повторная попытка через GitHub или вход через email/password. Для документации оставлен TODO.

---

## TODO

Задачи на будущее и то, что стоит доработать:

- [ ] **Обход Google-блокировки** — описать в README рабочие комбинации флагов / способов входа для DeepSeek и Qwen. Сейчас иногда требуется retry или вход через GitHub.
- [ ] **Синхронизация сессии DSH ↔ мост** — сейчас два разных формата (`chrome-profile` и `session.json`). В будущем можно научить мост читать `chrome-profile` DSH напрямую.
- [ ] **Интеграция `cezar`** — рассмотреть оркестратор для параллельных задач; пока достаточно встроенной субагентной работы DSH.
- [ ] **Интеграция `Traefic`** — добавить прокси + панель аутентификаци.
- [ ] **Плагин `dsh-context-control`** — вернуть в `PLUGINS`, когда автор выпустит версию под `0.2.1-rc.2`.

---

## Ссылки

### Базовые репозитории

- **DSH (DeepSeek Harness)** — [github.com/deepseek-ai/dsh](https://github.com/deepseek-ai/dsh) (официальный фреймворк)
- **Базовый образ DSH** — [runzhliu/deepseek-harness-docker](https://github.com/runzhliu/deepseek-harness-docker)
- **Мост к аккаунтам** — [DmitrL-dev/opencode-deepseek](https://github.com/DmitrL-dev/opencode-deepseek)
- **Плагин OpenCode Zen** — `@opencode2dsh/dsh-plugin`

### Плагины DSH

- **dsh-context** (мониторинг) — `dsh-context@latest`
- **dsh-command-context-trim** (сжатие) — `dsh-command-context-trim`
- **dsh-market** (магазин) — `dshmarket`
- **dsh-locale-russian** (локализация) — `dsh-locale-russian`
- **oh-my-dsh** (навыки) — [@hawk2048/oh-my-dsh](https://github.com/hawk2048/oh-my-dsh)
- **dsh-messenger-gateway** (Telegram) — [@goodandready/dsh-messenger-gateway](https://github.com/goodandready/dsh-messenger-gateway)
- **dsh-mnemon** (память) — `dsh-mnemon`
- **dsh-taskboard** (канбан) — [@shengsheng/dsh-taskboard](https://github.com/shengsheng/dsh-taskboard)
- **dsh-rss-digest** (RSS) — `dsh-rss-digest`
- **dsh-thinking-effort** — [@hytime/dsh-thinking-effort](https://github.com/hytime/dsh-thinking-effort)

### Документация

- **Playwright CDP** — [playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp](https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp)
- **Docker Compose profiles** — [docs.docker.com/compose/profiles](https://docs.docker.com/compose/profiles/)
- **DeepSeek API** — [platform.deepseek.com](https://platform.deepseek.com/)
- **OpenCode Zen** — [opencode.ai](https://opencode.ai/)

---

## Лицензия

Проект использует сторонние компоненты. Соблюдайте лицензии:

- **DSH** — MIT (см. репозиторий)
- **DmitrL-dev/opencode-deepseek** — MIT (см. репозиторий)
- **runzhliu/deepseek-harness-docker** — MIT (см. репозиторий)
- **Плагины DSH** — каждая по своей лицензии

**Отказ от ответственности:** автоматизация веб-аккаунтов может нарушать условия использования сервисов (DeepSeek, Qwen, Google). Используйте на свой риск. Автор не несёт ответственности за блокировки аккаунтов.