# Базовый образ: стабильный тег runzhliu (amd64/arm64)
FROM runzhliu/deepseek-harness:0.2.1-rc.2-r1

# Переключаемся на root для установки вспомогательного скрипта
USER root

# socat для reverse-proxy + Python для скриптов аутентификации
RUN apt-get update && apt-get install -y --no-install-recommends \
    socat \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# зависимости моста и ставим их в DSH
RUN pip3 install --no-cache-dir --break-system-packages --ignore-installed \
    "playwright>=1.44" \
    "python-dotenv>=1.0"

# Копируем только auth-файлы
COPY bridge/settings.py /app/settings.py
COPY bridge/deepseek/auth.py /app/deepseek/auth.py
COPY bridge/deepseek/__init__-dsh.py /app/deepseek/__init__.py
COPY bridge/qwen/auth.py /app/qwen/auth.py
RUN touch /app/qwen/__init__.py

COPY bridge/start-auth-dsh.sh /app/start-auth-dsh.sh
RUN chmod +x /app/start-auth-dsh.sh

# КРИТИЧНО: создаём /app/session с владельцем node
RUN mkdir -p /app/session && chown node:node /app/session

# Копируем наш entrypoint, который сначала установит плагин, а затем запустит оригинальный
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/dsh-entrypoint-wrapper.sh

# Возвращаем пользователя node (под ним работает DSH)
USER node

# Переопределяем ENTRYPOINT на наш wrapper.
# Оригинальный ENTRYPOINT образа — /usr/bin/tini -- /usr/local/bin/deepseek-harness-entrypoint
# Наш скрипт вызовет его после установки плагина.
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint-wrapper.sh"]