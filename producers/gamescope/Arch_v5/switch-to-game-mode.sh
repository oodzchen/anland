#!/usr/bin/env bash
# Leave the KDE Anland session and start anland-game-mode on the same display socket.
# The desktop entry runs this inside Plasma; the switch itself continues detached
# because logging out ends every process of the session.
# Log of the last switch: ~/.local/state/anland/switch-to-game-mode.log
set -euo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname -- "$SELF")"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/anland"
LOG="$STATE_DIR/switch-to-game-mode.log"
KDE_PROCESSES=(startplasma-wayland plasma_session plasmashell kwin_wayland_wrapper kwin_wayland)
note() { printf 'switch-to-game-mode: %s\n' "$*" >&2; }

# KDE's startup.sh holds the shared session lock on fd 9, and Plasma's children inherit it.
exec 9>&-

if [[ -n ${ANLAND_GAME_MODE_CMD:-} ]]; then
    GAME_MODE="$ANLAND_GAME_MODE_CMD"
elif [[ -x "$SELF_DIR/startup.sh" ]]; then
    GAME_MODE="$SELF_DIR/startup.sh"
else
    GAME_MODE=anland-game-mode
fi

# Game mode starts from a login-like environment, not Plasma's (WAYLAND_DISPLAY, kgsl, Qt).
CLEAN_ENV=()
for var in HOME USER LOGNAME SHELL PATH LANG LC_ALL TZ XDG_RUNTIME_DIR XDG_CONFIG_HOME \
    XDG_STATE_HOME ANLAND_SOCKET ANLAND_DRM_DEVICE ANLAND_GAME_MODE_CONF; do
    [[ -z ${!var:-} ]] || CLEAN_ENV+=("$var=${!var}")
done

report_error() {
    note "$1"
    if command -v kdialog >/dev/null; then
        kdialog --title 'Game Mode' --error "$1" >/dev/null 2>&1 &
    elif command -v notify-send >/dev/null; then
        notify-send -a 'Game Mode' 'Cannot switch to Game Mode' "$1" >/dev/null 2>&1 &
    fi
}

# Full command lines: pgrep -x only sees the first 15 characters (startplasma-way).
pattern() { printf '(^|/)%s([[:space:]]|$)' "$1"; }
running() {
    local name
    for name in "$@"; do
        pgrep -u "$(id -u)" -f "$(pattern "$name")" >/dev/null && return 0
    done
    return 1
}

if [[ ${1:-} != --detached ]]; then
    command -v "$GAME_MODE" >/dev/null ||
        { report_error "Game mode is not installed: $GAME_MODE"; exit 1; }
    # Never log out of the desktop when game mode would not start afterwards.
    if ! check="$(env -i "${CLEAN_ENV[@]}" "$GAME_MODE" --check 2>&1)"; then
        report_error "$(grep '^problem' <<<"$check" | sed 's/^problem *//' || printf '%s' "$check")"
        exit 1
    fi
    mkdir -p -- "$STATE_DIR"
    export ANLAND_SWITCH_KDE_BUS="${DBUS_SESSION_BUS_ADDRESS:-}" ANLAND_GAME_MODE_CMD="$GAME_MODE"
    # A process inside the game mode unit would die with the desktop it handed over to.
    if systemctl --user show-environment >/dev/null 2>&1; then
        setenv=()
        for entry in "${CLEAN_ENV[@]}"; do setenv+=(--setenv="$entry"); done
        systemd-run --user --collect --quiet --unit="anland-switch-to-game-mode-$$" \
            "${setenv[@]}" --setenv=ANLAND_SWITCH_KDE_BUS --setenv=ANLAND_GAME_MODE_CMD \
            "$SELF" --detached
    else
        setsid -f "$SELF" --detached </dev/null >"$LOG" 2>&1
    fi
    exit 0
fi

exec >"$LOG" 2>&1
note "started $(date '+%F %T'); game mode: $GAME_MODE"
mkdir -p -- "${XDG_RUNTIME_DIR:?}"
exec 7>"$XDG_RUNTIME_DIR/anland-switch-to-game-mode.lock"
flock -n 7 || { note 'another switch is in progress'; exit 1; }

if pid="$(pgrep -u "$(id -u)" -f "$(pattern steam)" | head -n1)" && [[ -n "$pid" ]]; then
    note 'asking the desktop Steam client to exit'
    "$(readlink -f "/proc/$pid/exe")" -shutdown >/dev/null 2>&1 || true
    for _ in {1..60}; do running steam || break; sleep 0.5; done
    if running steam; then
        note 'Steam did not exit; terminating it'
        pkill -TERM -u "$(id -u)" -f "$(pattern steam)" || true
        sleep 2
    fi
fi

if running "${KDE_PROCESSES[@]}"; then
    note 'logging out of Plasma'
    if [[ -n ${ANLAND_SWITCH_KDE_BUS:-} ]]; then
        DBUS_SESSION_BUS_ADDRESS="$ANLAND_SWITCH_KDE_BUS" dbus-send --session --type=method_call \
            --dest=org.kde.Shutdown /Shutdown org.kde.Shutdown.logout ||
        DBUS_SESSION_BUS_ADDRESS="$ANLAND_SWITCH_KDE_BUS" dbus-send --session --type=method_call \
            --dest=org.kde.ksmserver /KSMServer org.kde.KSMServerInterface.logout int32:0 int32:0 int32:0 ||
            note 'Plasma did not accept the logout request'
    fi
    for _ in {1..60}; do running "${KDE_PROCESSES[@]}" || break; sleep 0.5; done
    for signal in TERM KILL; do
        running "${KDE_PROCESSES[@]}" || break
        note "Plasma is still running; sending SIG$signal"
        for name in "${KDE_PROCESSES[@]}"; do pkill "-$signal" -u "$(id -u)" -f "$(pattern "$name")" || true; done
        for _ in {1..20}; do running "${KDE_PROCESSES[@]}" || break; sleep 0.5; done
    done
fi

# Leftover desktop programs may still hold the inherited session lock.
LOCK="$XDG_RUNTIME_DIR/anland-producer-session.lock"
lock_holders() {
    local fd
    for fd in /proc/[0-9]*/fd/*; do
        [[ "$(readlink "$fd" 2>/dev/null)" == "$LOCK" ]] || continue
        fd="${fd#/proc/}"
        printf '%s\n' "${fd%%/*}"
    done | sort -u
}
# flock(1) holds the file only in its own short-lived process, so this shell never shows up as a holder.
if [[ -e "$LOCK" ]] && ! flock -w 10 "$LOCK" true; then
    mapfile -t holders < <(lock_holders)
    note "session lock still held by: ${holders[*]:-unknown}; terminating them"
    for pid in "${holders[@]}"; do
        [[ -r "/proc/$pid/cmdline" ]] || continue
        note "  $pid $(tr '\0' ' ' < "/proc/$pid/cmdline")"
        kill -TERM "$pid" 2>/dev/null || true
    done
    flock -w 10 "$LOCK" true || { note 'session lock is still held; not starting game mode'; exit 1; }
fi

note 'starting game mode'
exec env -i "${CLEAN_ENV[@]}" "$GAME_MODE"
