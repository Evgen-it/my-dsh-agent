# Базовый образ: стабильный тег runzhliu (amd64/arm64)
FROM runzhliu/deepseek-harness:0.2.1-rc.2-r1

# Переключаемся на root для установки вспомогательного скрипта
USER root

# Устанавливаем socat для организации обратного прокси внутри контейнера
RUN apt-get update && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*

# Копируем наш entrypoint, который сначала установит плагин, а затем запустит оригинальный
COPY entrypoint.sh /usr/local/bin/dsh-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/dsh-entrypoint-wrapper.sh

# Возвращаем пользователя node (под ним работает DSH)
USER node

# Переопределяем ENTRYPOINT на наш wrapper.
# Оригинальный ENTRYPOINT образа — /usr/bin/tini -- /usr/local/bin/deepseek-harness-entrypoint
# Наш скрипт вызовет его после установки плагина.
ENTRYPOINT ["/usr/local/bin/dsh-entrypoint-wrapper.sh"]