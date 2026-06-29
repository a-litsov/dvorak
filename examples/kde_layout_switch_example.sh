#!/usr/bin/env bash
# kde_layout_switch_example.sh [dvorak|us|ua|ru]
# Switches KDE Plasma keyboard layout and signals dvorak daemons:
#   base layout (default: us) -> dvorak-signal.sh on
#   other layouts             -> dvorak-signal.sh off

set -u

SIGNAL_SCRIPT="/usr/local/bin/dvorak-signal.sh"
BASE_LAYOUT="${BASE_LAYOUT:-us}"
KXKBRC="${KXKBRC:-$HOME/.config/kxkbrc}"
QDBUS_BIN=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>/tmp/dvorak-layout.log
}

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
    shift
    [[ -n "$QDBUS_BIN" ]] || return 1
    "$QDBUS_BIN" org.kde.keyboard /Layouts "$method" "$@" 2>/dev/null
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

read_layout_list() {
    local list
    [[ -r "$KXKBRC" ]] || return 1

    list=$(awk -F= '
        /^\[Layout\]$/ { in_layout=1; next }
        /^\[/ { in_layout=0 }
        in_layout && $1=="LayoutList" { print $2; exit }
    ' "$KXKBRC" 2>/dev/null)

    [[ -n "$list" ]] || return 1
    printf '%s\n' "$list"
}

layout_from_index() {
    local idx="$1"
    local list
    local -a layouts

    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    list="$(read_layout_list)" || return 1
    IFS=',' read -r -a layouts <<<"$list"
    (( idx < ${#layouts[@]} )) || return 1
    normalize_layout "${layouts[$idx]}"
}

index_for_layout() {
    local wanted
    local list
    local -a layouts
    local i

    wanted="$(normalize_layout "$1")"
    list="$(read_layout_list)" || return 1
    IFS=',' read -r -a layouts <<<"$list"

    for i in "${!layouts[@]}"; do
        if [[ "$(normalize_layout "${layouts[$i]}")" == "$wanted" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done

    return 1
}

get_current_index() {
    local raw
    local method

    for method in \
        org.kde.KeyboardLayouts.getLayout \
        org.kde.KeyboardLayouts.currentLayout \
        org.kde.KeyboardLayouts.getCurrentLayout; do
        raw="$(qdbus_call "$method")"
        raw="$(trim "$raw")"
        [[ "$raw" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$raw"
        return 0
    done

    return 1
}

signal_dvorak() {
    local mode="$1"
    if [[ -x "$SIGNAL_SCRIPT" ]]; then
        "$SIGNAL_SCRIPT" "$mode" >>/tmp/dvorak-layout.log 2>&1
        log "signal=$mode exit=$?"
    else
        log "signal script not found or not executable: $SIGNAL_SCRIPT"
    fi
}

set_layout_index() {
    local idx="$1"
    local method

    for method in \
        org.kde.KeyboardLayouts.setLayout \
        org.kde.KeyboardLayouts.setCurrentLayout \
        org.kde.KeyboardLayouts.setLayoutByIndex; do
        if qdbus_call "$method" "$idx" >/dev/null; then
            return 0
        fi
    done

    return 1
}

switch_to_index() {
    local idx="$1"
    local layout
    local base_norm

    if ! set_layout_index "$idx"; then
        echo "Failed to switch KDE layout to index $idx" >&2
        exit 1
    fi

    layout="$(layout_from_index "$idx" 2>/dev/null || true)"
    base_norm="$(normalize_layout "$BASE_LAYOUT")"

    if [[ -n "$layout" && "$layout" == "$base_norm" ]]; then
        signal_dvorak on
    else
        signal_dvorak off
    fi
}

pick_qdbus
if [[ -z "$QDBUS_BIN" ]]; then
    echo "qdbus6/qdbus not found" >&2
    exit 1
fi

if [[ -n "${1:-}" ]]; then
    case "$1" in
        dvorak|us|ua|ru)
            idx="$(index_for_layout "$1" 2>/dev/null || true)"
            if [[ -z "$idx" ]]; then
                echo "Layout '$1' is not present in $KXKBRC LayoutList" >&2
                exit 1
            fi
            switch_to_index "$idx"
            ;;
        *)
            echo "Unknown layout: $1" >&2
            echo "Usage: $0 [dvorak|us|ua|ru]" >&2
            exit 1
            ;;
    esac
else
    current="$(get_current_index 2>/dev/null || true)"
    if [[ "$current" == "0" ]]; then
        idx="$(index_for_layout "ua" 2>/dev/null || true)"
        [[ -n "$idx" ]] || idx=1
        switch_to_index "$idx"
    else
        idx="$(index_for_layout "dvorak" 2>/dev/null || true)"
        [[ -n "$idx" ]] || idx=0
        switch_to_index "$idx"
    fi
fi
