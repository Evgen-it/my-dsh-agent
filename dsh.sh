#!/bin/bash
# dsh.sh — утилита управления локальным стеком DSH

set -e

CONTAINER="dsh"
URL_PATTERN='http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+'
WAIT_SECONDS=60

# Цвета только при выводе в терминал
if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''
fi

# --- Хелперы --------------------------------------------------------------

get_url() {
    docker compose logs --no-log-prefix --tail 200 "$CONTAINER" 2>/dev/null \
        | grep -oE "$URL_PATTERN" | tail -1
}

# URL, появившийся в логах ПОСЛЕ указанной строки (для restart)
get_url_after_line() {
    local line_num="$1"
    docker compose logs --no-log-prefix "$CONTAINER" 2>/dev/null \
        | tail -n +"$((line_num + 1))" \
        | grep -oE "$URL_PATTERN" | tail -1
}

get_log_lines() {
    docker compose logs --no-log-prefix "$CONTAINER" 2>/dev/null | wc -l | tr -d ' '
}

open_url() {
    local url="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        echo -e "${DIM}Откройте вручную: $url${NC}"
    fi
}

wait_and_open() {
    echo -n "Ожидание старта DSH"
    for _ in $(seq 1 "$WAIT_SECONDS"); do
        local url
        url=$(get_url)
        if [ -n "$url" ]; then
            echo ""
            echo -e "${GREEN}✓ Готово:${NC} $url"
            open_url "$url"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    echo -e "${RED}✗ Не дождались за ${WAIT_SECONDS} сек.${NC}" >&2
    echo -e "${DIM}Логи: docker compose logs $CONTAINER${NC}" >&2
    return 1
}

wait_for_new_url() {
    local old_line="$1"
    echo -n "Ожидание нового токена"
    for _ in $(seq 1 "$WAIT_SECONDS"); do
        local url
        url=$(get_url_after_line "$old_line")
        if [ -n "$url" ]; then
            echo ""
            echo -e "${GREEN}✓ Готово:${NC} $url"
            open_url "$url"
            return 0
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    echo -e "${RED}✗ Не дождались за ${WAIT_SECONDS} сек.${NC}" >&2
    echo -e "${DIM}Логи: docker compose logs $CONTAINER${NC}" >&2
    return 1
}

# --- Команды --------------------------------------------------------------

case "${1:-up}" in
    up)
        docker compose up -d
        wait_and_open || exit 1
        ;;
    rebuild)
        echo -e "${YELLOW}🔨 Пересборка образа и перезапуск...${NC}"
        docker compose up -d --build
        wait_and_open || exit 1
        ;;
    restart)
        old_lines=$(get_log_lines)
        echo -e "${YELLOW}🔄 Перезапуск DSH...${NC}"
        docker compose restart "$CONTAINER"
        wait_for_new_url "$old_lines" || exit 1
        ;;
    url)
        url=$(get_url)
        if [ -z "$url" ]; then
            echo -e "${RED}Токен не найден.${NC} Запустите: $0 up" >&2
            exit 1
        fi
        echo "$url"
        ;;
    open)
        url=$(get_url)
        if [ -z "$url" ]; then
            echo -e "${YELLOW}Токен не найден, ожидаем появления...${NC}"
            wait_and_open || exit 1
        else
            echo -e "${GREEN}✓ Открываю:${NC} $url"
            open_url "$url"
        fi
        ;;
    logs)
        docker compose logs -f "$CONTAINER"
        ;;
    status)
        echo -e "${YELLOW}=== Контейнер $CONTAINER ===${NC}"
        docker compose ps "$CONTAINER"
        echo ""
        url=$(get_url)
        if [ -n "$url" ]; then
            echo -e "${GREEN}Текущий URL:${NC} $url"
        else
            echo -e "${DIM}URL пока не найден (контейнер не запускался или токен не сгенерирован).${NC}"
        fi
        ;;
    down)
        echo -e "${YELLOW}⏹  Останавливаем DSH...${NC}"
        docker compose down
        echo -e "${GREEN}✓ Остановлено.${NC}"
        ;;
    down-all)
        echo -e "${YELLOW}⏹  Останавливаем все сервисы (DSH + bridge + auth)...${NC}"
        docker compose --profile bridge --profile auth --profile setup down --remove-orphans
        echo -e "${GREEN}✓ Всё остановлено.${NC}"
        ;;
    *)
        cat <<EOF
Использование: $0 {команда}

${YELLOW}Команды:${NC}
  up         Запустить DSH и открыть Web UI в браузере
  restart    Перезапустить DSH и открыть новый URL
  rebuild    Пересобрать образ и запустить
  url        Вывести текущий URL с токеном
  open       Открыть Web UI в браузере
  status     Показать статус контейнера и текущий URL
  logs       Следить за логами DSH (Ctrl+C для выхода)
  down       Остановить DSH (profile-сервисы не трогает)
  down-all   Остановить все сервисы (DSH + bridge + auth)

${YELLOW}Примеры:${NC}
  ./dsh.sh up
  ./dsh.sh restart
  ./dsh.sh status
EOF
        exit 1
        ;;
esac