#!/usr/bin/env bash
# Steam game mode on Gamescope/Anland for Arch Linux ARM (Droidspaces); no KWin.
# Usage: anland-game-mode [--check] [-- COMMAND...]
# Settings come from the environment, then ~/.config/anland/game-mode.conf,
# then /run/droidspaces.env; already-set values are never overridden.
set -euo pipefail
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname -- "$SELF")"
if [[ -d "$SELF_DIR/bin" ]]; then
    STUB_DIR="$SELF_DIR/bin"
else
    STUB_DIR=/usr/lib/anland-game-mode/bin
fi
die() { printf 'anland-game-mode: %s\n' "$*" >&2; exit 1; }
note() { printf 'anland-game-mode: %s\n' "$*" >&2; }

steam_client() {
    local state="$ANLAND_GAME_MODE_STATE" rc started quick=0
    local -a args=(-gamepadui -steamdeck -steamos3 -no-cef-sandbox -cef-ozone-platform=x11
                   -cef-force-gpu -cef-use-gl=angle -cef-use-angle=vulkan) extra=()
    export STEAMOS_STEAM_SHUTDOWN_SENTINEL="$state/steam-shutdown"
    export STEAMOS_STEAM_REBOOT_SENTINEL="$state/steam-reboot"
    export GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb SDL_VIDEODRIVER=x11
    export XDG_CURRENT_DESKTOP=gamescope XDG_SESSION_DESKTOP=gamescope
    export SRT_URLOPEN_PREFER_STEAM=1
    export STEAM_GAMESCOPE_NIS_SUPPORTED=1 STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT=1
    [[ -z ${ANLAND_STEAM_TU_DEBUG:-} ]] || export TU_DEBUG="$ANLAND_STEAM_TU_DEBUG"
    cd -- "$STEAM_ROOT"
    if [[ $ANLAND_STEAM_RT == 1 ]]; then
        # Steam's XRandR wrappers use RTLD_NEXT; make the real symbols global early.
        if [[ ${ANLAND_STEAM_XRANDR_PRELOAD:-1} == 1 ]]; then
            export LD_PRELOAD="libXrandr.so.2${LD_PRELOAD:+:$LD_PRELOAD}"
        fi
        # A -clientbeta that differs from package/beta makes the client restart with rc 42 forever.
        local beta_file="$STEAM_ROOT/package/beta" beta="${ANLAND_STEAM_BETA:-}"
        if [[ -n "$beta" ]]; then
            [[ -d "$STEAM_ROOT/package" ]] && printf '%s\n' "$beta" > "$beta_file"
        elif [[ -s "$beta_file" ]]; then
            beta="$(<"$beta_file")"
        fi
        [[ -z "$beta" ]] || args+=(-clientbeta "$beta")
    fi
    read -ra extra <<<"${ANLAND_STEAM_ARGS:-}"
    while :; do
        rm -f -- "$STEAMOS_STEAM_SHUTDOWN_SENTINEL" "$STEAMOS_STEAM_REBOOT_SENTINEL"
        started=$SECONDS
        set +e
        "$ANLAND_STEAM_BIN" "${args[@]}" "${extra[@]}"
        rc=$?
        set -e
        note "Steam exited rc=$rc"
        [[ ! -e "$state/session-request" ]] || break
        if [[ -e "$STEAMOS_STEAM_SHUTDOWN_SENTINEL" ]]; then
            note 'Shut Down from the power menu; ending game mode'
            break
        fi
        if [[ -e "$STEAMOS_STEAM_REBOOT_SENTINEL" ]]; then
            note 'Restart from the power menu; starting Steam again'
            continue
        fi
        [[ $rc == 42 ]] || break
        if (( SECONDS - started < 60 )); then
            quick=$((quick + 1))
            (( quick < 5 )) || { note 'Steam keeps asking to restart for an update; stopping'; break; }
        else
            quick=0
        fi
    done
    rm -f -- "$STEAMOS_STEAM_SHUTDOWN_SENTINEL" "$STEAMOS_STEAM_REBOOT_SENTINEL"
}

if [[ ${1:-} == --steam-client ]]; then
    shift
    steam_client "$@"
    exit 0
fi

