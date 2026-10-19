#!/bin/bash
set -e

DSH_HOME="/home/node/.dsh"
PROFILE="web"
PNPM_WS="$DSH_HOME/profiles/$PROFILE/pnpm-workspace.yaml"
CORDIS_PATCH="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"

# ============================================================================
# 1. КОНФИГУРАЦИЯ: списки плагинов
# ============================================================================

# --- Плагины для установки ---
# Порядок не важен. Для npm-пакетов и прямых URL .tgz логика установки одна.
PLUGINS=(
  # Базовые и проверенные
  "@opencode2dsh/dsh-plugin"
  "dsh-command-context-trim"
  "dsh-context@latest"
  "https://github.com/sxwer001/dsh-context-control/releases/download/v0.1.2/dsh-context-control-0.1.2.tgz"

  # Расширения интерфейса и удобства
  "dshmarket"                                   # Визуальный магазин плагинов внутри DSH
  "dsh-locale-russian"                          # Полная русская локализация интерфейса
  "@hytime/dsh-thinking-effort"                 # Управление уровнем "рассуждений" для моделей

  # Инструменты для работы
  "@hawk2048/oh-my-dsh"                         # Оркестрация и навыки в стиле oh-my-claudecode
  "@goodandready/dsh-messenger-gateway"         # Мост в Telegram для уведомлений и чата
  "dsh-mnemon"                                  # Трёхуровневая система памяти для агента
  "@shengsheng/dsh-taskboard"                   # Нативная канбан-доска для управления задачами
  "dsh-rss-digest"                              # RSS/Atom агрегатор с ежедневными сводками
)

# --- Плагины с несовместимыми версиями (требуют явного разрешения) ---
# Формат: "<package>@<version>". Авторы ещё не выпустили сборки под нашу версию DSH,
# но мы осознанно принимаем риск, чтобы получить функционал.
EXEMPT_PLUGINS=(
  "dsh-rss-digest@0.1.0"        # собран под 0.1.0-rc.6
  "dsh-context-control@0.1.2"   # собран под 0.2.0-rc.2
)

# ============================================================================
# 2. PNPM: разрешаем игнорирование build-скриптов у известных пакетов
# ============================================================================

echo "[dsh-entrypoint] Проверяем конфигурацию pnpm (allowBuilds)..."
mkdir -p "$DSH_HOME/profiles/$PROFILE"

if [ ! -f "$PNPM_WS" ]; then
  cat > "$PNPM_WS" <<'EOF'
allowBuilds:
  '@google/genai': false
  protobufjs: false
EOF
  echo "[dsh-entrypoint]   создан pnpm-workspace.yaml с allowBuilds."
else
  if ! grep -q "'@google/genai'" "$PNPM_WS" 2>/dev/null; then
    printf "\nallowBuilds:\n  '@google/genai': false\n  protobufjs: false\n" >> "$PNPM_WS"
    echo "[dsh-entrypoint]   добавлены allowBuilds в существующий pnpm-workspace.yaml."
  else
    echo "[dsh-entrypoint]   allowBuilds уже настроены."
  fi
fi

# ============================================================================
# 3. Принудительные разрешения для плагинов с несовместимыми версиями
# ============================================================================

# Определяем текущую версию DSH динамически, чтобы не хардкодить её.
DSH_VERSION=$(dsh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?' | head -1)
if [ -z "$DSH_VERSION" ]; then
  echo "[dsh-entrypoint] ВНИМАНИЕ: не удалось определить версию DSH, используем 0.2.1-rc.2"
  DSH_VERSION="0.2.1-rc.2"
fi
echo "[dsh-entrypoint] Версия DSH: $DSH_VERSION"

echo "[dsh-entrypoint] Выдаём разрешения для плагинов с несовместимыми версиями..."
for pkg in "${EXEMPT_PLUGINS[@]}"; do
  echo "[dsh-entrypoint]   allow-version: $pkg для DSH $DSH_VERSION"
  dsh plugin --profile "$PROFILE" allow-version \
    "$pkg" \
    --dsh-version "$DSH_VERSION" \
    --accept-risk || true
done

# ============================================================================
# 4. Установка плагинов из массива PLUGINS
# ============================================================================

echo "[dsh-entrypoint] Начинаем установку плагинов из списка..."

for plugin in "${PLUGINS[@]}"; do
  # Определяем "короткое имя" для проверки в списке установленных.
  if [[ "$plugin" == http* ]]; then
    short_name=$(basename "$plugin" .tgz | sed 's/-[0-9].*$//')
  else
    short_name=$(echo "$plugin" | sed 's/@[^/]*$//' | sed 's|^@[^/]*/||')
  fi

  echo "[dsh-entrypoint] Проверяем: $short_name"
  if dsh plugin --profile "$PROFILE" list 2>/dev/null | grep -q "$short_name"; then
    echo "[dsh-entrypoint]   уже установлен, пропускаем."
  else
    echo "[dsh-entrypoint]   устанавливаем $plugin ..."
    dsh plugin --profile "$PROFILE" add "$plugin"
    echo "[dsh-entrypoint]   установка завершена."
  fi
done

# ============================================================================
# 5. Специфичная настройка dsh-command-context-trim
# ============================================================================

echo "[dsh-entrypoint] Настраиваем dsh-command-context-trim в cordis.patch.yml..."
if [ ! -f "$CORDIS_PATCH" ]; then
  touch "$CORDIS_PATCH"
fi

if ! grep -q "id: dsh-command-context-trim" "$CORDIS_PATCH" 2>/dev/null; then
  cat >> "$CORDIS_PATCH" <<'EOF'

- id: dsh-command-context-trim
  name: dsh-command-context-trim
  config:
    thresholdRatio: 0.75
EOF
  echo "[dsh-entrypoint]   конфигурация добавлена."
else
  echo "[dsh-entrypoint]   конфигурация уже присутствует."
fi

# ============================================================================
# 6. Запуск: определение IP, socat-прокси, DSH
# ============================================================================

CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')
if [ -z "$CONTAINER_IP" ]; then
  echo "[dsh-entrypoint] ВНИМАНИЕ: не удалось определить IP, используем 127.0.0.1"
  CONTAINER_IP="127.0.0.1"
fi
echo "[dsh-entrypoint] IP контейнера: $CONTAINER_IP"
export DSH_BIND_HOST="$CONTAINER_IP"

echo "[dsh-entrypoint] Запускаем socat 0.0.0.0:3079 -> 127.0.0.1:3080..."
socat TCP-LISTEN:3079,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:3080 &
sleep 1

echo "[dsh-entrypoint] Запускаем DSH..."
exec /usr/local/bin/deepseek-harness-entrypoint web \
  --patch /opt/deepseek-harness/web.cordis.patch.yml \
  --no-open