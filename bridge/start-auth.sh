#!/bin/bash
set -e

rm -f /tmp/.X99-lock /tmp/.X11-unix/X99

# Убираем шум от Openbox (не критично, просто чище логи)
mkdir -p /var/lib/openbox
touch /var/lib/openbox/debian-menu.xml

Xvfb :99 -screen 0 ${RESOLUTION} -ac &
sleep 2

# Openbox — минимальный оконный менеджер
openbox &
sleep 1

x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -quiet &
websockify --web /usr/share/novnc/ 6080 localhost:5900 &
sleep 1

# Если какая-то аутентификация не нужна, просто закомментируйте шаг
# (или наоборот добавьте). Скрипт не сломается.

echo "=== VNC ready: http://localhost:6081/vnc.html ==="

echo "=== Step 1: Waiting for DeepSeek sign-in... ==="
python -m deepseek.auth

echo "=== Step 2: Waiting for Qwen sign-in... ==="
exec python -m qwen.auth

# exit 0