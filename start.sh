#!/bin/bash
set -euo pipefail
export COMPOSE_PROGRESS=plain
COMPOSE_FILE="docker-compose.yml"
AUTH_SERVICE="dsh-bridge-auth"
BRIDGE_SERVICE="bridge"

# 1. Чистим старый auth и запускаем новый
echo "🚀 Запуск auth-контейнера для проверки сессий AI моделей..."
docker compose -f "$COMPOSE_FILE" rm -f "$AUTH_SERVICE" < /dev/null >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" up -d "$AUTH_SERVICE" < /dev/null >/dev/null

# 2. Сразу показываем URL VNC — нечего ждать маркера
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  👉 Откройте VNC, если потребуется авторизация:"
echo "     http://localhost:6081/vnc.html"
echo "     (пароль не требуется, браузер уже открыт внутри)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Логи auth-контейнера (Ctrl+C прервёт ожидание):"
echo ""

# 3. Хвостим логи в фоне
docker compose -f "$COMPOSE_FILE" logs -f --no-log-prefix "$AUTH_SERVICE" < /dev/null 2>&1 &
LOGS_PID=$!
trap "kill $LOGS_PID 2>/dev/null || true" EXIT INT TERM

# 4. Опрашиваем статус контейнера
AUTH_EXIT=1
while true; do
    STATE=$(docker compose -f "$COMPOSE_FILE" ps -a --format json "$AUTH_SERVICE" 2>/dev/null \
        | grep -o '"State":"[^"]*"' | cut -d'"' -f4 || echo "missing")

    if [ "$STATE" = "exited" ]; then
        AUTH_EXIT=$(docker inspect --format='{{.State.ExitCode}}' \
            "$(docker compose -f "$COMPOSE_FILE" ps -a -q "$AUTH_SERVICE")" 2>/dev/null || echo "1")
        break
    fi
    sleep 2
done

# 5. Останавливаем tail логов
kill $LOGS_PID 2>/dev/null || true
wait $LOGS_PID 2>/dev/null || true

echo ""
if [ "$AUTH_EXIT" -ne 0 ]; then
    echo "❌ Auth-контейнер завершился с кодом $AUTH_EXIT"
    echo ""
    echo "   Возможные причины:"
    echo "   - Не успели залогиниться за 5 минут"
    echo "   - Браузер не открылся (проверьте: channel=None)"
    echo "   - Проблема с WAF"
    exit 1
fi

# 6. Успех — оставляем auth в exited-состоянии, чтобы depends_on работал
echo "✅ Сессия сохранена."
echo "🚀 Запускаю рабочие контейнеры..."
docker compose --profile $BRIDGE_SERVICE up -d $BRIDGE_SERVICE

# Ждём healthz
echo "⏳ Ожидание моста..."
for i in {1..60}; do
    if curl -sf http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
        echo "✅ Мост поднят."
        break
    fi
    sleep 1
done

# Настраиваем провайдера в DSH одной командой
echo "⚙️  Настраиваем провайдера Local account bridge в DSH..."
docker compose exec bridge /app/setup.sh

echo ""
echo "✨  Запускаю DSH через существующий скрипт"
echo ""
./dsh.sh up