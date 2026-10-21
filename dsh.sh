#!/bin/bash
# dsh.sh — утилита управления локальным стеком DSH

set -e
CONTAINER="dsh"
URL_PATTERN='http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+'

get_url() {
    docker compose logs --no-log-prefix --tail 200 "$CONTAINER" 2>/dev/null \
        | grep -oE "$URL_PATTERN" | tail -1
}

open_url() {
    local url="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    else
        echo "Откройте вручную: $url"
    fi
}

case "${1:-up}" in
    up)
        docker compose up -d
        echo -n "Ожидание старта DSH"
        for i in {1..60}; do
            URL=$(get_url)
            if [ -n "$URL" ]; then
                echo ""
                echo "✓ Готово: $URL"
                open_url "$URL"
                exit 0
            fi
            echo -n "."
            sleep 1
        done
        echo ""
        echo "✗ Не дождались за 60 сек. Логи: docker compose logs $CONTAINER" >&2
        exit 1
        ;;
    rebuild)
        docker compose up -d --build
        exec "$0" url-only-open
        ;;
    url)
        get_url || { echo "Токен не найден." >&2; exit 1; }
        ;;
    open)
        URL=$(get_url)
        [ -z "$URL" ] && { echo "Токен не найден." >&2; exit 1; }
        open_url "$URL"
        ;;
    logs)
        docker compose logs -f "$CONTAINER"
        ;;
    down)
        docker compose down
        ;;
    restart)
        docker compose restart "$CONTAINER"
        sleep 3
        exec "$0" open
        ;;
    *)
        echo "Использование: $0 {up|rebuild|url|open|logs|down|restart}"
        exit 1
        ;;
esac