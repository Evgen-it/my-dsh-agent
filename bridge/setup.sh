#!/bin/sh
set -e

echo "[setup] Генерируем патч от моста..."
python -m integrations.harness \
  --output /tmp/bridge.patch.yml \
  --without-browser \
  --default-model deepseek-expert \
  --base-url http://127.0.0.1:8000/v1 \
  --home /dsh-home

echo "[setup] Заменяем loopback URL на внутреннее имя сервиса bridge..."
sed -i 's|http://127.0.0.1:8000/v1|http://bridge:8000/v1|g' /tmp/bridge.patch.yml

echo "[setup] Сливаем патч в cordis.patch.yml профиля web..."
python /app/merge_patch.py \
  /tmp/bridge.patch.yml \
  /dsh-home/profiles/web/cordis.patch.yml

echo "[setup] Устанавливаем harness_shell_safety..."
python -m integrations.harness_shell_safety --profile web || true

# Права, чтобы DSH (node) мог дописывать конфиг
chmod -R a+rwX /dsh-home/profiles/web 2>/dev/null || true

echo "[setup] Готово."