CHECK=0
case "${1:-}" in
    --help|-h)
        printf '%s\n' 'Usage: anland-game-mode [--check] [-- COMMAND...]' \
          'Starts Steam Big Picture (-gamepadui -steamos3) on gamescope --backend anland.' \
          '--check prints the detected Steam, drivers and conflicts without starting.' \
          '-- COMMAND runs another client instead of Steam (e.g. -- vkcube).' \
          'Config: ~/.config/anland/game-mode.conf (KEY=VALUE). See the Anland guide for keys.'
        exit 0 ;;
    --check) CHECK=1; shift ;;
esac
[[ $# == 0 || ( $1 == -- && $# -gt 1 ) ]] || die 'use -- before a test/client command'
[[ $# == 0 ]] || shift
CLIENT=("$@")

declare -A ORIGIN=()
for var in ANLAND_GL_DRIVER MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER TU_DEBUG \
    VK_DRIVER_FILES VK_ICD_FILENAMES ANLAND_STEAM_BIN STEAM_ROOT PULSE_SERVER; do
    [[ -z ${!var:-} ]] || ORIGIN[$var]=environment
done

# Reads KEY=VALUE or export KEY='VALUE' lines without evaluating them; set values win.
load_env_file() {
    local file="$1" label="$2" line key value
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        if [[ "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
            value="${value//\'\\\'\'/\'}"
        elif [[ "$value" == \"*\" ]]; then
            value="${value:1:${#value}-2}"
        fi
        if [[ -z ${!key+x} ]]; then
            export "$key=$value"
            ORIGIN[$key]="$label"
        elif [[ "${!key}" == "$value" && ${ORIGIN[$key]:-} == environment ]]; then
            ORIGIN[$key]="$label"
        fi
    done < "$file"
}
load_env_file "${ANLAND_GAME_MODE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/anland/game-mode.conf}" config
load_env_file "${ANLAND_DROIDSPACES_ENV:-/run/droidspaces.env}" Droidspaces

PROBLEMS=()
problem() {
    if [[ $CHECK == 1 ]]; then PROBLEMS+=("$*"); else die "$*"; fi
}

export ANLAND_SOCKET="${ANLAND_SOCKET:-/run/display.sock}"
export ANLAND_DRM_DEVICE="${ANLAND_DRM_DEVICE:-/dev/dri/renderD128}"
export XWAYLAND_GBM_DEVICE="${XWAYLAND_GBM_DEVICE:-$ANLAND_DRM_DEVICE}"
[[ -S "$ANLAND_SOCKET" ]] || problem "daemon socket missing: $ANLAND_SOCKET (enable Anland Display in Droidspaces)"
[[ -r "$ANLAND_DRM_DEVICE" && -w "$ANLAND_DRM_DEVICE" ]] ||
    problem "render node not accessible: $ANLAND_DRM_DEVICE (enable GPU Access; usermod -aG droidspaces-gpu $(id -un))"

# Droidspaces' VirGL and PulseAudio toggles target Termux:X11, not Anland.
if [[ ${GALLIUM_DRIVER:-} == virpipe && ${ANLAND_GL_DRIVER:-inherit} == inherit ]]; then
    problem 'GALLIUM_DRIVER=virpipe (VirGL); turn VirGL off in Droidspaces or set ANLAND_GL_DRIVER=kgsl|zink'
fi
if [[ ${PULSE_SERVER:-} == unix:/tmp/.pulse-socket ]]; then
    note 'ignoring the Droidspaces PulseAudio server; Anland audio uses PipeWire'
    unset PULSE_SERVER
fi

# Mesa ships kgsl_dri.so with every freedreno build; the KGSL node proves the kernel side.
kgsl_dri_present() {
    local dir
    [[ -e /dev/kgsl-3d0 ]] || return 1
    for dir in ${LIBGL_DRIVERS_PATH:+${LIBGL_DRIVERS_PATH//:/ }} /usr/lib/dri; do
        [[ -e "$dir/kgsl_dri.so" ]] && return 0
    done
    return 1
}
apply_kgsl() {
    [[ $1 == force ]] && export MESA_LOADER_DRIVER_OVERRIDE=kgsl GALLIUM_DRIVER=kgsl
    export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
    export GALLIUM_DRIVER="${GALLIUM_DRIVER:-kgsl}"
    export FD_FORCE_KGSL="${FD_FORCE_KGSL:-1}"
    export MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE="${MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE:-1}"
    export FD_DEV_FEATURES="${FD_DEV_FEATURES:-enable_tp_ubwc_flag_hint=1}"
}
apply_zink() {
    [[ $1 == force ]] && export MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink
    export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-zink}"
    export GALLIUM_DRIVER="${GALLIUM_DRIVER:-zink}"
}
GL_DRIVER="${ANLAND_GL_DRIVER:-inherit}"
case "$GL_DRIVER" in
    kgsl|zink) "apply_$GL_DRIVER" force; GL_ORIGIN="forced by ANLAND_GL_DRIVER" ;;
    inherit)
        case "${MESA_LOADER_DRIVER_OVERRIDE:-${GALLIUM_DRIVER:-}}" in
            kgsl) apply_kgsl fill ;;
            zink) apply_zink fill ;;
            '') if kgsl_dri_present; then apply_kgsl fill; else apply_zink fill; fi
                ORIGIN[MESA_LOADER_DRIVER_OVERRIDE]=default ;;
        esac
        GL_ORIGIN="${ORIGIN[MESA_LOADER_DRIVER_OVERRIDE]:-${ORIGIN[GALLIUM_DRIVER]:-default}}" ;;
    *) die 'ANLAND_GL_DRIVER must be inherit, kgsl or zink' ;;
esac
if [[ -z ${VK_DRIVER_FILES:-} && -z ${VK_ICD_FILENAMES:-} ]]; then
    if [[ -f /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ]]; then
        export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
        ORIGIN[VK_DRIVER_FILES]=default
    else
        note 'Turnip ICD not found; leaving Vulkan driver selection to the loader'
    fi
fi

STEAM_SEARCHED=()
# Sets STEAM_ROOT to the resolved candidate when it holds the ARM64 client.
use_steam_root() {
    local root
    STEAM_SEARCHED+=("$1")
    root="$(readlink -f -- "$1" 2>/dev/null)" || return 1
    [[ -x "$root/steamrtarm64/steam" ]] || return 1
    STEAM_ROOT="$root"
}
find_steam() {
    local candidate
    ANLAND_STEAM_RT=0
    if [[ -n ${ANLAND_STEAM_BIN:-} ]]; then
        [[ -x "$ANLAND_STEAM_BIN" ]] || return 1
        if [[ -z ${STEAM_ROOT:-} ]]; then
            candidate="$(dirname -- "$(readlink -f -- "$ANLAND_STEAM_BIN")")"
            if [[ "${candidate##*/}" == steamrtarm64 ]]; then
                STEAM_ROOT="${candidate%/*}"
            else
                STEAM_ROOT="$HOME"
            fi
        fi
        [[ "$ANLAND_STEAM_BIN" -ef "$STEAM_ROOT/steamrtarm64/steam" ]] && ANLAND_STEAM_RT=1
        return 0
    fi
    if [[ -n ${STEAM_ROOT:-} ]]; then
        use_steam_root "$STEAM_ROOT" || return 1
    else
        for candidate in "$HOME/.steam/root" "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
            "$HOME/.steam/debian-installation"; do
            use_steam_root "$candidate" && break
        done
    fi
    if [[ -n ${STEAM_ROOT:-} ]]; then
        ANLAND_STEAM_BIN="$STEAM_ROOT/steamrtarm64/steam"
        ANLAND_STEAM_RT=1
        ORIGIN[ANLAND_STEAM_BIN]="${ORIGIN[STEAM_ROOT]:-detected}"
        return 0
    fi
    # A distribution or AUR wrapper manages its own data root.
    STEAM_SEARCHED+=(PATH)
    ANLAND_STEAM_BIN="$(command -v steam)" || { ANLAND_STEAM_BIN=; return 1; }
    STEAM_ROOT="$HOME"
    ORIGIN[ANLAND_STEAM_BIN]=PATH
}
if [[ ${#CLIENT[@]} == 0 ]]; then
    if find_steam; then
        export ANLAND_STEAM_BIN STEAM_ROOT ANLAND_STEAM_RT
    else
        if [[ -n ${ANLAND_STEAM_BIN:-} ]]; then
            problem "ANLAND_STEAM_BIN is not executable: $ANLAND_STEAM_BIN"
        else
            problem "Steam not found (searched: ${STEAM_SEARCHED[*]}); set ANLAND_STEAM_BIN or STEAM_ROOT"
        fi
    fi
fi

if [[ -f "$SELF_DIR/build.sh" ]]; then
    BUILD_HINT="cd $SELF_DIR && INSTALL=1 ./build.sh"
else
    BUILD_HINT='cd <anland checkout>/producers/gamescope/Arch_v5 && INSTALL=1 ./build.sh'
fi
# The Anland patch adds an "anland =>" entry to the --backend list in --help.
check_gamescope() {
    local owner output
    if [[ -n ${GAMESCOPE_BIN:-} ]]; then
        [[ -x "$GAMESCOPE_BIN" ]] || { problem "GAMESCOPE_BIN is not an executable file: $GAMESCOPE_BIN"; return; }
    elif ! GAMESCOPE_BIN="$(command -v gamescope)"; then
        GAMESCOPE_BIN=
        problem "gamescope is not installed; build and install gamescope-anland: $BUILD_HINT"
        return
    fi
    if command -v timeout >/dev/null; then
        output="$(timeout 10 "$GAMESCOPE_BIN" --help 2>&1)" || true
    else
        output="$("$GAMESCOPE_BIN" --help 2>&1)" || true
    fi
    [[ "$output" != *'anland =>'* ]] || return 0
    if [[ "$output" == *'error while loading shared libraries'* ]]; then
        problem "$GAMESCOPE_BIN cannot start: $(grep -m1 -o 'lib[^:]*: cannot open shared object file' <<<"$output" ||
            echo 'a shared library is missing'); install its dependencies or rebuild: $BUILD_HINT"
        return
    fi
    owner="$(pacman -Qqo "$GAMESCOPE_BIN" 2>/dev/null || true)"
    if [[ "$output" != *'--backend'* ]]; then
        problem "$GAMESCOPE_BIN did not answer --help; check it runs (\`$GAMESCOPE_BIN --help\`) or rebuild: $BUILD_HINT"
    elif [[ -n "$owner" && "$owner" != gamescope-anland ]]; then
        problem "$GAMESCOPE_BIN is the '$owner' package without the Anland backend; replace it with gamescope-anland: $BUILD_HINT"
    else
        problem "$GAMESCOPE_BIN has no Anland backend (--backend anland); install gamescope-anland or set GAMESCOPE_BIN: $BUILD_HINT"
    fi
}
check_gamescope
MANGOAPP=0
case "${ANLAND_MANGOAPP:-auto}" in
    auto) command -v mangoapp >/dev/null && MANGOAPP=1 ;;
    1) command -v mangoapp >/dev/null || problem 'ANLAND_MANGOAPP=1 but mangoapp is not installed'
       MANGOAPP=1 ;;
    0) ;;
    *) die 'ANLAND_MANGOAPP must be auto, 0 or 1' ;;
esac
XWAYLAND_COUNT="${ANLAND_XWAYLAND_COUNT:-2}"
[[ "$XWAYLAND_COUNT" =~ ^[1-9]$ ]] || die 'ANLAND_XWAYLAND_COUNT must be 1-9'
# An empty ANLAND_DESKTOP_CMD disables the desktop handoff.
read -ra DESKTOP_CMD <<<"${ANLAND_DESKTOP_CMD-kde-anland}"

if [[ $CHECK == 1 ]]; then
    origin() { printf '%s' "${ORIGIN[$1]:-default}"; }
    printf 'socket          %s\n' "$ANLAND_SOCKET"
    printf 'render node     %s\n' "$ANLAND_DRM_DEVICE"
    printf 'GL driver       %s (MESA_LOADER_DRIVER_OVERRIDE=%s GALLIUM_DRIVER=%s; %s)\n' \
        "$GL_DRIVER" "${MESA_LOADER_DRIVER_OVERRIDE:-}" "${GALLIUM_DRIVER:-}" "$GL_ORIGIN"
    if [[ -n ${VK_DRIVER_FILES:-} ]]; then
        printf 'Vulkan ICD      %s (%s)\n' "$VK_DRIVER_FILES" "$(origin VK_DRIVER_FILES)"
    else
        printf 'Vulkan ICD      %s (%s)\n' "${VK_ICD_FILENAMES:-loader default}" "$(origin VK_ICD_FILENAMES)"
    fi
    printf 'TU_DEBUG        %s (%s)\n' "${TU_DEBUG:-unset}" "$(origin TU_DEBUG)"
    if [[ ${#CLIENT[@]} == 0 ]]; then
        printf 'Steam           %s (%s, steamrtarm64=%s)\n' "${ANLAND_STEAM_BIN:-not found}" \
            "$(origin ANLAND_STEAM_BIN)" "${ANLAND_STEAM_RT:-0}"
        printf 'Steam root      %s\n' "${STEAM_ROOT:-}"
    else
        printf 'client          %s\n' "${CLIENT[*]}"
    fi
    printf 'gamescope       %s (mangoapp=%s, xwayland-count=%s)\n' "${GAMESCOPE_BIN:-not found}" "$MANGOAPP" "$XWAYLAND_COUNT"
    if [[ ${#DESKTOP_CMD[@]} == 0 ]]; then
        printf 'desktop handoff disabled\n'
    else
        printf 'desktop handoff %s (%s)\n' "${DESKTOP_CMD[*]}" \
            "$(command -v "${DESKTOP_CMD[0]}" >/dev/null && echo found || echo 'not installed')"
    fi
    if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
        printf 'problem         %s\n' "${PROBLEMS[@]}"
        exit 1
    fi
    printf 'ok\n'
    exit 0
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    # Fresh Droidspaces containers commonly lack a logind-created /run/user.
    XDG_RUNTIME_DIR="$HOME/.local/run/anland-$(id -u)"
    mkdir -p -m 0700 -- "$XDG_RUNTIME_DIR"
fi
[[ -d "$XDG_RUNTIME_DIR" && ! -L "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" &&
   "$(stat -c '%a' "$XDG_RUNTIME_DIR")" == 700 ]] ||
    die "runtime directory must be owned by this user with mode 0700: $XDG_RUNTIME_DIR"

# A child of dbus-run-session would inherit the lock below and then fail to take it.
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
    if [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    elif [[ -z ${ANLAND_GAME_MODE_DBUS:-} ]]; then
        command -v dbus-run-session >/dev/null || die 'no session bus and dbus-run-session is missing'
        export ANLAND_GAME_MODE_DBUS=1
        REEXEC=()
        [[ ${#CLIENT[@]} == 0 ]] || REEXEC=(-- "${CLIENT[@]}")
        exec dbus-run-session -- "$SELF" "${REEXEC[@]}"
    fi
fi

command -v flock >/dev/null || die 'flock is required'
command -v pgrep >/dev/null || die 'pgrep is required'
exec 9>"$XDG_RUNTIME_DIR/anland-producer-session.lock"
flock -n 9 || die 'another Anland session entry is active'
for name in kwin_wayland gamescope gnome-shell niri Hyprland mango weston; do
    if pgrep -u "$(id -u)" -x "$name" >/dev/null; then
        die "existing $name session detected; explicitly exit it first"
    fi
done
if [[ ${#CLIENT[@]} == 0 ]] && pgrep -u "$(id -u)" -x steam >/dev/null; then
    die 'Steam already running; explicitly exit it before game mode'
fi

export ANLAND_GAME_MODE_STATE="$XDG_RUNTIME_DIR/anland-game-mode"
mkdir -p -m 0700 -- "$ANLAND_GAME_MODE_STATE"
rm -f -- "$ANLAND_GAME_MODE_STATE/session-request"

HELPERS=()
if [[ ${ANLAND_DISABLE_AUDIO:-0} != 1 ]] && ! pgrep -u "$(id -u)" -x pipewire >/dev/null; then
    if systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user start pipewire.socket pipewire.service wireplumber.service \
            pipewire-pulse.socket 2>/dev/null || note 'could not start PipeWire user units'
    else
        for helper in pipewire wireplumber pipewire-pulse; do
            command -v "$helper" >/dev/null || { note "$helper missing; audio may not work"; continue; }
            "$helper" >/dev/null 2>&1 &
            HELPERS+=($!)
            [[ $helper != pipewire ]] || sleep 0.5
        done
    fi
fi

# Direct output is selected explicitly with --backend anland below.
# Do not leak the automatic backend selector into games and nested compositors.
unset ANLAND DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET QT_QPA_PLATFORM
GAMESCOPE_ARGS=(--backend anland --xwayland-count "$XWAYLAND_COUNT")
read -ra EXTRA_GAMESCOPE_ARGS <<<"${ANLAND_GAMESCOPE_ARGS:-}"
if [[ ${#CLIENT[@]} == 0 ]]; then
    export PATH="$STUB_DIR:$PATH"
    # SteamControlled may not publish a focus choice during initial UI startup.
    export GAMESCOPE_FALLBACK_APPID="${GAMESCOPE_FALLBACK_APPID:-769}"
    (( XWAYLAND_COUNT < 2 )) || export STEAM_MULTIPLE_XWAYLANDS=1
    if [[ $MANGOAPP == 1 ]]; then
        # Steam writes its performance overlay presets into this file.
        export MANGOHUD_CONFIGFILE="$ANLAND_GAME_MODE_STATE/mangohud.conf"
        printf 'no_display\n' > "$MANGOHUD_CONFIGFILE"
        export STEAM_USE_MANGOAPP=1 STEAM_MANGOAPP_PRESETS_SUPPORTED=1 STEAM_MANGOAPP_HORIZONTAL_SUPPORTED=1
        GAMESCOPE_ARGS+=(--mangoapp)
    fi
    GAMESCOPE_ARGS+=(-e)
    CLIENT=("$SELF" --steam-client)
fi
note "gamescope ${GAMESCOPE_ARGS[*]} ${EXTRA_GAMESCOPE_ARGS[*]} (GL=${MESA_LOADER_DRIVER_OVERRIDE:-}, socket=$ANLAND_SOCKET)"

"$GAMESCOPE_BIN" "${GAMESCOPE_ARGS[@]}" "${EXTRA_GAMESCOPE_ARGS[@]}" -- "${CLIENT[@]}" &
GAMESCOPE_PID=$!
trap 'kill -TERM "$GAMESCOPE_PID" 2>/dev/null || true' TERM INT HUP
rc=0
while :; do
    wait "$GAMESCOPE_PID" && rc=0 || rc=$?
    kill -0 "$GAMESCOPE_PID" 2>/dev/null || break
done
trap - TERM INT HUP

REQUEST="$(cat -- "$ANLAND_GAME_MODE_STATE/session-request" 2>/dev/null || true)"
rm -f -- "$ANLAND_GAME_MODE_STATE/session-request"
if [[ "$REQUEST" != desktop ]]; then
    [[ ${#HELPERS[@]} == 0 ]] || kill "${HELPERS[@]}" 2>/dev/null || true
    exit "$rc"
fi
if [[ ${#DESKTOP_CMD[@]} == 0 ]] || ! command -v "${DESKTOP_CMD[0]}" >/dev/null; then
    note "desktop command not found: ${DESKTOP_CMD[0]:-none} (set ANLAND_DESKTOP_CMD); game mode ended"
    [[ ${#HELPERS[@]} == 0 ]] || kill "${HELPERS[@]}" 2>/dev/null || true
    exit 0
fi
for _ in {1..100}; do
    pgrep -u "$(id -u)" -x gamescope >/dev/null || pgrep -u "$(id -u)" -x Xwayland >/dev/null || break
    sleep 0.1
done
# The desktop entry takes the same lock and picks its own drivers.
exec 9>&-
unset GAMESCOPE_FALLBACK_APPID STEAM_MULTIPLE_XWAYLANDS MANGOHUD_CONFIGFILE STEAM_USE_MANGOAPP \
    STEAM_MANGOAPP_PRESETS_SUPPORTED STEAM_MANGOAPP_HORIZONTAL_SUPPORTED ANLAND_GAME_MODE_DBUS
export PATH="${PATH#"$STUB_DIR":}"
note "switching to the desktop: ${DESKTOP_CMD[*]}"
exec "${DESKTOP_CMD[@]}"
