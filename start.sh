#!/bin/bash
set -euo pipefail
export COMPOSE_PROGRESS=plain

echo "🚀 Запускаем DSH..."
docker compose up -d dsh

# Ждём, пока CDP-интерфейс браузера DSH станет доступен
echo "⏳ Ожидание CDP-интерфейса браузера DSH..."
for i in {1..60}; do
    if docker compose exec -T dsh curl -sf http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
        echo "✅ CDP доступен."
        break
    fi
    sleep 2
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  👉 Откройте VNC для входа в аккаунты:"
echo "     http://127.0.0.1:6080/novnc-debian-1.6.0-2/vnc.html?autoconnect=1&resize=scale&view_only=0&reconnect=1"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Запускаем аутентификацию внутри DSH (использует существующий браузер через CDP)
echo "🔐 Запускаем аутентификацию внутри DSH..."
docker compose exec dsh /app/start-auth-dsh.sh

echo "✅ Аутентификация завершена."

# Запускаем мост
echo "🚀 Запускаем мост..."
docker compose --profile bridge up -d bridge

# Ждём healthz
for i in {1..60}; do
    if curl -sf http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
        echo "✅ Мост поднят."
        break
    fi
    sleep 1
done

# Настраиваем провайдера
echo "⚙️  Настраиваем провайдера Local account bridge в DSH..."
docker compose exec bridge /app/setup.sh

# Перезапускаем DSH, чтобы он подхватил новый конфиг
echo "🔄 Перезапускаем DSH..."

bash dsh.sh restart

echo "✨ Готово."