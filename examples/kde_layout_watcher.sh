#!/usr/bin/env bash
# kde_layout_watcher.sh — Companion to dvorak-signal.sh for KDE Plasma.
# Tracks current KDE keyboard layout and switches dvorak mode:
#   base layout (default: us) -> dvorak-signal.sh on
#   any other layout          -> dvorak-signal.sh off

set -u

SCRIPT_NAME="$(basename "$0")"
PIDFILE="/tmp/${SCRIPT_NAME}.pid"
SIGNAL_SCRIPT="/usr/local/bin/dvorak-signal.sh"
BASE_LAYOUT="${BASE_LAYOUT:-us}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
KXKBRC="${KXKBRC:-$HOME/.config/kxkbrc}"
LAST_LAYOUT=""
QDBUS_BIN=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>/tmp/dvorak-layout.log
}

kill_previous_instance() {
    local old_pid
    old_pid=""
    [[ -f "$PIDFILE" ]] && old_pid="$(<"$PIDFILE")"

    if [[ -n "$old_pid" && "$old_pid" =~ ^[0-9]+$ && "$old_pid" != "$$" ]] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null
        sleep 0.3
        kill -9 "$old_pid" 2>/dev/null
    fi

    printf '%s\n' "$$" >"$PIDFILE"
}

cleanup() {
    [[ -f "$PIDFILE" && "$(<"$PIDFILE")" == "$$" ]] && rm -f "$PIDFILE"
}
trap cleanup EXIT

pick_qdbus() {
    if command -v qdbus6 >/dev/null 2>&1; then
        QDBUS_BIN="qdbus6"
    elif command -v qdbus >/dev/null 2>&1; then
        QDBUS_BIN="qdbus"
    else
        QDBUS_BIN=""
    fi
}

qdbus_call() {
    local method="$1"
    [[ -n "$QDBUS_BIN" ]] || return 1
    "$QDBUS_BIN" org.kde.keyboard /Layouts "$method" 2>/dev/null
}

trim() {
    local s="$1"
    s="${s#${s%%[![:space:]]*}}"
    s="${s%${s##*[![:space:]]}}"
    printf '%s' "$s"
}

normalize_layout() {
    local v
    v="$(trim "$1")"
    v="${v,,}"
    v="${v%%(*}"
    v="${v%%+*}"
    v="${v%%,*}"
    v="${v%%:*}"
    trim "$v"
}

layout_from_index() {
    local idx="$1"
    local list
    local -a layouts

    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    [[ -r "$KXKBRC" ]] || return 1

    list=$(awk -F= '
        /^\[Layout\]$/ { in_layout=1; next }
        /^\[/ { in_layout=0 }
        in_layout && $1=="LayoutList" { print $2; exit }
    ' "$KXKBRC" 2>/dev/null)

    [[ -n "$list" ]] || return 1
    IFS=',' read -r -a layouts <<<"$list"
    (( idx < ${#layouts[@]} )) || return 1
    normalize_layout "${layouts[$idx]}"
}

get_current_layout() {
    local raw
    local parsed
    local method

    for method in \
        org.kde.KeyboardLayouts.getLayout \
        org.kde.KeyboardLayouts.currentLayout \
        org.kde.KeyboardLayouts.getCurrentLayout; do
        raw="$(qdbus_call "$method")"
        [[ -n "$raw" ]] || continue
        raw="$(trim "$raw")"
        [[ -n "$raw" ]] || continue

        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            parsed="$(layout_from_index "$raw" 2>/dev/null || true)"
            if [[ -n "$parsed" ]]; then
                printf '%s\n' "$parsed"
                return 0
            fi
        fi

        parsed="$(normalize_layout "$raw")"
        if [[ -n "$parsed" ]]; then
            printf '%s\n' "$parsed"
            return 0
        fi
    done

    return 1
}

signal_for_layout() {
    local layout="$1"
    local base_norm
    local layout_norm

    [[ -n "$layout" ]] || return
    [[ "$layout" == "$LAST_LAYOUT" ]] && return
    LAST_LAYOUT="$layout"

    base_norm="$(normalize_layout "$BASE_LAYOUT")"
    layout_norm="$(normalize_layout "$layout")"

    if [[ ! -x "$SIGNAL_SCRIPT" ]]; then
        log "signal script not found or not executable: $SIGNAL_SCRIPT"
        return
    fi

    if [[ "$layout_norm" == "$base_norm" ]]; then
        "$SIGNAL_SCRIPT" on >>/tmp/dvorak-layout.log 2>&1
        log "layout=${layout_norm:-unknown} -> on"
    else
        "$SIGNAL_SCRIPT" off >>/tmp/dvorak-layout.log 2>&1
        log "layout=${layout_norm:-unknown} -> off"
    fi
}

update_from_current_layout() {
    local layout
    layout="$(get_current_layout 2>/dev/null || true)"
    [[ -n "$layout" ]] && signal_for_layout "$layout"
}

run_polling_loop() {
    log "watch mode: polling (${POLL_INTERVAL}s)"
    while true; do
        update_from_current_layout
        sleep "$POLL_INTERVAL"
    done
}

run_dbus_monitor_loop() {
    if ! command -v dbus-monitor >/dev/null 2>&1; then
        return 1
    fi

    log "watch mode: dbus-monitor"
    while IFS= read -r line; do
        [[ "$line" == *"member="* ]] && update_from_current_layout
    done < <(dbus-monitor --session "type='signal',sender='org.kde.keyboard',path='/Layouts'" 2>/dev/null)

    return 1
}

kill_previous_instance
pick_qdbus

if [[ -z "$QDBUS_BIN" ]]; then
    log "qdbus6/qdbus not found; cannot detect KDE layout"
    exit 1
fi

LAST_LAYOUT=""
update_from_current_layout

run_dbus_monitor_loop || run_polling_loop
