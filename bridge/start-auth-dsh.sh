#!/bin/bash
set -e

CDP_URL=${CDP_URL:-http://127.0.0.1:9222}

# Переходим в /app, чтобы Python нашёл пакеты deepseek и qwen
cd /app
export PYTHONPATH=/app:${PYTHONPATH:-}

echo "=== Используем существующий браузер DSH через CDP: $CDP_URL ==="

echo "=== Шаг 1: Вход в DeepSeek... ==="
python3 -m deepseek.auth --cdp-url "$CDP_URL"

echo "=== Шаг 2: Вход в Qwen... ==="
python3 -m qwen.auth --cdp-url "$CDP_URL"

echo "=== Аутентификация завершена. Сессии сохранены. ==="