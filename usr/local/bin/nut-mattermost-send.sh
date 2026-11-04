#!/usr/bin/env bash
#
# nut-mattermost-send - send a single message to Mattermost via webhook
#
# Usage:
#   nut-mattermost-send.sh <emoji> <text>
#
# Environment variables:
#   CONFIG_FILE  - config file path (default: /etc/nut/nut-event-handler.conf)
#   SEND_TIMEOUT - optional timeout override (default: 10; for :skull: -> 3)
#
# Dependencies: curl, jq
#
set -u
set -o pipefail

# --- Arguments --------------------------------------------------------------
if (( $# != 2 )); then
    printf 'Usage: %s <emoji> <text>\n' "${0##*/}" >&2
    exit 2
fi
emoji="$1"
text="$2"

# --- Config -----------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-/etc/nut/nut-event-handler.conf}"
if [[ ! -r "$CONFIG_FILE" ]]; then
    printf 'config not found: %s\n' "$CONFIG_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${WEBHOOK_URL:?WEBHOOK_URL is not set (see $CONFIG_FILE)}"
: "${MATTERMOST_USER:?MATTERMOST_USER is not set (see $CONFIG_FILE)}"

# --- Dependency checks ------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is not installed\n' >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    printf 'curl is not installed\n' >&2
    exit 1
fi

# --- Build payload ----------------------------------------------------------
if ! payload=$(jq -n \
        --arg user  "$MATTERMOST_USER" \
        --arg emoji "$emoji" \
        --arg text  "$emoji $text" \
        '{username: $user, icon_emoji: $emoji, text: $text}'); then
    printf 'jq failed to build payload\n' >&2
    exit 1
fi

# --- Determine timeout ------------------------------------------------------
# Use a short timeout for critical SHUTDOWN notifications (:skull:) so a dead
# Mattermost does not delay the actual shutdown procedure.
max_time="${SEND_TIMEOUT:-10}"
if [[ "$emoji" == ":skull:" ]]; then
    max_time="${SEND_TIMEOUT:-3}"
fi

# --- Send -------------------------------------------------------------------
if ! curl -fsS --max-time "$max_time" --connect-timeout 5 \
        -H 'Content-Type: application/json' \
        -d "$payload" "$WEBHOOK_URL" >/dev/null; then
    rc=$?
    printf 'curl failed with exit %d\n' "$rc" >&2
    exit "$rc"
fi