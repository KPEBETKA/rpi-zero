#!/usr/bin/env bash
#
# nut-battery-tracker - sends battery charge level to Mattermost while UPS
# is running on battery.
#
# Invoked only from nut-event-handler.sh (in background):
#   nut-battery-tracker.sh <UPS_ID> <DEVICE_NAME>
#
# Stopped by TERM signal (ONLINE branch of the event handler), or exits on
# its own when mains returns or when upsd connection is lost persistently.
#
# Environment variables:
#   CONFIG_FILE - config file path (default: /etc/nut/nut-event-handler.conf)
#
# Dependencies: upsc
#
set -u
set -o pipefail

# --- Arguments --------------------------------------------------------------
if (( $# != 2 )); then
    printf 'Usage: %s <UPS_ID> <DEVICE_NAME>\n' "${0##*/}" >&2
    exit 2
fi
ups_id="$1"
device_name="$2"

# --- Helpers ----------------------------------------------------------------

log() { printf '[%s] tracker: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

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
: "${POLL_INTERVAL:?POLL_INTERVAL is not set (see $CONFIG_FILE)}"
: "${MAX_FAILS:?MAX_FAILS is not set (see $CONFIG_FILE)}"

# --- Helpers (dependent on config) -----------------------------------------

cleanup() {
    local pid=""
    [[ -s "$PID_FILE" ]] && pid=$(<"$PID_FILE")
    # Remove PID file only if it belongs to us (race protection on early exit)
    [[ "$pid" == "$$" ]] && rm -f "$PID_FILE"
    return 0
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

ups_info() { upsc "${ups_id}@localhost" "$1" 2>/dev/null || true; }

format_runtime() {
    # $1 - raw battery.runtime; prints "N h. M min." / "M min." / ""
    local raw="${1:-}" sec="" hours="" minutes=""
    sec=${raw%%.*}                 # integer part (strip .0 and tail)
    sec=${sec//[!0-9]/}            # keep only digits
    [[ -n "$sec" ]] || return 0
    sec=$(( 10#$sec ))             # force base-10 (guard against 0120)
    (( sec > 0 )) || return 0
    hours=$(( sec / 3600 ))
    minutes=$(( (sec % 3600) / 60 ))
    if (( hours > 0 )); then
        printf '%d h. %d min.' "$hours" "$minutes"
    else
        printf '%d min.' "$minutes"
    fi
}

# --- Guard against concurrent start ----------------------------------------
tracker_name="${0##*/}"
if [[ -s "$PID_FILE" ]]; then
    pid=$(<"$PID_FILE")
    if [[ "$pid" =~ ^[0-9]+$ ]] && \
       grep -qaF "$tracker_name" "/proc/$pid/cmdline" 2>/dev/null; then
        log "tracker already running (pid $pid), exiting"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

# --- Atomic PID write -------------------------------------------------------
if ! printf '%s\n' "$$" > "${PID_FILE}.tmp" \
   || ! mv -f "${PID_FILE}.tmp" "$PID_FILE"; then
    rm -f "${PID_FILE}.tmp"
    log "failed to write PID file $PID_FILE"
    exit 1
fi

# --- Main loop --------------------------------------------------------------
fail=0

# Warm-up: skip the first notification right after ONBATT - the event handler
# has already sent "Mains power lost". Comment out these three lines if you
# want an immediate report with the current charge level.
last_reported_charge=""
first_charge=$(ups_info battery.charge)
if [[ "$first_charge" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    last_reported_charge="${first_charge%%.*}"
fi

while :; do
    status=$(ups_info ups.status)
    charge_raw=$(ups_info battery.charge)
    runtime_raw=$(ups_info battery.runtime)

    if [[ -z "$status" ]]; then
        (( fail++ )) || true
        log "upsc returned no status ($fail/$MAX_FAILS)"
        if (( fail >= MAX_FAILS )); then
            log "too many failures, exiting"
            exit 1
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    fail=0

    # Continue only while status contains OB (on battery)
    [[ "$status" == *"OB"* ]] || { log "mains returned, exiting"; break; }

    # Validate charge: must be numeric
    if [[ ! "$charge_raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        sleep "$POLL_INTERVAL"
        continue
    fi
    charge="${charge_raw%%.*}"

    if [[ "$charge" != "$last_reported_charge" ]]; then
        time_left=$(format_runtime "$runtime_raw")
        [[ -n "$time_left" ]] || time_left="рассчитывается..."

        text="Текущий уровень заряда ${device_name}: **${charge}%** (заряда хватит, примерно, на **${time_left}**)"

        if "$SEND_SCRIPT" ":battery:" "$text"; then
            last_reported_charge="$charge"
        fi
    fi

    sleep "$POLL_INTERVAL"
done

exit 0