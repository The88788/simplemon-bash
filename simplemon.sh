#!/usr/bin/env bash
# ============================================================
# simplemon.sh - мониторинг сайта и сервера, bash + cron
# Проверяет: HTTP-код и время ответа сайта, свободное место на диске
# Уведомляет на email при сбое и при восстановлении (без спама)
# Лог: /var/log/simplemon.log
# Установка: см. комментарии внизу файла
# ============================================================

# ---------- НАСТРОЙКИ ----------
SITE_URL="https://example.ru/"          # какой сайт проверяем
CHECK_NAME="Сайт example.ru"            # как подписывать в письмах
EMAILS="admin@example.ru,dir@example.ru" # куда слать уведомления (через запятую)
MAX_RESPONSE_TIME=10                     # секунд, дольше - считаем сбоем
DISK_THRESHOLD=90                        # % занятости диска, выше - предупреждение
DISK_PATH="/"                            # какой раздел контролируем
MAX_TIME=15                              # таймаут curl, секунд

STATE_DIR="/var/lib/simplemon"           # флаги состояния, чтобы не слать спам
LOG="/var/log/simplemon.log"
# ------------------------------

mkdir -p "$STATE_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() { echo "$(ts) $1" >> "$LOG"; }

send_mail() {
    # $1 - тема, $2 - текст. Требуется sendmail или mail (mailutils)
    local subject="$1" body="$2"
    if command -v mail >/dev/null 2>&1; then
        echo "$body" | mail -s "$subject" ${EMAILS//,/ }
    elif [ -x /usr/sbin/sendmail ]; then
        {
            echo "To: $EMAILS"
            echo "Subject: $subject"
            echo "Content-Type: text/plain; charset=utf-8"
            echo ""
            echo "$body"
        } | /usr/sbin/sendmail -t
    else
        log "ОШИБКА: нет mail и sendmail, письмо не отправлено: $subject"
    fi
}

# ---------- Проверка сайта ----------
check_http() {
    local result code time down_flag="$STATE_DIR/http.down"
    result=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
                  --max-time "$MAX_TIME" "$SITE_URL" 2>/dev/null)
    code="${result%% *}"
    time="${result##* }"

    if [ -z "$code" ]; then
        # curl вообще не получил ответ - сеть/днс/таймаут
        fail "Сервер не ответил за $MAX_TIME секунд (таймаут)"
        return
    fi

    if [ "$code" != "200" ]; then
        fail "HTTP-код $code (ожидался 200)"
        return
    fi

    # сравнение с порогом через awk (bc не везде стоит)
    if awk "BEGIN{exit !($time > $MAX_RESPONSE_TIME)}"; then
        fail "Ответ сервера $time сек, больше порога $MAX_RESPONSE_TIME сек"
        return
    fi

    # все хорошо - если был сбой, шлем восстановление
    if [ -f "$down_flag" ]; then
        rm -f "$down_flag"
        send_mail "$CHECK_NAME: восстановлен" \
            "$CHECK_NAME снова работает.
Время ответа: $time сек, HTTP $code.
Время восстановления: $(ts)"
        log "ВОССТАНОВЛЕНИЕ: HTTP $code, ${time} сек"
    else
        log "OK: HTTP $code, ${time} сек"
    fi
}

fail() {
    local reason="$1" down_flag="$STATE_DIR/http.down"
    if [ -f "$down_flag" ]; then
        # уже в сбое - просто лог, без повторных писем
        log "СБОЙ (продолжается): $reason"
    else
        touch "$down_flag"
        send_mail "$CHECK_NAME: СБОЙ" \
            "Проверка: $CHECK_NAME
Что случилось: $reason
Время начала: $(ts)
Следующее письмо придет при восстановлении."
        log "СБОЙ: $reason"
    fi
}

# ---------- Проверка диска ----------
check_disk() {
    local used disk_flag="$STATE_DIR/disk.down"
    used=$(df -P "$DISK_PATH" | awk 'NR==2{gsub(/%/,"",$5); print $5}')

    if [ -z "$used" ]; then
        log "ОШИБКА: не смог определить занятость диска $DISK_PATH"
        return
    fi

    if [ "$used" -ge "$DISK_THRESHOLD" ]; then
        if [ ! -f "$disk_flag" ]; then
            touch "$disk_flag"
            send_mail "$CHECK_NAME: мало места на диске" \
                "Раздел $DISK_PATH заполнен на $used%.
Порог срабатывания: $DISK_THRESHOLD%.
Проверьте логи и старые бэкапы, пока диск не закончился совсем."
            log "СБОЙ ДИСКА: занято $used%"
        else
            log "ДИСК (продолжается): занято $used%"
        fi
    else
        if [ -f "$disk_flag" ]; then
            rm -f "$disk_flag"
            send_mail "$CHECK_NAME: место на диске освободилось" \
                "Раздел $DISK_PATH теперь заполнен на $used%."
            log "ДИСК ВОССТАНОВЛЕН: занято $used%"
        fi
    fi
}

# ---------- Точка входа ----------
case "$1" in
    http)  check_http ;;
    disk)  check_disk ;;
    *)
        echo "Использование: $0 {http|disk}"
        echo "http - проверка сайта, вызывается cron каждые 5 минут"
        echo "disk - проверка диска, вызывается cron раз в час"
        exit 1
        ;;
esac

# ============================================================
# УСТАНОВКА:
# 1. Скопировать в /usr/local/bin/simplemon.sh, chmod +x
# 2. Поставить mailutils (Debian/Ubuntu: apt install mailutils)
#    или настроить msmtp - тогда письма уйдут через внешний SMTP,
#    а не через локальный сервер (надежнее для доставки)
# 3. Cron:
#    */5 * * * * /usr/local/bin/simplemon.sh http
#    7 * * * *   /usr/local/bin/simplemon.sh disk
# 4. Тест: остановить nginx на минуту - должно прийти письмо о сбое,
#    после запуска - письмо о восстановлении
# ============================================================
