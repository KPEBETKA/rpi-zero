#!/usr/bin/env bash
#
# nut-event-handler - handles UPS events and dispatches notifications / actions
#
# Invoked from upssched with an event argument:
#   ONBATT | ONLINE | LOWBATT | SHUTDOWN
#
# Side effects:
#   ONLINE  - stop battery tracker
#   ONBATT  - start battery tracker
#
# Notifications are sent via $SEND_SCRIPT (see config).
#
# Environment variables:
#   UPSNAME     - NUT UPS section name (set by upsmon)
#   CONFIG_FILE - config file path (default: /etc/nut/nut-event-handler.conf)
#
# Dependencies: upsc
#
set -u
set -o pipefail

# --- Helpers ----------------------------------------------------------------

log() { printf '[%s] event-handler: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# --- Config -----------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-/etc/nut/nut-event-handler.conf}"
if [[ ! -r "$CONFIG_FILE" ]]; then
    log "config not found: $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${SEND_SCRIPT:?SEND_SCRIPT is not set (see $CONFIG_FILE)}"
: "${PID_FILE:?PID_FILE is not set (see $CONFIG_FILE)}"
: "${TRACKER_SCRIPT:?TRACKER_SCRIPT is not set (see $CONFIG_FILE)}"

# --- Helpers (dependent on config) -----------------------------------------

ups_info() { upsc "${ups_id}@localhost" "$1" 2>/dev/null || true; }

stop_tracker() {
    local pid="" start="" tracker_name=""
    [[ -s "$PID_FILE" ]] || return 0
    pid=$(<"$PID_FILE")
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        rm -f "$PID_FILE"
        return 0
    fi
    tracker_name="${TRACKER_SCRIPT##*/}"
    if grep -qaF "$tracker_name" "/proc/$pid/cmdline" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        start=$SECONDS
        while kill -0 "$pid" 2>/dev/null && (( SECONDS - start < 5 )); do
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "tracker (pid $pid) did not exit within 5s, sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$PID_FILE"
}

# --- Main logic -------------------------------------------------------------
event="${1:-}"
if [[ -z "$event" ]]; then
    log "empty event argument, exiting"
    exit 0
fi

ups_id="${UPSNAME:-$UPS_NAME_DEFAULT}"
ups_id="${ups_id%@*}"

mfr=$(ups_info ups.mfr)
model=$(ups_info ups.model)
if [[ -n "$mfr" && -n "$model" ]]; then
    device_name="${mfr}${model}"
else
    device_name="$ups_id"
fi

# --- Build notification text ------------------------------------------------
case "$event" in
    ONLINE)
        emoji=":zap:"
        text="**Питание восстановлено!** ${device_name} переключился на работу от сети."
        ;;
    ONBATT)
        emoji=":warning:"
        text="**Внимание! Пропало внешнее питание.** ${device_name} переключился на работу от батареи."
        ;;
    LOWBATT)
        emoji=":sos:"
        text="**Критический уровень заряда!** ${device_name} почти разряжен. Сервер скоро выключится."
        ;;
    SHUTDOWN)
        emoji=":skull:"
        text="**Экстренное выключение!** Запущена процедура завершения работы."
        ;;
    *)
        emoji=":grey_question:"
        text="Изменение статуса ${device_name}: ${event}"
        ;;
esac

# --- Side effects per event -------------------------------------------------
case "$event" in
    ONLINE)
        stop_tracker
        ;;
    ONBATT)
        if [[ -x "$TRACKER_SCRIPT" ]]; then
            "$TRACKER_SCRIPT" "$ups_id" "$device_name" &
        else
            log "tracker not found: $TRACKER_SCRIPT"
        fi
        ;;
esac

# --- Send notification ------------------------------------------------------
"$SEND_SCRIPT" "$emoji" "$text" || log "failed to send notification"

exit 0