#!/bin/bash

# --- 1. Initialization & Environment Setup ---
set -uo pipefail

if [ -t 1 ]; then
    reset='\033[0m'
    bold='\033[1m'
    dim='\033[2m'
    red='\033[38;5;196m'
    green='\033[38;5;71m'
    yellow='\033[38;5;214m'
    blue='\033[38;5;75m'
    magenta='\033[38;5;176m'
    cyan='\033[38;5;79m'
    white='\033[38;5;255m'
    gray='\033[38;5;244m'
    bg_crit='\033[48;5;160;38;5;255;1m'
    bg_nuke='\033[48;5;196;38;5;255;1m'
    bg_feat='\033[48;5;214;38;5;0;1m'
else
    reset='' bold='' dim='' red='' green='' yellow='' blue=''
    magenta='' cyan='' white='' gray='' bg_crit='' bg_nuke='' bg_feat=''
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo -e "${blue}${bold}Arch Smart Update${reset}"
    echo -e "\nUsage: ${white}${0##*/}${reset} [options]\n"
    echo -e "Options:"
    echo -e "  ${cyan}(no arguments)${reset}   Run this to manually inspect pending updates in a detailed layout and choose when to install them."
    echo -e "  ${cyan}--daemon${reset}         Run this in the background to automatically monitor updates and receive a desktop notification when they are ready."
    echo -e "  ${cyan}--check${reset}          Run a single, quiet scan right now to check for updates and test your notification settings without keeping a service running."
    echo -e "  ${cyan}--enable-daemon${reset}  Enable and start the background update monitor service (systemd)."
    echo -e "  ${cyan}--disable-daemon${reset} Disable and stop the background update monitor service (systemd)."
    echo -e "  ${cyan}--silence [time]${reset} Silence background notifications (e.g. 6h, 1d) or cancel silence ('off')."
    echo -e "  ${cyan}--reconfigure${reset}    Align and update settings.conf with new default options while preserving custom settings."
    echo -e "  ${cyan}--help, -h${reset}       Display this help screen showing all available options."
    exit 0
fi

if [[ "$EUID" -eq 0 ]]; then
    echo -e "${red}Error: Please run '$(basename "$0")' without sudo.${reset}"
    exit 1
fi

exec {ASU_TTY_OUT}>&1 {ASU_TTY_ERR}>&2

DAEMON_MODE=false
ASU_SPAWNED="${ASU_SPAWNED:-false}"
if [[ "${1:-}" == "--daemon" || "${1:-}" == "--check" || "${1:-}" == "--notify-worker" || "${1:-}" == "--news-worker" ]]; then
    DAEMON_MODE=true
fi

# --- 2. Configuration & External Files ---
USER_HOME="${HOME:-}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$USER_HOME/.config}/arch-smart-update"
mkdir -p "$CONFIG_DIR"

PKG_CONF="$CONFIG_DIR/packages.conf"
SETTINGS_DEFAULT="$CONFIG_DIR/settings.default.conf"
SETTINGS_CONF="$CONFIG_DIR/settings.conf"
DAEMON_TEMPLATE="$CONFIG_DIR/daemon.template"
ICON_PATH="$CONFIG_DIR/ASU.png"

DEFAULT_CHECK_INTERVAL="2h"
DEFAULT_START_DELAY="5min"
DEFAULT_SILENCE_UPDATES="6h"
DEFAULT_NOTIFICATION_TIMEOUT=15000
DEFAULT_MAX_BACKUP_COPIES=5
DEFAULT_MAX_LOG_NUMBERS=5
DEFAULT_MIN_DISK_SPACE_MB=2048
DEFAULT_MIN_BTRFS_SPACE_MB=4608
DEFAULT_T_MIRROR_H=3
DEFAULT_T_FEAT_H=6
DEFAULT_T_CRIT_H=12
DEFAULT_T_DE_H=12
DEFAULT_T_NUKE_H=24

CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
START_DELAY="$DEFAULT_START_DELAY"
SILENCE_UPDATES="$DEFAULT_SILENCE_UPDATES"
NOTIFICATION_TIMEOUT="$DEFAULT_NOTIFICATION_TIMEOUT"
MAX_BACKUP_COPIES="$DEFAULT_MAX_BACKUP_COPIES"
MAX_LOG_NUMBERS="$DEFAULT_MAX_LOG_NUMBERS"
MIN_DISK_SPACE_MB="$DEFAULT_MIN_DISK_SPACE_MB"
MIN_BTRFS_SPACE_MB="$DEFAULT_MIN_BTRFS_SPACE_MB"
T_MIRROR_H="$DEFAULT_T_MIRROR_H"
T_FEAT_H="$DEFAULT_T_FEAT_H"
T_CRIT_H="$DEFAULT_T_CRIT_H"
T_DE_H="$DEFAULT_T_DE_H"
T_NUKE_H="$DEFAULT_T_NUKE_H"
ENABLE_BACKGROUND_CHECK=false
ENABLE_POST_CLEANUP=false
ENABLE_AUR_REBUILD_CHECK=true
GENERATE_LOGS=false
IGNORE_PATCH_TIMERS=true
PROMPT_MIRROR_REFRESH=false
AUR_HELPER_OVERRIDE=""
CUSTOM_RATE_MIRRORS_CMD=""
CUSTOM_REFLECTOR_CMD=""

ASU_TEMP_FILES=()
ASU_TEMP_DIRS=()
ASU_STATE_LOCK_FD=""
ASU_STATE_LOCK_DEPTH=0
ASU_STATE_LOCK_MODE=""

create_temp_file() {
    local var_name="${1:-}"
    local prefix="${2:-asu_temp}"
    local tmp
    tmp=$(mktemp "/tmp/${prefix}.XXXXXX") || exit 1
    ASU_TEMP_FILES+=("$tmp")
    printf -v "$var_name" "%s" "$tmp"
}

create_temp_dir() {
    local var_name="${1:-}"
    local prefix="${2:-asu_dir}"
    local tmp
    tmp=$(mktemp -d "/tmp/${prefix}.XXXXXX") || exit 1
    ASU_TEMP_DIRS+=("$tmp")
    printf -v "$var_name" "%s" "$tmp"
}

acquire_state_lock() {
    local lock_mode="${1:-x}"
    local lock_file="${CONFIG_DIR}/.state.lock"
    touch "$lock_file" 2>/dev/null || return 1
    if [[ -n "$ASU_STATE_LOCK_FD" ]]; then
        if [[ "$ASU_STATE_LOCK_MODE" == "x" ]]; then
            (( ASU_STATE_LOCK_DEPTH++ ))
            return 0
        elif [[ "$lock_mode" == "s" ]]; then
            (( ASU_STATE_LOCK_DEPTH++ ))
            return 0
        else
            if flock -w 5 -x "$ASU_STATE_LOCK_FD" 2>/dev/null; then
                ASU_STATE_LOCK_MODE="x"
                (( ASU_STATE_LOCK_DEPTH++ ))
                return 0
            fi
            release_state_lock "true"
            return 1
        fi
    fi
    local fd=""
    if exec {fd}<>"$lock_file" 2>/dev/null; then
        if [[ "$lock_mode" == "s" ]]; then
            if flock -w 5 -s "$fd" 2>/dev/null; then
                ASU_STATE_LOCK_FD="$fd"
                ASU_STATE_LOCK_MODE="s"
                ASU_STATE_LOCK_DEPTH=1
                return 0
            fi
        else
            if flock -w 5 -x "$fd" 2>/dev/null; then
                ASU_STATE_LOCK_FD="$fd"
                ASU_STATE_LOCK_MODE="x"
                ASU_STATE_LOCK_DEPTH=1
                return 0
            fi
        fi
        exec {fd}>&- 2>/dev/null || true
    fi
    return 1
}

release_state_lock() {
    local force="${1:-false}"
    if [[ "$force" == "true" ]]; then
        ASU_STATE_LOCK_DEPTH=0
    elif (( ASU_STATE_LOCK_DEPTH > 0 )); then
        (( ASU_STATE_LOCK_DEPTH-- ))
    fi
    if (( ASU_STATE_LOCK_DEPTH == 0 )) && [[ -n "$ASU_STATE_LOCK_FD" ]]; then
        if [[ "$ASU_STATE_LOCK_FD" =~ ^[0-9]+$ ]]; then
            exec {ASU_STATE_LOCK_FD}>&- 2>/dev/null || true
        fi
        ASU_STATE_LOCK_FD=""
        ASU_STATE_LOCK_MODE=""
    fi
}

parse_duration_to_seconds() {
    local raw="${1:-}"
    local var_name="${2:-}"
    local fallback="${3-}"
    local sec=-1
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" =~ ^([0-9]{1,9})$ ]]; then
        local raw_val="${BASH_REMATCH[1]}"
        local safe_num=$(( 10#$raw_val ))
        sec=$(( safe_num * 3600 ))
    elif [[ "$raw" =~ ^([0-9]{1,9})[[:space:]]*([a-zA-Z]+)$ ]]; then
        local raw_val="${BASH_REMATCH[1]}"
        local safe_num=$(( 10#$raw_val ))
        local unit="${BASH_REMATCH[2],,}"
        case "$unit" in
            s|sec|secs|second|seconds) sec="$safe_num" ;;
            m|min|mins|minute|minutes) sec=$(( safe_num * 60 )) ;;
            h|hr|hrs|hour|hours) sec=$(( safe_num * 3600 )) ;;
            d|day|days) sec=$(( safe_num * 86400 )) ;;
            w|wk|wks|week|weeks) sec=$(( safe_num * 604800 )) ;;
            *) sec=-1 ;;
        esac
    fi
    if (( sec < 0 )) && [[ -n "$fallback" && "$raw" != "$fallback" ]]; then
        parse_duration_to_seconds "$fallback" "$var_name" ""
        return
    fi
    if (( sec < 0 )); then
        sec=0
    fi
    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" "%s" "$sec"
    else
        echo "$sec"
    fi
}

parse_timeout_to_ms() {
    local raw="${1:-}"
    local var_name="${2:-}"
    local fallback="${3-$DEFAULT_NOTIFICATION_TIMEOUT}"
    local ms=-1
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ "$raw" =~ ^([0-9]{1,9})$ ]]; then
        local raw_val="${BASH_REMATCH[1]}"
        ms=$(( 10#$raw_val ))
    elif [[ "$raw" =~ ^([0-9]{1,9})[[:space:]]*([a-zA-Z]+)$ ]]; then
        local raw_val="${BASH_REMATCH[1]}"
        local safe_num=$(( 10#$raw_val ))
        local unit="${BASH_REMATCH[2],,}"
        case "$unit" in
            ms|msec|msecs|millisecond|milliseconds) ms="$safe_num" ;;
            s|sec|secs|second|seconds) ms=$(( safe_num * 1000 )) ;;
            m|min|mins|minute|minutes) ms=$(( safe_num * 60000 )) ;;
            h|hr|hrs|hour|hours) ms=$(( safe_num * 3600000 )) ;;
            *) ms=-1 ;;
        esac
    fi
    if (( ms < 0 )) && [[ -n "$fallback" && "$raw" != "$fallback" ]]; then
        parse_timeout_to_ms "$fallback" "$var_name" ""
        return
    fi
    if (( ms < 0 )); then
        ms="$DEFAULT_NOTIFICATION_TIMEOUT"
    fi
    if [[ -n "$var_name" ]]; then
        printf -v "$var_name" "%s" "$ms"
    else
        echo "$ms"
    fi
}

test_socket_alive() {
    local sock_target="${1:-}"
    [[ -S "$sock_target" ]] || return 1
    python3 - "$sock_target" <<'PYEOF' 2>/dev/null
import socket, sys
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(0.3)
        s.connect(sys.argv[1])
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
}

detect_display_session() {
    local sess_type="${XDG_SESSION_TYPE:-}"
    local desktop_env="${XDG_CURRENT_DESKTOP:-}"
    local run_dir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
    local effective_wayland="${WAYLAND_DISPLAY:-}"
    local effective_x11="${DISPLAY:-}"

    if [[ -n "$effective_wayland" ]]; then
        local w_path="$effective_wayland"
        [[ "$w_path" != /* ]] && w_path="$run_dir/$effective_wayland"
        if ! test_socket_alive "$w_path"; then
            effective_wayland=""
        fi
    fi

    if [[ -z "$effective_wayland" && -d "$run_dir" ]]; then
        while IFS= read -r sock; do
            [[ -z "$sock" ]] && continue
            if [[ -S "$sock" && -O "$sock" ]] && test_socket_alive "$sock"; then
                effective_wayland="$(basename "$sock")"
                break
            fi
        done < <(find "$run_dir" -maxdepth 1 -name "wayland-[0-9]*" -type s 2>/dev/null | sort -V -r)
    fi

    if [[ -n "$effective_x11" ]]; then
        local x11_part="${effective_x11#*:}"
        local x11_num="${x11_part%%.*}"
        local x11_sock="/tmp/.X11-unix/X${x11_num}"
        if [[ ! -S "$x11_sock" ]] || ! test_socket_alive "$x11_sock"; then
            effective_x11=""
        fi
    fi

    if [[ -z "$effective_x11" && -d "/tmp/.X11-unix" ]]; then
        while IFS= read -r sock; do
            [[ -z "$sock" ]] && continue
            if [[ -S "$sock" && ( -O "$sock" || -w "$sock" ) ]] && test_socket_alive "$sock"; then
                effective_x11=":${sock#/tmp/.X11-unix/X}"
                break
            fi
        done < <(find /tmp/.X11-unix -maxdepth 1 -name "X[0-9]*" -type s 2>/dev/null | sort -V -r)
    fi

    if [[ -n "$effective_wayland" ]]; then
        export XDG_SESSION_TYPE="wayland"
    elif [[ -n "$effective_x11" ]]; then
        export XDG_SESSION_TYPE="x11"
    elif [[ -n "$sess_type" && "$sess_type" != "unspecified" && "$sess_type" != "tty" ]]; then
        export XDG_SESSION_TYPE="$sess_type"
    fi

    export DETECTED_WAYLAND="$effective_wayland"
    export DETECTED_DISPLAY="$effective_x11"
}

launch_detached() {
    detect_display_session

    local run_dir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
    local dbus_addr="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$run_dir/bus}"

    local env_wrapper=(env)
    if [[ -n "${DETECTED_WAYLAND:-}" ]]; then
        env_wrapper+=("WAYLAND_DISPLAY=$DETECTED_WAYLAND")
    else
        env_wrapper+=("-u" "WAYLAND_DISPLAY")
    fi
    if [[ -n "${DETECTED_DISPLAY:-}" ]]; then
        env_wrapper+=("DISPLAY=$DETECTED_DISPLAY")
    else
        env_wrapper+=("-u" "DISPLAY")
    fi
    [[ -n "${run_dir:-}" ]] && env_wrapper+=("XDG_RUNTIME_DIR=$run_dir")
    [[ -n "${dbus_addr:-}" ]] && env_wrapper+=("DBUS_SESSION_BUS_ADDRESS=$dbus_addr")
    [[ -n "${PATH:-}" ]] && env_wrapper+=("PATH=$PATH")
    [[ -n "${XAUTHORITY:-}" ]] && env_wrapper+=("XAUTHORITY=$XAUTHORITY")
    [[ -n "${XDG_DATA_DIRS:-}" ]] && env_wrapper+=("XDG_DATA_DIRS=$XDG_DATA_DIRS")
    [[ -n "${XDG_CONFIG_DIRS:-}" ]] && env_wrapper+=("XDG_CONFIG_DIRS=$XDG_CONFIG_DIRS")
    [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] && env_wrapper+=("XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP")
    [[ -n "${XDG_SESSION_TYPE:-}" ]] && env_wrapper+=("XDG_SESSION_TYPE=$XDG_SESSION_TYPE")
    [[ -n "${ASU_SPAWNED:-}" ]] && env_wrapper+=("ASU_SPAWNED=$ASU_SPAWNED")

    local runner=()
    [[ "${1:-}" == *.sh ]] && runner=(/bin/bash)

    if [[ -d /run/systemd/system ]] && command -v systemd-run >/dev/null 2>&1; then
        systemd-run --user --quiet --collect -- "${env_wrapper[@]}" ${runner[@]+"${runner[@]}"} "$@" >/dev/null 2>&1
    elif command -v setsid >/dev/null 2>&1; then
        "${env_wrapper[@]}" setsid -f ${runner[@]+"${runner[@]}"} "$@" </dev/null >/dev/null 2>&1
    else
        "${env_wrapper[@]}" nohup ${runner[@]+"${runner[@]}"} "$@" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
}

handle_news_worker() {
    local notif_icon="${2:-dialog-warning}"
    local diff_hours="${3:-0}"
    local news_ts="${4:-0}"
    local news_cache="$CONFIG_DIR/news.cache"

    local notif_daemon desktop_env supports_actions=false use_single_action=false action="" action_clean=""
    notif_daemon=$(dbus-send --session --print-reply --dest=org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications.GetServerInformation 2>/dev/null | awk -F'"' '/string/ {print $2; exit}')
    notif_daemon=${notif_daemon,,}
    desktop_env="${XDG_CURRENT_DESKTOP:-}"
    desktop_env="${desktop_env,,}"

    if notify-send --help 2>&1 | grep -q -- "--action"; then
        supports_actions=true
    fi

    if [[ "$notif_daemon" =~ (mako|dunst|lxqt|xfce|fnott|wired|swaync) ]] || [[ "$desktop_env" =~ (sway|i3|hyprland|niri|lxqt|xfce|wlroots) ]]; then
        use_single_action=true
    fi

    if [[ "$supports_actions" == "true" ]]; then
        if [[ "$use_single_action" == "true" ]]; then
            action=$(notify-send -t 0 -a "Arch Smart Update" -u critical -i "$notif_icon" --action="default=Read News" --action="silence=Silence" "Attention: Arch News detected!" "Published $diff_hours h. ago.\nCheck archlinux.org before updating." 2>/dev/null) || action=""
        else
            action=$(notify-send -t 0 -a "Arch Smart Update" -u critical -i "$notif_icon" --action="default=Read News" --action="read=Read News" --action="silence=Silence" "Attention: Arch News detected!" "Published $diff_hours h. ago.\nCheck archlinux.org before updating." 2>/dev/null) || action=""
        fi
    else
        notify-send -t 0 -a "Arch Smart Update" -u critical -i "$notif_icon" "Attention: Arch News detected!" "Published $diff_hours h. ago.\nCheck archlinux.org before updating." >/dev/null 2>&1 || true
    fi

    action_clean=$(echo "$action" | tr -d ' \n\r')

    if [[ "$action_clean" == "silence" || ( "$use_single_action" == "true" && "$action_clean" == "1" ) || ( "$use_single_action" == "false" && "$action_clean" == "2" ) ]]; then
        echo "${news_ts}|silenced" > "$news_cache"
    elif [[ "$action_clean" == "read" || "$action_clean" == "default" || "$action_clean" == "0" || ( "$use_single_action" == "false" && "$action_clean" == "1" ) ]]; then
        echo "${news_ts}|silenced" > "$news_cache"
        open_url() {
            local url="$1"
            local default_browser=""
            if command -v xdg-settings >/dev/null 2>&1; then
                default_browser=$(xdg-settings get default-web-browser 2>/dev/null)
                default_browser="${default_browser%.desktop}"
            fi
            if [[ -n "$default_browser" ]] && command -v "$default_browser" >/dev/null 2>&1; then
                exec "$default_browser" "$url"
            fi
            if command -v xdg-open >/dev/null 2>&1; then
                exec xdg-open "$url"
            fi
            for browser in "firefox" "chromium" "google-chrome-stable" "librewolf" "brave" "waterfox" "opera" "epiphany" "falkon"; do
                if command -v "$browser" >/dev/null 2>&1; then
                    exec "$browser" "$url"
                fi
            done
        }
        open_url "https://archlinux.org/"
    fi
}

handle_notify_worker() {
    local notif_icon="${2:-software-update-available}"
    local pkg_count="${3:-0}"
    local aur_count="${4:-0}"
    local notif_timeout="${5:-$DEFAULT_NOTIFICATION_TIMEOUT}"
    local target_script
    target_script="$(realpath "$(command -v "${BASH_SOURCE:-$0}" 2>/dev/null || echo "${BASH_SOURCE:-$0}")")"

    if [[ -f "$SETTINGS_CONF" ]]; then
        if validate_user_conf "$SETTINGS_CONF" "settings.conf" "false"; then
            load_daemon_params "$SETTINGS_CONF"
        fi
    fi

    local silence_cfg="${SILENCE_UPDATES:-$DEFAULT_SILENCE_UPDATES}"
    local raw_timeout="${NOTIFICATION_TIMEOUT:-${5:-$DEFAULT_NOTIFICATION_TIMEOUT}}"
    parse_timeout_to_ms "$raw_timeout" notif_timeout "$DEFAULT_NOTIFICATION_TIMEOUT"

    local notif_daemon desktop_env supports_actions=false use_single_action=false action="" action_clean=""
    notif_daemon=$(dbus-send --session --print-reply --dest=org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications.GetServerInformation 2>/dev/null | awk -F'"' '/string/ {print $2; exit}')
    notif_daemon=${notif_daemon,,}
    desktop_env="${XDG_CURRENT_DESKTOP:-}"
    desktop_env="${desktop_env,,}"

    if notify-send --help 2>&1 | grep -q -- "--action"; then
        supports_actions=true
    fi

    if [[ "$notif_daemon" =~ (mako|dunst|lxqt|xfce|fnott|wired|swaync) ]] || [[ "$desktop_env" =~ (sway|i3|hyprland|niri|lxqt|xfce|wlroots) ]]; then
        use_single_action=true
    fi

    if [[ "$supports_actions" == "true" ]]; then
        if [[ "$use_single_action" == "true" ]]; then
            action=$(notify-send -t "$notif_timeout" -a "Arch Smart Update" -u normal -i "$notif_icon" \
                --action="default=Update Now" \
                --action="silence=Silence" \
                "Safe Updates Available" "Found $pkg_count updates ($aur_count AUR).\nReady to install." 2>/dev/null) || action=""
        else
            action=$(notify-send -t "$notif_timeout" -a "Arch Smart Update" -u normal -i "$notif_icon" \
                --action="default=Update Now" \
                --action="update=Update Now" \
                --action="silence=Silence" \
                "Safe Updates Available" "Found $pkg_count updates ($aur_count AUR).\nReady to install." 2>/dev/null) || action=""
        fi
    else
        notify-send -t "$notif_timeout" -a "Arch Smart Update" -u normal -i "$notif_icon" "Safe Updates Available" "Found $pkg_count updates ($aur_count AUR).\nReady to install." >/dev/null 2>&1 || true
    fi

    action_clean=$(echo "$action" | tr -d ' \n\r')

    if [[ "$action_clean" == "silence" || ( "$use_single_action" == "true" && "$action_clean" == "1" ) || ( "$use_single_action" == "false" && "$action_clean" == "2" ) ]]; then
        local silence_sec=0
        parse_duration_to_seconds "$silence_cfg" silence_sec "$DEFAULT_SILENCE_UPDATES"
        local silence_ts=$(( $(date +%s) + silence_sec ))
        if acquire_state_lock "x"; then
            echo "${silence_ts}|silence" > "${CONFIG_DIR}/next_check.conf"
            release_state_lock
        fi
        if command -v systemctl >/dev/null 2>&1; then
            sync_daemon_state "true" >/dev/null 2>&1 || true
        fi
        exit 0
    elif [[ "$action_clean" == "update" || "$action_clean" == "default" || "$action_clean" == "0" || ( "$use_single_action" == "false" && "$action_clean" == "1" ) ]]; then
        sleep 0.15

        spawn_term() {
            export ASU_SPAWNED=true
            exec "$@"
        }

        if [[ -n "${TERMINAL:-}" ]]; then
            read -ra term_custom <<< "$TERMINAL"
            if command -v "${term_custom[0]}" >/dev/null 2>&1; then
                if (( ${#term_custom[@]} > 1 )); then
                    spawn_term "${term_custom[@]}" "$target_script"
                elif [[ "${term_custom[0]}" =~ ^(kitty|gnome-terminal)$ ]]; then
                    spawn_term "${term_custom[0]}" -- "$target_script"
                elif [[ "${term_custom[0]}" == "foot" ]]; then
                    spawn_term "${term_custom[0]}" "$target_script"
                elif [[ "${term_custom[0]}" == "wezterm" ]]; then
                    spawn_term "${term_custom[0]}" start -- "$target_script"
                else
                    spawn_term "${term_custom[0]}" -e "$target_script"
                fi
            fi
        fi

        if command -v xdg-terminal-exec >/dev/null 2>&1; then
            spawn_term xdg-terminal-exec "$target_script"
        fi

        local term_candidates=(
            "ghostty -e"
            "alacritty -e"
            "kitty --"
            "konsole -e"
            "gnome-terminal --"
            "xfce4-terminal --disable-server -x"
            "terminator -x"
            "tilix -e"
            "foot"
            "wezterm start --"
            "qterminal -e"
            "lxterminal -e"
            "mate-terminal -x"
            "xterm -e"
        )

        for term_entry in "${term_candidates[@]}"; do
            read -ra term_arr <<< "$term_entry"
            local bin="${term_arr[0]}"
            if command -v "$bin" >/dev/null 2>&1; then
                spawn_term "${term_arr[@]}" "$target_script"
            fi
        done
    fi
}

if ! $DAEMON_MODE && [ -d "$CONFIG_DIR" ]; then
    dir_owner=$(stat -Lc '%u' "$CONFIG_DIR" 2>/dev/null || echo "")
    if [[ "$dir_owner" == "0" ]] || find "$CONFIG_DIR" -user root -print -quit 2>/dev/null | grep -q .; then
        echo -e "${yellow}Detected files owned by root in config directory.${reset}"
        echo -ne "${white}Fix ownership of config directory using sudo chown? [y/N]: ${reset}"
        read -r chown_ans </dev/tty 2>/dev/null || read -r chown_ans 2>/dev/null || chown_ans="n"
        if [[ "$chown_ans" =~ ^[Yy]$ ]]; then
            if ! sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIR"; then
                echo -e "${red}Error: Failed to fix ownership of config directory. Exiting.${reset}"
                exit 1
            fi
        else
            echo -e "${red}Error: Root-owned files exist in config directory. Exiting.${reset}"
            exit 1
        fi
    fi
fi

OUTPUT_FILE=""
SYNC_LOG=""
REFL_LOG=""
CHECK_DB=""
SUDO_KEEP_ALIVE_PID=""
CURRENT_TMP_LOG=""
CURRENT_TASK_CAPTURE=""

cleanup() {
    release_state_lock "true"

    if [[ -n "${SUDO_KEEP_ALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEP_ALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEP_ALIVE_PID" 2>/dev/null
    fi

    local files_to_remove=()
    for f in "${ASU_TEMP_FILES[@]+"${ASU_TEMP_FILES[@]}"}"; do
        [[ -f "$f" ]] && files_to_remove+=("$f")
    done
    [[ -n "${SETTINGS_CONF:-}" && -f "${SETTINGS_CONF}.tmp" ]] && files_to_remove+=("${SETTINGS_CONF}.tmp")
    [[ -n "${CURRENT_TMP_LOG:-}" && -f "$CURRENT_TMP_LOG" ]] && files_to_remove+=("$CURRENT_TMP_LOG")
    [[ -n "${CURRENT_TASK_CAPTURE:-}" && -f "$CURRENT_TASK_CAPTURE" ]] && files_to_remove+=("$CURRENT_TASK_CAPTURE")

    if [[ ${#files_to_remove[@]} -gt 0 ]]; then
        rm -f "${files_to_remove[@]}"
    fi

    for d in "${ASU_TEMP_DIRS[@]+"${ASU_TEMP_DIRS[@]}"}"; do
        if [[ -d "$d" && "$d" == /tmp/* && "$d" != "/tmp/" ]]; then
            rm -rf -- "$d" 2>/dev/null
            if [[ -d "$d" ]]; then
                sudo -n rm -rf -- "$d" 2>/dev/null
            fi
        fi
    done
}

trap cleanup EXIT INT TERM

log_step() {
    echo -e "${dim}[$(date +%T)] ${1:-}${reset}"
}

for cmd in python3 tar awk stat curl zstd sha256sum grep sed vercmp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${red}Error: Required command '$cmd' is not installed.${reset}"
        exit 1
    fi
done

prompt_user() {
    local msg="${1:-}" options="${2:-}" var_name="${3:-}"
    local user_input=""
    if ! $DAEMON_MODE; then
        echo -ne "${white}${msg} [${options}]: ${reset}"
        read -r user_input </dev/tty 2>/dev/null || read -r user_input 2>/dev/null || user_input=""
    fi
    [[ -n "$user_input" ]] && declare -g "$var_name=$user_input"
}

bypass_cdn_cache() {
    local url="${1:-}"
    local ts="${EPOCHSECONDS:-}"
    if [[ -z "$ts" ]]; then
        ts=$(date +%s 2>/dev/null || echo "1")
    fi
    if [[ "$url" == *"raw.githubusercontent.com"* ]]; then
        local url_no_anchor="${url%%[#]*}"
        local anchor=""
        if [[ "$url" == *"#"* ]]; then
            anchor="#${url#*#}"
        fi
        if [[ "$url_no_anchor" == *"?"* ]]; then
            printf '%s\n' "${url_no_anchor}&t=${ts}${anchor}"
        else
            printf '%s\n' "${url_no_anchor}?t=${ts}${anchor}"
        fi
    else
        printf '%s\n' "$url"
    fi
}

update_from_github() {
    local file_path="${1:-}"
    local url="${2:-}"
    local expected_string="${3:-}"
    local filename
    filename=$(basename "$file_path")
    local tmp_file
    create_temp_file tmp_file "${filename}"
    local conn_timeout=2
    local max_time=4
    if [[ ! -f "$file_path" ]]; then
        conn_timeout=5
        max_time=10
    fi

    local target_url
    target_url=$(bypass_cdn_cache "$url")

    if curl -sLfo "$tmp_file" --connect-timeout "$conn_timeout" --max-time "$max_time" "$target_url"; then
        if [[ -n "$expected_string" ]] && ! grep -q "$expected_string" "$tmp_file"; then
            rm -f "$tmp_file"
            [[ ! -f "$file_path" ]] && echo -e "${red}Failed to download $filename (Invalid format / Captive Portal)${reset}"
            return 1
        fi

        local manifest_file="$CONFIG_DIR/manifest.sha256"
        if [[ -f "$manifest_file" ]]; then
            local remote_name
            local url_clean="${url%%[?]*}"
            url_clean="${url_clean%%[#]*}"
            remote_name=$(basename "$url_clean")
            local expected_hash
            expected_hash=$(awk -v fname="$remote_name" '{sub(/\r$/, ""); sub(/^\*/, "", $2); sub(/^.*\//, "", $2); if ($2 == fname) print $1}' "$manifest_file" 2>/dev/null || true)
            if [[ -n "$expected_hash" ]]; then
                local actual_hash
                actual_hash=$(sha256sum "$tmp_file" | cut -d' ' -f1)
                if [[ "$actual_hash" != "$expected_hash" ]]; then
                    rm -f "$tmp_file"
                    echo -e "${red}Security Alert: Integrity check failed for $filename. Hash mismatch!${reset}"
                    return 1
                fi
            else
                rm -f "$tmp_file"
                echo -e "${red}Security Alert: File $filename is missing from the integrity manifest. Rejected!${reset}"
                return 1
            fi
        fi

        if [[ "$filename" == "settings.default.conf" ]]; then
            if awk '/^[[:space:]]*CUSTOM_CMDS[[:space:]]*(\+)?[[:space:]]*=[[:space:]]*\(/ { in_block=1; sub(/^.*=[[:space:]]*\(/, ""); if ($0 ~ /\)/) { sub(/\).*$/, ""); sub(/#.*$/, ""); if ($0 ~ /[^[:space:]]/) { print "DANGER"; exit; } in_block=0; } else { sub(/#.*$/, ""); if ($0 ~ /[^[:space:]]/) { print "DANGER"; exit; } } next; } in_block && /^[[:space:]]*\)/ { in_block=0; next; } in_block && /^[[:space:]]*[^#[:space:]]/ { print "DANGER"; exit; }' "$tmp_file" | grep -q "DANGER"; then
                rm -f "$tmp_file"
                [[ ! -f "$file_path" ]] && echo -e "${red}Security Alert: Active custom commands detected in default settings. Download rejected!${reset}"
                return 1
            fi
        fi

        if [[ ! -f "$file_path" ]]; then
            mv "$tmp_file" "$file_path"
            echo -e "${dim}Downloaded $filename from GitHub...${reset}"
        elif ! cmp -s "$file_path" "$tmp_file"; then
            mv "$tmp_file" "$file_path"
            echo -e "${green}Updated $filename from GitHub!${reset}"
        else
            rm -f "$tmp_file"
        fi
    else
        [[ ! -f "$file_path" ]] && echo -e "${red}Failed to download $filename (No internet connection?)${reset}"
        rm -f "$tmp_file"
    fi
}

parse_bash_array() {
    local file="${1:-}"
    local arr_name="${2:-}"
    [[ -z "$file" || ! -f "$file" ]] && return 0
    awk -v var="$arr_name" '
        BEGIN { in_arr=0 }
        { sub(/^[[:space:]]*#.*/, "") }
        $0 ~ "^[[:space:]]*"var"(\\+)?=\\s*\\(" { in_arr=1; sub(/^.*\(/, "") }
        in_arr {
            tmp = $0
            while (match(tmp, /"[^"]*"|\047[^\047]*\047/)) {
                len = RLENGTH
                replacement = ""
                for (i=1; i<=len; i++) replacement = replacement " "
                tmp = substr(tmp, 1, RSTART-1) replacement substr(tmp, RSTART+RLENGTH)
            }
            idx = index(tmp, "#")
            if (idx > 0) {
                tmp = substr(tmp, 1, idx - 1)
                $0 = substr($0, 1, idx - 1)
            }
            if (match(tmp, /\)/)) {
                $0 = substr($0, 1, RSTART-1)
                in_arr=0
            }
            while (match($0, /"[^"]*"|\047[^\047]*\047|[^ \t\n\r"\047()]+/)) {
                val = substr($0, RSTART, RLENGTH)
                if (val ~ /^#/) break
                gsub(/^["\047]|["\047]$/, "", val)
                if (val != "") print val
                $0 = substr($0, RSTART+RLENGTH)
            }
        }
    ' "$file"
}

validate_user_conf() {
    local file="${1:-}"
    local label="${2:-}"
    local check_custom="${3:-true}"

    [[ ! -f "$file" ]] && return 0

    local owner=""
    owner=$(stat -Lc '%u' "$file" 2>/dev/null || echo "")
    local real_user
    real_user="$(id -u)"
    if [[ -z "$owner" || ( "$owner" != "$real_user" && "$owner" != "0" ) ]]; then
        echo -e "${bg_nuke}SECURITY ${reset} ${red}$label is owned by '${owner:-UNKNOWN}', expected '$real_user' or 'root'. Refusing to load.${reset}"
        return 1
    fi

    local perms=""
    perms=$(stat -Lc '%a' "$file" 2>/dev/null || echo "")
    if [[ -z "$perms" ]]; then
        echo -e "${bg_nuke}SECURITY ${reset} ${red}Could not determine permissions for $label. Refusing to load.${reset}"
        return 1
    fi
    if (( 8#${perms} & 8#022 )); then
        echo -e "${bg_nuke}SECURITY ${reset} ${red}$label is group/world-writable (${perms}). Refusing to load.${reset}"
        echo -e "${yellow}Fix with: chmod 600 \"$file\"${reset}"
        return 1
    fi

    if [[ "$label" == "settings.conf" && "$check_custom" == "true" ]]; then
        if awk '/^[[:space:]]*CUSTOM_CMDS[[:space:]]*(\+)?[[:space:]]*=[[:space:]]*\(/ { in_block=1; sub(/^.*=[[:space:]]*\(/, ""); if ($0 ~ /\)/) { sub(/\).*$/, ""); sub(/#.*$/, ""); if ($0 ~ /[^[:space:]]/) { print "DANGER"; exit; } in_block=0; } else { sub(/#.*$/, ""); if ($0 ~ /[^[:space:]]/) { print "DANGER"; exit; } } next; } in_block && /^[[:space:]]*\)/ { in_block=0; next; } in_block && /^[[:space:]]*[^#[:space:]]/ { print "DANGER"; exit; }' "$file" | grep -q "DANGER"; then
            local conf_hash
            conf_hash=$(sha256sum "$file" | cut -d' ' -f1)
            local trust_file="$CONFIG_DIR/.trusted_hash"
            local trusted=false
            if [[ -f "$trust_file" ]] && [[ "$(cat "$trust_file" 2>/dev/null)" == "$conf_hash" ]]; then
                trusted=true
            fi
            if [[ "$trusted" == "false" ]]; then
                if ! $DAEMON_MODE; then
                    local trust_ans=""
                    local cmd=""
                    echo -e "${yellow}Warning: Active custom commands detected in settings.conf:${reset}"
                    while IFS= read -r cmd; do
                        [[ -n "$cmd" ]] && printf "  %b• %b%s%b\n" "${cyan}" "${white}" "$cmd" "${reset}"
                    done < <(parse_bash_array "$file" "CUSTOM_CMDS")
                    echo -ne "${white}Do you trust and want to execute these custom commands? [y/N]: ${reset}"
                    read -r trust_ans </dev/tty 2>/dev/null || read -r trust_ans 2>/dev/null || trust_ans="n"
                    if [[ "$trust_ans" =~ ^[Yy]$ ]]; then
                        sha256sum "$file" | cut -d' ' -f1 > "$trust_file"
                        chmod 600 "$trust_file" 2>/dev/null || true
                    else
                        echo -e "${red}Error: Custom commands untrusted. Refusing to load settings.conf.${reset}"
                        echo -ne "${white}Would you like to remove these custom commands? [Y/n]: ${reset}"
                        local remove_ans=""
                        read -r remove_ans </dev/tty 2>/dev/null || read -r remove_ans 2>/dev/null || remove_ans="n"
                        if [[ "$remove_ans" =~ ^[Yy]$ || -z "$remove_ans" ]]; then
                            local default_param=""
                            if [[ -n "${SETTINGS_DEFAULT:-}" && -f "$SETTINGS_DEFAULT" ]]; then
                                local def_owner def_perms
                                def_owner=$(stat -Lc '%u' "$SETTINGS_DEFAULT" 2>/dev/null || echo "")
                                def_perms=$(stat -Lc '%a' "$SETTINGS_DEFAULT" 2>/dev/null || echo "")
                                if [[ "$def_owner" == "$(id -u)" || "$def_owner" == "0" ]] && [[ "$def_perms" =~ ^[0-7]+$ ]] && ! (( 8#${def_perms} & 8#022 )); then
                                    default_param="$SETTINGS_DEFAULT"
                                fi
                            fi
                            if python3 - "$file" "$default_param" <<'EOF'
import sys, re, os

def find_blocks(content):
    idx = 0
    n = len(content)
    blocks = []
    while idx < n:
        if idx == 0 or content[idx-1] == '\n':
            match = re.match(r'([ \t]*)CUSTOM_CMDS\s*(?:\+)?=\s*\(', content[idx:])
        else:
            match = None
        if match:
            start_idx = idx
            indent = match.group(1)
            idx += match.end()
            in_dquote = False
            in_squote = False
            escaped = False
            comment = False
            paren_depth = 1
            while idx < n:
                char = content[idx]
                if escaped:
                    escaped = False
                    idx += 1
                    continue
                if comment:
                    if char == '\n':
                        comment = False
                    idx += 1
                    continue
                if in_dquote:
                    if char == '\\':
                        escaped = True
                    elif char == '"':
                        in_dquote = False
                    idx += 1
                    continue
                if in_squote:
                    if char == "'":
                        in_squote = False
                    idx += 1
                    continue
                if char == '\\':
                    escaped = True
                elif char == chr(35):
                    comment = True
                elif char == '"':
                    in_dquote = True
                elif char == "'":
                    in_squote = True
                elif char == '(':
                    paren_depth += 1
                elif char == ')':
                    paren_depth -= 1
                    if paren_depth == 0:
                        idx += 1
                        break
                idx += 1
            if paren_depth == 0:
                blocks.append((start_idx, idx, indent))
            else:
                raise ValueError("Mismatched parenthesis")
        else:
            idx += 1
    return blocks

def is_block_safe(block):
    if not block:
        return True
    inner = re.sub(r'^CUSTOM_CMDS\s*(?:\+)?=\s*\(', '', block.strip())
    if inner.endswith(')'):
        inner = inner[:-1]
    for line in inner.splitlines():
        line_stripped = line.strip()
        if not line_stripped or line_stripped.startswith(chr(35)):
            continue
        return False
    return True

try:
    target_file = os.path.realpath(sys.argv[1])
    default_file = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    with open(target_file, "r", encoding="utf-8", errors="surrogateescape") as f:
        target_content = f.read()
    default_block = None
    if default_file and os.path.exists(default_file):
        try:
            with open(default_file, "r", encoding="utf-8", errors="surrogateescape") as f:
                def_content = f.read()
            def_blocks = find_blocks(def_content)
            if def_blocks:
                b_start, b_end, _ = def_blocks[0]
                extracted = def_content[b_start:b_end]
                if is_block_safe(extracted):
                    default_block = extracted
        except Exception:
            pass
    if not default_block:
        default_block = "CUSTOM_CMDS=()"

    t_blocks = find_blocks(target_content)
    if not t_blocks:
        sanitized = target_content
    else:
        out = []
        last_end = 0
        replaced = False
        for start, end, indent in t_blocks:
            out.append(target_content[last_end:start])
            if not replaced:
                out.append(f"{indent}{default_block.lstrip()}")
                replaced = True
            else:
                out.append(f"{indent}CUSTOM_CMDS=()")
            last_end = end
        out.append(target_content[last_end:])
        sanitized = "".join(out)

    tmp_file = target_file + ".tmp"
    fd = os.open(tmp_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with open(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(sanitized)
    os.replace(tmp_file, target_file)
    sys.exit(0)
except Exception:
    sys.exit(1)
EOF
                            then
                                chmod 600 "$file"
                                echo -e "${green}Custom commands removed. settings.conf loaded successfully.${reset}"
                                return 0
                            else
                                echo -e "${red}Error: Failed to sanitize custom commands from settings.conf.${reset}"
                                return 1
                            fi
                        else
                            return 1
                        fi
                    fi
                else
                    echo -e "${red}Error: Unverified custom commands detected in settings.conf in background mode.${reset}"
                    return 1
                fi
            fi
        fi
    fi

    return 0
}

NUCLEAR_PKGS=("glibc" "linux" "systemd" "pacman" "nvidia" "mkinitcpio")
CRITICAL_PKGS=("base" "base-devel" "mesa" "wayland" "xorg-server" "dbus")
FEATURE_PKGS=("pipewire" "plasma-desktop" "gnome-shell" "hyprland" "networkmanager")
CUSTOM_CMDS=()
SETTINGS_VALIDATION_FAILED=false

sync_daemon_state() {
    local force_restart="${1:-false}"
    if [[ "${SETTINGS_VALIDATION_FAILED:-false}" == "true" ]]; then
        return 0
    fi

    local QUIET=false
    [[ "$DAEMON_MODE" == true ]] && QUIET=true

    local SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$USER_HOME/.config}/systemd/user"
    local bg_check="${ENABLE_BACKGROUND_CHECK:-false}"

    if [[ "${bg_check,,}" == "true" ]]; then
        if ! command -v fakeroot >/dev/null 2>&1; then
            $QUIET || echo -e "${yellow}Background check requires 'fakeroot' (install base-devel). Disabling daemon.${reset}"
            ENABLE_BACKGROUND_CHECK="false"
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null || systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null || [[ -f "$SYSTEMD_USER_DIR/arch-smart-update.timer" ]]; then
                    systemctl --user disable --now arch-smart-update.timer >/dev/null 2>&1
                    systemctl --user stop arch-smart-update.service >/dev/null 2>&1 || true
                    rm -f "$SYSTEMD_USER_DIR/arch-smart-update.service" "$SYSTEMD_USER_DIR/arch-smart-update.timer"
                    systemctl --user daemon-reload >/dev/null 2>&1
                fi
            fi
            return 0
        fi

        if ! command -v systemctl >/dev/null 2>&1; then
            $QUIET || echo -e "${yellow}Notice: systemctl not found (non-systemd system).${reset}"
            $QUIET || echo -e "${dim}To use the background checker, please manually schedule a cron job for: ${reset}${white}$(realpath "$(command -v "${BASH_SOURCE:-$0}" 2>/dev/null || echo "${BASH_SOURCE:-$0}")") --daemon${reset}"
            return 0
        fi

        mkdir -p "$SYSTEMD_USER_DIR"

        if [[ ! -f "$DAEMON_TEMPLATE" ]]; then
            $QUIET || echo -e "${yellow}Warning: Missing daemon.template. Cannot configure systemd units.${reset}"
            return 1
        fi

        local SCRIPT_PATH TMP_SVC TMP_TMR
        SCRIPT_PATH="$(realpath "$(command -v "${BASH_SOURCE:-$0}" 2>/dev/null || echo "${BASH_SOURCE:-$0}")")"
        create_temp_file TMP_SVC "asu_svc"
        create_temp_file TMP_TMR "asu_tmr"

        local CURRENT_INTERVAL="${CHECK_INTERVAL:-$DEFAULT_CHECK_INTERVAL}"
        CURRENT_INTERVAL="$(echo "$CURRENT_INTERVAL" | tr -d '[:space:]')"
        if [[ "$CURRENT_INTERVAL" =~ ^[0-9]+$ ]]; then
            CURRENT_INTERVAL="${CURRENT_INTERVAL}h"
        fi

        local NEXT_CHECK_FILE="$CONFIG_DIR/next_check.conf"
        if acquire_state_lock "x"; then
            if [[ -f "$NEXT_CHECK_FILE" ]]; then
                local file_mtime=0 boot_ts=0
                file_mtime=$(stat -c %Y "$NEXT_CHECK_FILE" 2>/dev/null || echo 0)
                boot_ts=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null || echo 0)
                local raw_next="" next_ts="" now_ts=0 existing_tag=""
                raw_next=$(cat "$NEXT_CHECK_FILE" 2>/dev/null || echo 0)
                next_ts="${raw_next%%|*}"
                next_ts="${next_ts#"${next_ts%%[![:space:]]*}"}"
                next_ts="${next_ts%"${next_ts##*[![:space:]]}"}"
                if [[ "$raw_next" == *"|"* ]]; then
                    existing_tag="${raw_next#*|}"
                    existing_tag="${existing_tag#"${existing_tag%%[![:space:]]*}"}"
                    existing_tag="${existing_tag%"${existing_tag##*[![:space:]]}"}"
                fi
                now_ts=$(date +%s)
                if (( file_mtime > 0 && boot_ts > 0 && file_mtime < boot_ts )) && [[ "$existing_tag" != "silence" ]]; then
                    rm -f "$NEXT_CHECK_FILE"
                elif [[ "$next_ts" =~ ^[0-9]+$ ]] && (( next_ts > now_ts )); then
                    local diff_m=$(( (next_ts - now_ts) / 60 + 1 ))
                    (( diff_m < 1 )) && diff_m=1
                    CURRENT_INTERVAL="${diff_m}min"
                else
                    rm -f "$NEXT_CHECK_FILE"
                fi
            fi
            release_state_lock
        fi

        local START_DELAY_VAL="${START_DELAY:-$DEFAULT_START_DELAY}"
        START_DELAY_VAL="$(echo "$START_DELAY_VAL" | tr -d '[:space:]')"
        if [[ "$START_DELAY_VAL" =~ ^[0-9]+$ ]]; then
            START_DELAY_VAL="${START_DELAY_VAL}min"
        fi

        export SCRIPT_PATH START_DELAY="$START_DELAY_VAL" CURRENT_INTERVAL
        awk -v svc="$TMP_SVC" -v tmr="$TMP_TMR" '
            BEGIN {
                script = ENVIRON["SCRIPT_PATH"]
                delay = ENVIRON["START_DELAY"]
                interval = ENVIRON["CURRENT_INTERVAL"]
            }
            /^\[TimerTemplate\]/ { in_timer=1; next }
            {
                while ((idx = index($0, "__SCRIPT_PATH__")) > 0)
                    $0 = substr($0, 1, idx - 1) "\"" script "\"" substr($0, idx + 15)
                while ((idx = index($0, "__START_DELAY__")) > 0)
                    $0 = substr($0, 1, idx - 1) delay substr($0, idx + 15)
                while ((idx = index($0, "__CHECK_INTERVAL__")) > 0)
                    $0 = substr($0, 1, idx - 1) interval substr($0, idx + 18)

                if (in_timer) print > tmr
                else print > svc
            }
        ' "$DAEMON_TEMPLATE"

        if [[ ! -s "$TMP_SVC" || ! -s "$TMP_TMR" ]]; then
            rm -f "$TMP_SVC" "$TMP_TMR"
            $QUIET || echo -e "${yellow}Warning: Failed to generate systemd units from template.${reset}"
            return 1
        fi

        local needs_reload=false
        if ! cmp -s "$TMP_SVC" "$SYSTEMD_USER_DIR/arch-smart-update.service" || ! cmp -s "$TMP_TMR" "$SYSTEMD_USER_DIR/arch-smart-update.timer"; then
            mv "$TMP_SVC" "$SYSTEMD_USER_DIR/arch-smart-update.service"
            mv "$TMP_TMR" "$SYSTEMD_USER_DIR/arch-smart-update.timer"
            chmod 644 "$SYSTEMD_USER_DIR/arch-smart-update.service" "$SYSTEMD_USER_DIR/arch-smart-update.timer"
            needs_reload=true
        else
            rm -f "$TMP_SVC" "$TMP_TMR"
        fi

        if [[ "$needs_reload" == "true" ]]; then
            systemctl --user daemon-reload >/dev/null 2>&1
        fi

        if ! systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null; then
            systemctl --user enable arch-smart-update.timer >/dev/null 2>&1
        fi

        if ! systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null; then
            systemctl --user start arch-smart-update.timer >/dev/null 2>&1
        elif [[ "$force_restart" == "true" || "$needs_reload" == "true" ]]; then
            systemctl --user restart arch-smart-update.timer >/dev/null 2>&1
        fi
        return 0
    else
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null || systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null || [[ -f "$SYSTEMD_USER_DIR/arch-smart-update.timer" ]]; then
                systemctl --user disable --now arch-smart-update.timer >/dev/null 2>&1
                systemctl --user stop arch-smart-update.service >/dev/null 2>&1 || true
                rm -f "$SYSTEMD_USER_DIR/arch-smart-update.service" "$SYSTEMD_USER_DIR/arch-smart-update.timer"
                systemctl --user daemon-reload >/dev/null 2>&1
            fi
        fi
        return 0
    fi
}

ensure_asu_base_configs() {
    local force_update="${1:-false}"
    local manifest_file="$CONFIG_DIR/manifest.sha256"
    local manifest_updated=false

    if [[ "$force_update" == "true" || ! -f "$DAEMON_TEMPLATE" || ! -f "$SETTINGS_DEFAULT" || ! -f "$manifest_file" || ! -f "$PKG_CONF" || ! -f "$ICON_PATH" ]]; then
        if curl -sI --connect-timeout 2 --max-time 4 "https://raw.githubusercontent.com" >/dev/null 2>&1; then
            local tmp_m=""
            create_temp_file tmp_m "manifest"
            local manifest_target
            manifest_target=$(bypass_cdn_cache "https://raw.githubusercontent.com/motorrin/arch-smart-update/main/manifest.sha256")
            if curl -sLfo "$tmp_m" --connect-timeout 2 --max-time 4 "$manifest_target"; then
                if grep -qE '^[a-f0-9]{64}[[:space:]]+' "$tmp_m"; then
                    mv "$tmp_m" "$manifest_file"
                    tmp_m=""
                    manifest_updated=true
                else
                    rm -f "$tmp_m"
                    tmp_m=""
                    echo -e "${yellow}Warning: Downloaded manifest has an invalid format. Skipping config updates to prevent verification failures.${reset}"
                fi
            else
                rm -f "$tmp_m"
                tmp_m=""
                echo -e "${yellow}Warning: Failed to update manifest.sha256. Skipping config updates to prevent verification failures.${reset}"
            fi

            if [[ -f "$manifest_file" ]]; then
                if [[ "$manifest_updated" == "true" || ! -f "$SETTINGS_DEFAULT" || ! -f "$PKG_CONF" || ! -f "$DAEMON_TEMPLATE" || ! -f "$ICON_PATH" ]]; then
                    update_from_github "$SETTINGS_DEFAULT" "https://raw.githubusercontent.com/motorrin/arch-smart-update/main/settings.conf" "PROMPT_MIRROR_REFRESH"
                    update_from_github "$PKG_CONF" "https://raw.githubusercontent.com/motorrin/arch-smart-update/main/packages.conf" "NUCLEAR_PKGS"
                    update_from_github "$DAEMON_TEMPLATE" "https://raw.githubusercontent.com/motorrin/arch-smart-update/main/daemon.template" "[TimerTemplate]"
                    update_from_github "$ICON_PATH" "https://raw.githubusercontent.com/motorrin/arch-smart-update/main/ASU.png" ""
                fi
            elif [[ ! -f "$SETTINGS_DEFAULT" ]]; then
                echo -e "${yellow}Warning: Manifest verification failed and local settings.default.conf is missing.${reset}"
            fi
        fi
    fi

    [[ -f "$ICON_PATH" ]] && chmod 644 "$ICON_PATH" 2>/dev/null

    if [[ ! -f "$DAEMON_TEMPLATE" || ! -f "$SETTINGS_DEFAULT" ]]; then
        return 1
    fi

    return 0
}

write_bg_check_setting() {
    local target_file="${1:-}"
    local target_val="${2:-false}"

    [[ -z "$target_file" ]] && return 1

    local real_target
    real_target=$(realpath -m "$target_file" 2>/dev/null || realpath "$target_file" 2>/dev/null || echo "$target_file")

    if ! acquire_state_lock "x"; then
        return 1
    fi

    if [[ ! -f "$real_target" ]]; then
        if [[ -f "$SETTINGS_DEFAULT" ]]; then
            if ! cp "$SETTINGS_DEFAULT" "$real_target"; then
                release_state_lock
                return 1
            fi
            chmod 600 "$real_target" 2>/dev/null || true
        else
            release_state_lock
            return 1
        fi
    fi

    local target_tmp="${real_target}.tmp"
    ASU_TEMP_FILES+=("$target_tmp")

    local trust_file="$CONFIG_DIR/.trusted_hash"
    local was_trusted=false
    local pre_cmds_hash=""
    if [[ -f "$trust_file" ]]; then
        local current_file_hash
        current_file_hash=$(sha256sum "$real_target" 2>/dev/null | cut -d' ' -f1)
        local stored_hash
        stored_hash=$(cat "$trust_file" 2>/dev/null || true)
        if [[ -n "$current_file_hash" && "$current_file_hash" == "$stored_hash" ]]; then
            was_trusted=true
            pre_cmds_hash=$(parse_bash_array "$real_target" "CUSTOM_CMDS" 2>/dev/null | sha256sum | cut -d' ' -f1)
        fi
    fi

    if ! python3 - "$real_target" "$target_val" "$target_tmp" <<'PYEOF'
import sys, os, re

tmp_path = sys.argv[3]
try:
    conf_path = os.path.realpath(sys.argv[1])
    new_val = sys.argv[2]
    lines = []
    if os.path.exists(conf_path):
        with open(conf_path, "r", encoding="utf-8", errors="surrogateescape") as f:
            lines = f.readlines()

    h = chr(35)
    active_pattern = re.compile(r"^([ \t]*)ENABLE_BACKGROUND_CHECK\s*=[^" + h + r"\r\n]*(" + h + r".*)?$")
    commented_pattern = re.compile(r"^([ \t]*)" + h + r"+[ \t]*ENABLE_BACKGROUND_CHECK\s*=[^" + h + r"\r\n]*(" + h + r".*)?$")

    has_active = any(active_pattern.match(l.rstrip("\r\n")) for l in lines)
    out = []
    replaced = False

    for line in lines:
        rline = line.rstrip("\r\n")
        m_act = active_pattern.match(rline)
        m_com = commented_pattern.match(rline)

        if m_act:
            if not replaced:
                indent = m_act.group(1)
                comment = f" {m_act.group(2).strip()}" if m_act.group(2) else ""
                out.append(f"{indent}ENABLE_BACKGROUND_CHECK={new_val}{comment}\n")
                replaced = True
            continue
        elif m_com and not has_active:
            if not replaced:
                indent = m_com.group(1)
                comment = f" {m_com.group(2).strip()}" if m_com.group(2) else ""
                out.append(f"{indent}ENABLE_BACKGROUND_CHECK={new_val}{comment}\n")
                replaced = True
            else:
                out.append(line)
        else:
            out.append(line)

    if not replaced:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"ENABLE_BACKGROUND_CHECK={new_val}\n")

    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with open(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.writelines(out)
    os.replace(tmp_path, conf_path)
    sys.exit(0)
except Exception:
    if tmp_path and os.path.exists(tmp_path):
        try:
            os.remove(tmp_path)
        except OSError:
            pass
    sys.exit(1)
PYEOF
    then
        rm -f "$target_tmp" 2>/dev/null || true
        release_state_lock
        return 1
    fi

    chmod 600 "$real_target" 2>/dev/null || true

    if [[ "$was_trusted" == "true" && -f "$trust_file" ]]; then
        local post_cmds_hash
        post_cmds_hash=$(parse_bash_array "$real_target" "CUSTOM_CMDS" 2>/dev/null | sha256sum | cut -d' ' -f1)
        if [[ "$post_cmds_hash" == "$pre_cmds_hash" ]]; then
            sha256sum "$real_target" | cut -d' ' -f1 > "$trust_file"
            chmod 600 "$trust_file" 2>/dev/null || true
        else
            rm -f "$trust_file"
        fi
    fi

    release_state_lock
    return 0
}

load_daemon_params() {
    local file="${1:-}"
    [[ -z "$file" || ! -f "$file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line%%[[:space:]]#*}"
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            if [[ "$val" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ || "$val" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
                val="${BASH_REMATCH[1]}"
            else
                val="${val%%#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi
            case "$key" in
                ENABLE_BACKGROUND_CHECK|CHECK_INTERVAL|START_DELAY|SILENCE_UPDATES|NOTIFICATION_TIMEOUT)
                    declare -g "$key=$val"
                    ;;
            esac
        fi
    done < "$file"

    [[ -z "${CHECK_INTERVAL:-}" ]] && CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    [[ -z "${START_DELAY:-}" ]] && START_DELAY="$DEFAULT_START_DELAY"
    [[ -z "${SILENCE_UPDATES:-}" ]] && SILENCE_UPDATES="$DEFAULT_SILENCE_UPDATES"
    parse_timeout_to_ms "${NOTIFICATION_TIMEOUT:-$DEFAULT_NOTIFICATION_TIMEOUT}" NOTIFICATION_TIMEOUT "$DEFAULT_NOTIFICATION_TIMEOUT"
}

handle_enable_daemon() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${red}Error: systemctl not found (non-systemd system). Cannot enable daemon.${reset}"
        exit 1
    fi

    if ! command -v fakeroot >/dev/null 2>&1; then
        echo -e "${red}Error: Background update check requires 'fakeroot' (install base-devel).${reset}"
        exit 1
    fi

    if ! ensure_asu_base_configs; then
        echo -e "${red}Error: Failed to initialize configuration files. Network unreachable?${reset}"
        exit 1
    fi

    if [[ ! -f "$DAEMON_TEMPLATE" ]]; then
        echo -e "${red}Error: Missing daemon.template. Cannot configure systemd units.${reset}"
        exit 1
    fi

    local real_settings_conf
    real_settings_conf=$(realpath -m "$SETTINGS_CONF" 2>/dev/null || realpath "$SETTINGS_CONF" 2>/dev/null || echo "$SETTINGS_CONF")

    if [[ -f "$real_settings_conf" ]]; then
        if ! validate_user_conf "$real_settings_conf" "settings.conf" "true"; then
            echo -e "${red}Error: settings.conf failed security validation. Aborting.${reset}"
            exit 1
        fi
    fi

    if ! write_bg_check_setting "$real_settings_conf" "true"; then
        echo -e "${red}Error: Failed to write configuration to settings.conf.${reset}"
        exit 1
    fi
    load_daemon_params "$real_settings_conf"

    if acquire_state_lock "x"; then
        rm -f "${CONFIG_DIR}/next_check.conf"
        release_state_lock
    else
        rm -f "${CONFIG_DIR}/next_check.conf" 2>/dev/null || true
    fi

    ENABLE_BACKGROUND_CHECK="true"
    if ! sync_daemon_state "true"; then
        write_bg_check_setting "$real_settings_conf" "false" >/dev/null 2>&1 || true
        ENABLE_BACKGROUND_CHECK="false"
        sync_daemon_state "false" >/dev/null 2>&1 || true
        echo -e "${red}Error: Failed to configure background service units.${reset}"
        exit 1
    fi

    if systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null && systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null; then
        echo -e "${green}Systemd background update service successfully enabled and started.${reset}"
        if ! pacman -Q libnotify >/dev/null 2>&1; then
            echo -e "${yellow}Notice: 'libnotify' is not installed. Desktop notifications may not appear.${reset}"
        fi
        exit 0
    else
        write_bg_check_setting "$real_settings_conf" "false" >/dev/null 2>&1 || true
        ENABLE_BACKGROUND_CHECK="false"
        sync_daemon_state "false" >/dev/null 2>&1 || true
        echo -e "${red}Error: Failed to activate arch-smart-update.timer via systemd.${reset}"
        echo -e "${yellow}Notice: Check systemd user session status (e.g. systemctl --user status). Settings reverted.${reset}"
        exit 1
    fi
}

handle_disable_daemon() {
    ensure_asu_base_configs "false" >/dev/null 2>&1 || true

    local real_settings_conf conf_updated=false
    real_settings_conf=$(realpath -m "$SETTINGS_CONF" 2>/dev/null || realpath "$SETTINGS_CONF" 2>/dev/null || echo "$SETTINGS_CONF")

    local can_write=true
    if [[ -f "$real_settings_conf" ]]; then
        if ! validate_user_conf "$real_settings_conf" "settings.conf" "false"; then
            can_write=false
        fi
    fi

    if [[ "$can_write" == "true" ]]; then
        if write_bg_check_setting "$real_settings_conf" "false"; then
            conf_updated=true
        fi
    fi

    if acquire_state_lock "x"; then
        rm -f "${CONFIG_DIR}/next_check.conf"
        release_state_lock
    else
        rm -f "${CONFIG_DIR}/next_check.conf" 2>/dev/null || true
    fi

    ENABLE_BACKGROUND_CHECK="false"
    sync_daemon_state "false"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null || systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null; then
            echo -e "${red}Error: Failed to completely disable and stop arch-smart-update.timer via systemd.${reset}"
            exit 1
        else
            echo -e "${green}Systemd background update service successfully disabled and stopped.${reset}"
            if [[ "$conf_updated" == "false" ]]; then
                echo -e "${yellow}Notice: Timer was stopped, but settings.conf could not be safely updated.${reset}"
            fi
            exit 0
        fi
    else
        if [[ "$conf_updated" == "true" ]]; then
            echo -e "${green}Local configuration updated (ENABLE_BACKGROUND_CHECK=false).${reset}"
        else
            echo -e "${yellow}Notice: systemctl not found and settings.conf was not modified.${reset}"
        fi
        exit 0
    fi
}

handle_silence() {
    local raw_arg="${1:-}"
    local silence_arg="$raw_arg"
    silence_arg="${silence_arg#"${silence_arg%%[![:space:]]*}"}"
    silence_arg="${silence_arg%"${silence_arg##*[![:space:]]}"}"

    local real_settings_conf
    real_settings_conf=$(realpath -m "$SETTINGS_CONF" 2>/dev/null || realpath "$SETTINGS_CONF" 2>/dev/null || echo "$SETTINGS_CONF")
    if [[ -f "$real_settings_conf" ]]; then
        if [[ "$silence_arg" == "-h" || "$silence_arg" == "--help" ]]; then
            load_daemon_params "$real_settings_conf" 2>/dev/null || true
        else
            if ! validate_user_conf "$real_settings_conf" "settings.conf" "false"; then
                echo -e "${red}Error: settings.conf failed security validation. Aborting.${reset}"
                exit 1
            fi
            load_daemon_params "$real_settings_conf"
        fi
    fi

    if [[ "$silence_arg" == "-h" || "$silence_arg" == "--help" ]]; then
        local display_default="${SILENCE_UPDATES:-$DEFAULT_SILENCE_UPDATES}"
        echo -e "${blue}${bold}Silence Notification Schedule${reset}"
        echo -e "\nUsage: ${white}${0##*/} --silence${reset} [duration|off]\n"
        echo -e "Options:"
        echo -e "  ${cyan}(no argument)${reset}  Silence notifications using configured value (${white}${display_default}${reset})."
        echo -e "  ${cyan}[duration]${reset}     Custom duration (e.g. ${white}30m${reset}, ${white}2h${reset}, ${white}1d${reset})."
        echo -e "  ${cyan}off, cancel${reset}    Cancel active silence schedule and restore normal check interval."
        exit 0
    fi

    local daemon_active=false
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null || systemctl --user is-enabled --quiet arch-smart-update.timer 2>/dev/null; then
            daemon_active=true
        fi
    fi

    local silence_cfg=""
    local is_cancel=false

    if [[ -n "$silence_arg" ]]; then
        local silence_arg_lower="${silence_arg,,}"
        local silence_arg_norm="${silence_arg_lower#--}"
        silence_arg_norm="${silence_arg_norm#-}"
        if [[ "$silence_arg_norm" =~ ^(0[a-zA-Z]*|off|reset|clear|cancel|none)$ ]]; then
            is_cancel=true
        elif [[ "$silence_arg_norm" == "default" ]]; then
            silence_cfg="${SILENCE_UPDATES:-$DEFAULT_SILENCE_UPDATES}"
        else
            silence_cfg="$silence_arg"
        fi
    else
        silence_cfg="${SILENCE_UPDATES:-$DEFAULT_SILENCE_UPDATES}"
    fi

    if [[ "$is_cancel" == "true" ]]; then
        local cancel_ok=false
        if acquire_state_lock "x"; then
            rm -f "${CONFIG_DIR}/next_check.conf"
            cancel_ok=true
            release_state_lock
        fi

        if [[ "$cancel_ok" == "false" ]]; then
            echo -e "${red}Error: Failed to acquire lock to cancel silence state.${reset}"
            exit 1
        fi

        echo -e "${green}Notification silence cancelled. Standard schedule restored.${reset}"

        if [[ "${ENABLE_BACKGROUND_CHECK,,}" != "true" ]]; then
            echo -e "${yellow}Notice: Background monitor is disabled (ENABLE_BACKGROUND_CHECK=false).${reset}"
        elif [[ "$daemon_active" == "false" ]]; then
            echo -e "${yellow}Notice: Background check is enabled in settings, but systemd timer is currently inactive.${reset}"
        else
            ensure_asu_base_configs "false" >/dev/null 2>&1 || true
            sync_daemon_state "true" >/dev/null 2>&1 || true
        fi
        exit 0
    fi

    local script_name="${0##*/}"
    if [[ "${ENABLE_BACKGROUND_CHECK,,}" != "true" ]]; then
        echo -e "${red}Error: Background monitor is disabled in configuration (ENABLE_BACKGROUND_CHECK=false).${reset}"
        echo -e "${dim}Notifications are inactive. Use '${white}${script_name} --enable-daemon${dim}' to enable background checks.${reset}"
        exit 1
    fi

    local has_systemd=false
    if command -v systemctl >/dev/null 2>&1; then
        has_systemd=true
        if [[ "$daemon_active" == "false" ]]; then
            echo -e "${red}Error: Systemd background timer is currently inactive.${reset}"
            echo -e "${dim}Run '${white}${script_name} --enable-daemon${dim}' to activate the monitor before setting silence schedule.${reset}"
            exit 1
        fi
    fi

    if [[ "$has_systemd" == "true" ]]; then
        if ! ensure_asu_base_configs "false"; then
            echo -e "${red}Error: Failed to verify base configuration templates.${reset}"
            exit 1
        fi

        if [[ ! -f "$DAEMON_TEMPLATE" ]]; then
            echo -e "${red}Error: Missing daemon.template. Cannot configure silence timer.${reset}"
            exit 1
        fi
    fi

    [[ -z "$silence_cfg" ]] && silence_cfg="$DEFAULT_SILENCE_UPDATES"

    local silence_sec=0
    parse_duration_to_seconds "$silence_cfg" silence_sec

    if (( silence_sec <= 0 )); then
        echo -e "${red}Error: Invalid duration '${silence_cfg}'.${reset}"
        echo -e "${dim}Valid examples: ${white}30m${dim}, ${white}2h${dim}, ${white}1d${dim}, or ${white}off${dim} to cancel.${reset}"
        exit 1
    fi

    local now_ts silence_ts
    now_ts=$(date +%s)
    silence_ts=$(( now_ts + silence_sec ))

    local write_ok=false
    if acquire_state_lock "x"; then
        echo "${silence_ts}|silence" > "${CONFIG_DIR}/next_check.conf"
        write_ok=true
        release_state_lock
    fi

    if [[ "$write_ok" == "false" ]]; then
        echo -e "${red}Error: Failed to record silence schedule (lock timeout).${reset}"
        exit 1
    fi

    if ! sync_daemon_state "true" >/dev/null 2>&1; then
        echo -e "${red}Error: Failed to reschedule background timer.${reset}"
        if acquire_state_lock "x"; then
            rm -f "${CONFIG_DIR}/next_check.conf"
            release_state_lock
        fi
        exit 1
    fi

    local until_time
    until_time=$(date -d "@$silence_ts" +'%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$silence_ts" +%H:%M 2>/dev/null || echo "@$silence_ts")
    echo -e "${green}Notifications silenced until ${white}${until_time}${green} (${silence_cfg}).${reset}"
    exit 0
}

handle_reconfigure() {
    local real_settings_conf orig_bg_val="" bg_val_found=false
    local pre_reconf_cmds_hash="" reconf_was_trusted=false

    real_settings_conf=$(realpath -m "$SETTINGS_CONF" 2>/dev/null || realpath "$SETTINGS_CONF" 2>/dev/null || echo "$SETTINGS_CONF")

    if [[ -f "$real_settings_conf" ]]; then
        if ! validate_user_conf "$real_settings_conf" "settings.conf"; then
            echo -e "${red}Error: settings.conf validation failed before reconfiguration.${reset}"
            exit 1
        fi
        local local_trust_file="$CONFIG_DIR/.trusted_hash"
        if [[ -f "$local_trust_file" ]]; then
            local curr_conf_hash
            curr_conf_hash=$(sha256sum "$real_settings_conf" 2>/dev/null | cut -d' ' -f1)
            if [[ -n "$curr_conf_hash" && "$curr_conf_hash" == "$(cat "$local_trust_file" 2>/dev/null)" ]]; then
                reconf_was_trusted=true
            fi
        fi
        orig_bg_val=$(awk '
            /^[[:space:]]*ENABLE_BACKGROUND_CHECK[[:space:]]*=/ {
                line = $0
                sub(/\r$/, "", line)
                sub(/^[[:space:]]*ENABLE_BACKGROUND_CHECK[[:space:]]*=[[:space:]]*/, "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                gsub(/["\047]/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                val = tolower(line)
                if (val == "true" || val == "false") res = val
                else res = "invalid"
            }
            END {
                if (res != "") print res
            }
        ' "$real_settings_conf" 2>/dev/null || true)
        if [[ "$orig_bg_val" == "true" || "$orig_bg_val" == "false" ]]; then
            bg_val_found=true
        fi
        pre_reconf_cmds_hash=$(parse_bash_array "$real_settings_conf" "CUSTOM_CMDS" 2>/dev/null | sha256sum | cut -d' ' -f1)
    fi

    ensure_asu_base_configs "true"

    if [[ ! -f "$SETTINGS_DEFAULT" ]]; then
        echo -e "${red}Critical: Default configuration template settings.default.conf is missing.${reset}"
        echo -e "${yellow}Cannot proceed with reconfiguration without default template.${reset}"
        exit 1
    fi

    local restart_daemon=false
    local user_bg_choice=""
    local can_run_daemon=true

    if ! command -v systemctl >/dev/null 2>&1 || ! command -v fakeroot >/dev/null 2>&1; then
        can_run_daemon=false
    fi

    if [[ "$bg_val_found" == "true" ]]; then
        if [[ "$orig_bg_val" == "true" ]]; then
            if [[ "$can_run_daemon" == "true" ]]; then
                restart_daemon=true
            else
                echo -e "${yellow}Notice: Background monitor was enabled, but systemctl or fakeroot is missing. Disabling daemon.${reset}"
                user_bg_choice="false"
                restart_daemon=false
            fi
        fi
    else
        echo -e "${yellow}Warning: 'ENABLE_BACKGROUND_CHECK' setting was not found or is unconfigured in settings.conf.${reset}"
        if ! command -v systemctl >/dev/null 2>&1; then
            echo -e "${dim}Notice: systemctl not found. Background service cannot be enabled.${reset}"
            user_bg_choice="false"
            restart_daemon=false
        elif ! command -v fakeroot >/dev/null 2>&1; then
            echo -e "${dim}Notice: 'fakeroot' is not installed. Background update check is unavailable.${reset}"
            user_bg_choice="false"
            restart_daemon=false
        else
            echo -ne "${white}Do you want to enable and start the systemd background update service? [y/N]: ${reset}"
            local ans_daemon="n"
            read -r ans_daemon </dev/tty 2>/dev/null || read -r ans_daemon 2>/dev/null || ans_daemon="n"
            if [[ "$ans_daemon" =~ ^[Yy]$ ]]; then
                restart_daemon=true
                user_bg_choice="true"
            else
                restart_daemon=false
                user_bg_choice="false"
            fi
        fi
    fi

    if ! acquire_state_lock "x"; then
        echo -e "${red}Error: Could not acquire lock on configuration state. Migration aborted.${reset}"
        exit 1
    fi

    if [[ ! -f "$real_settings_conf" && -f "$SETTINGS_DEFAULT" ]]; then
        cp "$SETTINGS_DEFAULT" "$real_settings_conf"
        chmod 600 "$real_settings_conf"
    fi

    local reconf_tmp="${real_settings_conf}.tmp"
    local py_exit=0
    ASU_TEMP_FILES+=("$reconf_tmp")
    rm -f "$reconf_tmp" 2>/dev/null || true

    python3 - "$real_settings_conf" "$SETTINGS_DEFAULT" "$reconf_tmp" "${user_bg_choice:-}" <<'EOF'
import re, sys, os

def strip_quotes_preserve_length(s):
    chars = list(s)
    in_dquote = False
    in_squote = False
    escaped = False
    for i, char in enumerate(chars):
        if escaped:
            chars[i] = ' '
            escaped = False
            continue
        if char == '\\':
            chars[i] = ' '
            escaped = True
            continue
        if char == '"' and not in_squote:
            in_dquote = not in_dquote
            chars[i] = ' '
        elif char == "'" and not in_dquote:
            in_squote = not in_dquote
            chars[i] = ' '
        elif in_dquote or in_squote:
            chars[i] = ' '
    return "".join(chars)

def clean_comment_and_quotes(s):
    clean = ""
    in_dquote = False
    in_squote = False
    escaped = False
    for char in s:
        if escaped:
            clean += char
            escaped = False
            continue
        if char == '\\':
            clean += char
            escaped = True
            continue
        if char == '"' and not in_squote:
            in_dquote = not in_dquote
        elif char == "'" and not in_dquote:
            in_squote = not in_dquote
        elif char == chr(35) and not in_dquote and not in_squote:
            break
        clean += char
    clean = clean.strip()
    return clean, strip_quotes_preserve_length(clean)

def parse(content):
    sc = {}
    ar = {}
    raw_lines = content.splitlines()
    lines = []
    accumulator = ""
    for r_line in raw_lines:
        r_stripped = r_line.rstrip()
        if r_stripped.endswith("\\"):
            accumulator += r_stripped[:-1]
        else:
            accumulator += r_line
            lines.append(accumulator)
            accumulator = ""
    if accumulator:
        lines.append(accumulator)

    in_array = False
    current_array_name = None
    current_array_elems = []
    elem_re = re.compile(r'("[^"\\]*(?:\\.[^"\\]*)*")|(\'[^\'\\]*(?:\\.[^\'\\]*)*\')|([^\s\(\)]+)')

    for line in lines:
        line_stripped = line.strip()
        if in_array:
            clean_line, temp = clean_comment_and_quotes(line_stripped)
            if ')' in temp:
                idx_in_clean = temp.find(')')
                last_part = clean_line[:idx_in_clean].strip()
                if last_part:
                    if last_part.startswith(chr(35)):
                        current_array_elems.append(last_part)
                    else:
                        for m in elem_re.finditer(last_part):
                            item = m.group(1) or m.group(2) or m.group(3)
                            if item is not None:
                                current_array_elems.append(item)
                ar[current_array_name] = current_array_elems
                in_array = False
                current_array_name = None
                current_array_elems = []
            else:
                if line_stripped:
                    if line_stripped.startswith(chr(35)):
                        current_array_elems.append(line_stripped)
                    else:
                        for m in elem_re.finditer(clean_line):
                            item = m.group(1) or m.group(2) or m.group(3)
                            if item is not None:
                                current_array_elems.append(item)
        else:
            if not line_stripped or line_stripped.startswith(chr(35)):
                continue

            clean_line, temp = clean_comment_and_quotes(line_stripped)
            if not clean_line:
                continue

            m_arr = re.match(r"^([A-Za-z0-9_]+)\s*(\+)?=\s*\((.*)", clean_line)
            if m_arr:
                name = m_arr.group(1)
                rest = m_arr.group(3).strip()
                in_array = True
                current_array_name = name
                current_array_elems = []

                temp = strip_quotes_preserve_length(rest)
                if ')' in temp:
                    idx = temp.find(')')
                    rest_clean = rest[:idx].strip()
                    if rest_clean:
                        if rest_clean.startswith(chr(35)):
                            current_array_elems.append(rest_clean)
                        else:
                            for m in elem_re.finditer(rest_clean):
                                item = m.group(1) or m.group(2) or m.group(3)
                                if item is not None:
                                    current_array_elems.append(item)
                    ar[name] = current_array_elems
                    in_array = False
                    current_array_name = None
                    current_array_elems = []
                else:
                    if rest:
                        if rest.startswith(chr(35)):
                            current_array_elems.append(rest)
                        else:
                            for m in elem_re.finditer(rest):
                                item = m.group(1) or m.group(2) or m.group(3)
                                if item is not None:
                                    current_array_elems.append(item)
            else:
                if "=" in clean_line:
                    parts = clean_line.split("=", 1)
                    k = parts[0].strip()
                    if k.endswith("+"):
                        k = k[:-1].strip()
                    if re.match(r"^[A-Za-z0-9_]+$", k):
                        sc[k] = parts[1].strip()
    return sc, ar

def norm_elem(x):
    if (x.startswith('"') and x.endswith('"')) or (x.startswith("'") and x.endswith("'")):
        return x[1:-1]
    return x

def norm_arr(arr):
    return [norm_elem(x) for x in arr]

u_sc, u_ar = {}, {}
if os.path.exists(sys.argv[1]):
    try:
        with open(sys.argv[1], "r", encoding="utf-8", errors="surrogateescape") as f:
            u_sc, u_ar = parse(f.read())
    except Exception as e:
        print(f"Error parsing user configuration file: {e}", file=sys.stderr)
        sys.exit(1)

prompted_keys = set()
if len(sys.argv) > 4 and sys.argv[4]:
    u_sc["ENABLE_BACKGROUND_CHECK"] = sys.argv[4]
    prompted_keys.add("ENABLE_BACKGROUND_CHECK")

try:
    with open(sys.argv[2], "r", encoding="utf-8", errors="surrogateescape") as f:
        t_content = f.read()
        t_lines = t_content.splitlines(keepends=True)
        t_sc, t_ar = parse(t_content)
except Exception as e:
    print(f"Error reading configuration template: {e}", file=sys.stderr)
    sys.exit(1)

out = []
in_arr = False
skipping_arr = False
arr_name = None
migrated_scalars = set()
migrated_arrays = set()
written_scalars = set()
written_arrays = set()

is_tty = sys.stdout.isatty()
BLUE = "\033[38;5;75m" if is_tty else ""
GREEN = "\033[38;5;71m" if is_tty else ""
YELLOW = "\033[38;5;214m" if is_tty else ""
RED = "\033[38;5;196m" if is_tty else ""
MAGENTA = "\033[38;5;176m" if is_tty else ""
CYAN = "\033[38;5;79m" if is_tty else ""
GRAY = "\033[38;5;244m" if is_tty else ""
DIM = "\033[2m" if is_tty else ""
BOLD = "\033[1m" if is_tty else ""
RESET = "\033[0m" if is_tty else ""

print(f"{BLUE}{BOLD}:: Commencing smart configuration migration...{RESET}")

for line_raw in t_lines:
    line = line_raw.strip()

    if skipping_arr:
        clean_line, temp = clean_comment_and_quotes(line)
        if ")" in temp:
            skipping_arr = False
        continue

    if in_arr:
        clean_line, temp = clean_comment_and_quotes(line)
        if ")" in temp:
            el = u_ar.get(arr_name)
            if el is not None:
                default_el = t_ar.get(arr_name, [])
                active_el = [x for x in el if not x.strip().startswith(chr(35))]
                if norm_arr(el) == norm_arr(default_el):
                    print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}Array matches template. No migration needed.{RESET}")
                elif active_el:
                    count_suffix = f"{len(active_el)} item{'s' if len(active_el) != 1 else ''}"
                    print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GREEN}Custom user elements detected ({count_suffix}). Preserving customized list.{RESET}")
                elif el:
                    print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}No active elements detected (commented examples only). Preserving existing entries.{RESET}")
                else:
                    print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}Keeping array empty (user preference).{RESET}")
                for item in el:
                    out.append(f"    {item}\n")
            else:
                default_el = t_ar.get(arr_name, [])
                active_default = [x for x in default_el if not x.strip().startswith(chr(35))]
                count_info = f" ({len(active_default)} item{'s' if len(active_default) != 1 else ''})" if active_default else ""
                print(f"  {DIM}[Analyzing]{RESET} Array {MAGENTA}{arr_name:<23}{RESET} -> {YELLOW}Adopting default list from updated template{count_info}.{RESET}")
            out.append(line_raw)
            in_arr = False
        else:
            if arr_name not in u_ar:
                out.append(line_raw)
        continue

    m_arr = re.match(r"^([A-Za-z0-9_]+)\s*(\+)?=\s*\((.*)", line)
    if m_arr:
        arr_name = m_arr.group(1)
        clean_line, temp = clean_comment_and_quotes(line)
        idx_paren = temp.find('(')
        is_single_line = idx_paren != -1 and ")" in temp[idx_paren+1:]

        if arr_name in written_arrays:
            if not is_single_line:
                skipping_arr = True
            continue

        written_arrays.add(arr_name)
        out.append(line_raw)
        migrated_arrays.add(arr_name)

        if is_single_line:
            el = u_ar.get(arr_name)
            if el is not None:
                default_el = t_ar.get(arr_name, [])
                active_el = [x for x in el if not x.strip().startswith(chr(35))]
                if norm_arr(el) == norm_arr(default_el):
                    print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}Array matches template. No migration needed.{RESET}")
                else:
                    out.pop()
                    out.append(f"{arr_name}=(\n")
                    if active_el:
                        count_suffix = f"{len(active_el)} item{'s' if len(active_el) != 1 else ''}"
                        print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GREEN}Custom user elements detected ({count_suffix}). Preserving customized list.{RESET}")
                    elif el:
                        print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}No active elements detected (commented examples only). Preserving existing entries.{RESET}")
                    else:
                        print(f"  {DIM}[Analyzing]{RESET} Array {CYAN}{arr_name:<23}{RESET} -> {GRAY}Keeping array empty (user preference).{RESET}")
                    for item in el:
                        out.append(f"    {item}\n")
                    out.append(")\n")
            else:
                default_el = t_ar.get(arr_name, [])
                active_default = [x for x in default_el if not x.strip().startswith(chr(35))]
                count_info = f" ({len(active_default)} item{'s' if len(active_default) != 1 else ''})" if active_default else ""
                print(f"  {DIM}[Analyzing]{RESET} Array {MAGENTA}{arr_name:<23}{RESET} -> {YELLOW}Adopting default list from updated template{count_info}.{RESET}")
        else:
            in_arr = True
        continue

    m_sc = re.match(r"^(\s*#\s*)?([A-Za-z0-9_]+)\s*(\+)?=\s*(.*)", line)
    if m_sc:
        k = m_sc.group(2)
        is_commented = m_sc.group(1) is not None and m_sc.group(1).strip().startswith(chr(35))
        if is_commented and k in t_sc:
            out.append(line_raw)
            continue
        migrated_scalars.add(k)
        if k in written_scalars:
            if is_commented:
                out.append(line_raw)
            continue
        if k in u_sc:
            user_val = u_sc[k]
            default_val = t_sc.get(k, "N/A")
            if k in prompted_keys:
                print(f"  {DIM}[Analyzing]{RESET} Option {CYAN}{k:<23}{RESET} -> {GREEN}Setting value '{user_val}' configured via user prompt.{RESET}")
            elif user_val != default_val:
                print(f"  {DIM}[Analyzing]{RESET} Option {CYAN}{k:<23}{RESET} -> {GREEN}Custom value '{user_val}' matches user configuration. Preserving preference.{RESET}")
            else:
                print(f"  {DIM}[Analyzing]{RESET} Option {CYAN}{k:<23}{RESET} -> {GRAY}Value '{user_val}' matches template. No migration needed.{RESET}")
            out.append(f"{k}={user_val}\n")
            written_scalars.add(k)
            continue
        else:
            if is_commented:
                out.append(line_raw)
                continue
            else:
                default_val = t_sc.get(k, "N/A")
                print(f"  {DIM}[Analyzing]{RESET} Option {MAGENTA}{k:<23}{RESET} -> {YELLOW}Parameter missing in user config. Appending default value: {default_val}{RESET}")
                out.append(line_raw)
                written_scalars.add(k)
                continue

    out.append(line_raw)

protected_keys = {"ENABLE_BACKGROUND_CHECK"}
orphans = (set(u_sc.keys()) - migrated_scalars) - prompted_keys - protected_keys
orphan_arrays = set(u_ar.keys()) - migrated_arrays
if orphans or orphan_arrays:
    print(f"\n{YELLOW}{BOLD}:: Deprecated parameter cleanup:{RESET}")
    for o in orphans:
        print(f"  {DIM}[Analyzing]{RESET} Option {RED}{o:<23}{RESET} -> {GRAY}Discarding unrecognized parameter (removed from template).{RESET}")
    for o in orphan_arrays:
        print(f"  {DIM}[Analyzing]{RESET} Array  {RED}{o:<23}{RESET} -> {GRAY}Discarding unrecognized array (removed from template).{RESET}")

for p_key in sorted(prompted_keys | (protected_keys & set(u_sc.keys()))):
    if p_key not in written_scalars and p_key in u_sc:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"{p_key}={u_sc[p_key]}\n")
        written_scalars.add(p_key)

try:
    fd = os.open(sys.argv[3], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with open(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.writelines(out)
except Exception as e:
    print(f"Error writing configuration: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    py_exit=$?

    if [[ $py_exit -eq 0 && -f "$reconf_tmp" ]]; then
        mv "$reconf_tmp" "$real_settings_conf"
        chmod 600 "$real_settings_conf"
        if [[ "$reconf_was_trusted" == "true" && -f "$local_trust_file" ]]; then
            local post_reconf_cmds_hash
            post_reconf_cmds_hash=$(parse_bash_array "$real_settings_conf" "CUSTOM_CMDS" 2>/dev/null | sha256sum | cut -d' ' -f1)
            if [[ "$post_reconf_cmds_hash" == "$pre_reconf_cmds_hash" ]]; then
                sha256sum "$real_settings_conf" | cut -d' ' -f1 > "$local_trust_file"
                chmod 600 "$local_trust_file" 2>/dev/null || true
            else
                rm -f "$local_trust_file"
            fi
        elif [[ -f "$local_trust_file" ]]; then
            rm -f "$local_trust_file"
        fi
        if [[ "$restart_daemon" == "true" ]]; then
            local ex_tag=""
            local ex_ts=0
            local ex_raw=""
            local ex_raw_ts=""
            if [[ -f "${CONFIG_DIR}/next_check.conf" ]]; then
                ex_raw=$(cat "${CONFIG_DIR}/next_check.conf" 2>/dev/null || echo 0)
                [[ "$ex_raw" == *"|"* ]] && ex_tag="${ex_raw#*|}"
                ex_tag="${ex_tag#"${ex_tag%%[![:space:]]*}"}"
                ex_tag="${ex_tag%"${ex_tag##*[![:space:]]}"}"
                ex_raw_ts="${ex_raw%%|*}"
                ex_raw_ts="${ex_raw_ts#"${ex_raw_ts%%[![:space:]]*}"}"
                ex_raw_ts="${ex_raw_ts%"${ex_raw_ts##*[![:space:]]}"}"
                [[ "$ex_raw_ts" =~ ^[0-9]+$ ]] && ex_ts=$(( 10#$ex_raw_ts ))
            fi
            if [[ "$ex_tag" != "silence" ]] || (( ex_ts <= $(date +%s) )); then
                rm -f "${CONFIG_DIR}/next_check.conf"
            fi
        else
            rm -f "${CONFIG_DIR}/next_check.conf"
        fi
        echo -e "\n${green}Smart configuration migration completed successfully.${reset}"
    else
        echo -e "${red}Error: Failed to process and merge configuration files.${reset}"
        rm -f "$reconf_tmp" 2>/dev/null || true
        release_state_lock
        exit 1
    fi

    if [[ -n "${real_settings_conf:-}" && -f "$real_settings_conf" ]]; then
        if ! validate_user_conf "$real_settings_conf" "settings.conf"; then
            echo -e "${red}Error: settings.conf validation failed after reconfiguration.${reset}"
            SETTINGS_VALIDATION_FAILED=true
            release_state_lock
            exit 1
        fi
        load_daemon_params "$real_settings_conf"
    fi

    if [[ "$restart_daemon" == "true" ]]; then
        if [[ ! -f "$DAEMON_TEMPLATE" ]]; then
            echo -e "${yellow}Warning: Missing daemon.template. Background service could not be started.${reset}"
        else
            ENABLE_BACKGROUND_CHECK="true"
            sync_daemon_state "true"
            if command -v systemctl >/dev/null 2>&1; then
                if ! systemctl --user is-active --quiet arch-smart-update.timer 2>/dev/null; then
                    echo -e "${yellow}Warning: Background timer was configured, but failed to activate via systemd.${reset}"
                fi
            fi
            if ! pacman -Q libnotify >/dev/null 2>&1; then
                echo -e "${yellow}Notice: 'libnotify' is not installed. Desktop notifications may not appear.${reset}"
            fi
        fi
    else
        ENABLE_BACKGROUND_CHECK="false"
        sync_daemon_state "false"
    fi

    release_state_lock
    exit 0
}

# --- 3. CLI Action Dispatch ---
if [[ "${1:-}" == "--notify-worker" ]]; then
    handle_notify_worker "$@"
    exit 0
fi

if [[ "${1:-}" == "--news-worker" ]]; then
    handle_news_worker "$@"
    exit 0
fi

if [[ "${1:-}" == "--reconfigure" ]]; then
    handle_reconfigure
fi

if [[ "${1:-}" == "--enable-daemon" || "${1:-}" == "--start-daemon" ]]; then
    handle_enable_daemon
fi

if [[ "${1:-}" == "--disable-daemon" || "${1:-}" == "--stop-daemon" ]]; then
    handle_disable_daemon
fi

if [[ "${1:-}" == "--silence" || "${1:-}" == "--snooze" || "${1:-}" == --silence=* || "${1:-}" == --snooze=* ]]; then
    silence_opt=""
    if [[ "${1:-}" == *"="* ]]; then
        silence_opt="${1#*=}"
    elif (( $# >= 2 )); then
        silence_opt="${2:-}"
    fi
    handle_silence "$silence_opt"
fi

# --- 4. Runtime Configuration & Daemon Sync ---
mkdir -p "$CONFIG_DIR"

if ! $DAEMON_MODE; then
    echo -e "${blue}${bold}:: Arch Smart Update${reset}"
    echo -e "${dim}Config path: ${white}${SETTINGS_CONF}${reset}\n"
    if command -v snapper &>/dev/null && ! pacman -Qq snap-pac &>/dev/null; then
        if [[ ! -f "$CONFIG_DIR/.snapper_warned" ]]; then
            echo -e "${yellow}Notice: Snapper detected, but ${white}snap-pac${yellow} is not installed.${reset}"
            echo -e "${gray}We highly recommend installing 'snap-pac' to automatically create${reset}"
            echo -e "${gray}Btrfs pre/post snapshots on every update: ${white}sudo pacman -S snap-pac${reset}\n"
            touch "$CONFIG_DIR/.snapper_warned" 2>/dev/null
        fi
    fi
    echo -e "${dim}Checking for configuration updates...${reset}"
    ensure_asu_base_configs "true"
else
    ensure_asu_base_configs "false" >/dev/null 2>&1 || true
fi

if [[ ! -f "$SETTINGS_CONF" && -f "$SETTINGS_DEFAULT" ]]; then
    cp "$SETTINGS_DEFAULT" "$SETTINGS_CONF"
    chmod 600 "$SETTINGS_CONF"
    echo -e "${dim}Created default $SETTINGS_CONF${reset}"

    echo -e "\n${blue}${bold}[First Run Setup]${reset}"
    setup_ans="Y"
    daemon_ans="N"
    clean_ans="N"
    log_ans="N"

    prompt_user "Allow mirror ranking option before update (with confirmation)?" "Y/n" setup_ans
    prompt_user "Enable background update checker?" "y/N" daemon_ans
    prompt_user "Enable automatic post-update system cleanup?" "y/N" clean_ans
    prompt_user "Enable update log generation in ~/.config/arch-smart-update/logs/?" "y/N" log_ans

    echo ""

    if [[ "$setup_ans" =~ ^[Nn]$ ]]; then
        sed -i 's/^PROMPT_MIRROR_REFRESH=.*/PROMPT_MIRROR_REFRESH=false/' "$SETTINGS_CONF"
        echo -e "${dim}Mirror ranking prompt disabled.${reset}"
    else
        sed -i 's/^PROMPT_MIRROR_REFRESH=.*/PROMPT_MIRROR_REFRESH=true/' "$SETTINGS_CONF"
        echo -e "${dim}Mirror ranking prompt enabled.${reset}"
    fi

    if [[ "$daemon_ans" =~ ^[Yy]$ ]]; then
        if write_bg_check_setting "$SETTINGS_CONF" "true"; then
            echo -e "${dim}Background checker enabled.${reset}"
            if ! pacman -Q libnotify >/dev/null 2>&1; then
                echo -e "${yellow}Warning: The ${red}libnotify${yellow} package is not installed. Please install it for notifications to work.${reset}"
            fi
        else
            echo -e "${red}Warning: Failed to update background checker setting in configuration file.${reset}"
        fi
    else
        if write_bg_check_setting "$SETTINGS_CONF" "false"; then
            echo -e "${dim}Background checker disabled.${reset}"
        else
            echo -e "${red}Warning: Failed to update background checker setting in configuration file.${reset}"
        fi
    fi

    if [[ "$clean_ans" =~ ^[Yy]$ ]]; then
        sed -i 's/^ENABLE_POST_CLEANUP=.*/ENABLE_POST_CLEANUP=true/' "$SETTINGS_CONF"
        echo -e "${dim}Post-update cleanup enabled.${reset}"
    else
        sed -i 's/^ENABLE_POST_CLEANUP=.*/ENABLE_POST_CLEANUP=false/' "$SETTINGS_CONF"
        echo -e "${dim}Post-update cleanup disabled.${reset}"
    fi

    if [[ "$log_ans" =~ ^[Yy]$ ]]; then
        sed -i 's/^GENERATE_LOGS=.*/GENERATE_LOGS=true/' "$SETTINGS_CONF"
        echo -e "${dim}Log generation enabled.${reset}"
    else
        sed -i 's/^GENERATE_LOGS=.*/GENERATE_LOGS=false/' "$SETTINGS_CONF"
        echo -e "${dim}Log generation disabled.${reset}"
    fi

    echo ""

    chmod 600 "$SETTINGS_CONF" 2>/dev/null || true
fi

SETTINGS_VALIDATION_FAILED=false
if ! validate_user_conf "$SETTINGS_CONF" "settings.conf"; then
    echo -e "${yellow}Settings disabled due to security check failure.${reset}"
    SETTINGS_CONF=""
    SETTINGS_VALIDATION_FAILED=true
fi

if ! validate_user_conf "$PKG_CONF" "packages.conf"; then
    echo -e "${yellow}Packages config disabled due to security check failure.${reset}"
    PKG_CONF=""
fi

if [[ "$DAEMON_MODE" == true && "${SETTINGS_VALIDATION_FAILED:-false}" == "true" ]]; then
    log_step "Error: settings.conf failed verification. Aborting."
    if command -v notify-send >/dev/null 2>&1; then
        notif_icon="dialog-error"
        [[ -f "$ICON_PATH" ]] && notif_icon="$ICON_PATH"
        launch_detached notify-send -a "Arch Smart Update" -u critical -i "$notif_icon" "Security Alert: Background Monitor Paused" "Unverified changes detected in settings.conf. Please run this script manually in a terminal to authorize them."
    fi
    exit 1
fi

if [[ -n "$SETTINGS_CONF" && -f "$SETTINGS_CONF" ]]; then
    load_daemon_params "$SETTINGS_CONF"
fi

if [[ "$DAEMON_MODE" == true ]]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

    if command -v systemctl >/dev/null 2>&1; then
        while IFS='=' read -r key val; do
            if [[ -n "$val" && -z "${!key:-}" ]]; then
                export "$key=$val"
            fi
        done < <(systemctl --user show-environment 2>/dev/null | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|XAUTHORITY|XDG_DATA_DIRS|XDG_CONFIG_DIRS)=')
    fi

    detect_display_session

    if [[ -z "${DETECTED_WAYLAND:-}" && -z "${DETECTED_DISPLAY:-}" ]]; then
        target_pids=$(pgrep -i -u "$EUID" -x "niri|sway|hyprland|wayfire|river|kwin_wayland|gnome-shell|labwc|dwl|mako|dunst|swaync|fnott|waybar" 2>/dev/null | sort -rn || true)
        all_pids=$(pgrep -u "$EUID" 2>/dev/null | sort -rn || true)
        seen_pids=""
        fallback_dbus=""
        fallback_data=""
        fallback_config=""

        for pid in $target_pids $all_pids; do
            [[ -z "$pid" || " $seen_pids " == *" $pid "* ]] && continue
            seen_pids="$seen_pids $pid"

            if [[ -r "/proc/$pid/environ" ]]; then
                p_disp=""
                p_wayland=""
                p_xauth=""
                p_desktop=""
                p_session_type=""
                p_dbus=""
                p_data=""
                p_config=""

                while IFS='=' read -r -d '' env_key env_val; do
                    case "$env_key" in
                        DISPLAY) p_disp="$env_val" ;;
                        WAYLAND_DISPLAY) p_wayland="$env_val" ;;
                        XAUTHORITY) p_xauth="$env_val" ;;
                        XDG_CURRENT_DESKTOP) p_desktop="$env_val" ;;
                        XDG_SESSION_TYPE) p_session_type="$env_val" ;;
                        DBUS_SESSION_BUS_ADDRESS) p_dbus="$env_val" ;;
                        XDG_DATA_DIRS) p_data="$env_val" ;;
                        XDG_CONFIG_DIRS) p_config="$env_val" ;;
                    esac
                done < <(cat "/proc/$pid/environ" 2>/dev/null)

                if [[ -n "$p_wayland" || -n "$p_disp" ]]; then
                    [[ -n "$p_dbus" ]] && export DBUS_SESSION_BUS_ADDRESS="$p_dbus"
                    [[ -n "$p_data" ]] && export XDG_DATA_DIRS="$p_data"
                    [[ -n "$p_config" ]] && export XDG_CONFIG_DIRS="$p_config"
                    [[ -n "$p_disp" ]] && export DISPLAY="$p_disp"
                    [[ -n "$p_wayland" ]] && export WAYLAND_DISPLAY="$p_wayland"
                    [[ -n "$p_xauth" ]] && export XAUTHORITY="$p_xauth"
                    [[ -n "$p_desktop" ]] && export XDG_CURRENT_DESKTOP="$p_desktop"
                    [[ -n "$p_session_type" ]] && export XDG_SESSION_TYPE="$p_session_type"
                    break
                elif [[ -z "$fallback_dbus" && -n "$p_dbus" ]]; then
                    fallback_dbus="$p_dbus"
                    fallback_data="$p_data"
                    fallback_config="$p_config"
                fi
            fi
        done

        if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" && -n "$fallback_dbus" ]]; then
            export DBUS_SESSION_BUS_ADDRESS="$fallback_dbus"
            [[ -n "$fallback_data" ]] && export XDG_DATA_DIRS="$fallback_data"
            [[ -n "$fallback_config" ]] && export XDG_CONFIG_DIRS="$fallback_config"
        fi

        detect_display_session
    fi

    if [[ -z "${XAUTHORITY:-}" && -f "${USER_HOME:-}/.Xauthority" ]]; then
        export XAUTHORITY="${USER_HOME}/.Xauthority"
    fi

    if [[ -n "${DETECTED_WAYLAND:-}" ]]; then
        export WAYLAND_DISPLAY="$DETECTED_WAYLAND"
    else
        unset WAYLAND_DISPLAY
    fi
    if [[ -n "${DETECTED_DISPLAY:-}" ]]; then
        export DISPLAY="$DETECTED_DISPLAY"
    else
        unset DISPLAY
    fi

    NEXT_CHECK_FILE="$CONFIG_DIR/next_check.conf"
    if [[ "${1:-}" == "--daemon" ]] && [[ -f "$NEXT_CHECK_FILE" ]]; then
        NEXT_TS=0
        raw_next=""
        existing_tag=""
        file_mtime=0
        boot_ts=0
        if acquire_state_lock "x"; then
            if [[ -f "$NEXT_CHECK_FILE" ]]; then
                file_mtime=$(stat -c %Y "$NEXT_CHECK_FILE" 2>/dev/null || echo 0)
                boot_ts=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null || echo 0)
                raw_next=$(cat "$NEXT_CHECK_FILE" 2>/dev/null || echo 0)
                NEXT_TS="${raw_next%%|*}"
                NEXT_TS="${NEXT_TS#"${NEXT_TS%%[![:space:]]*}"}"
                NEXT_TS="${NEXT_TS%"${NEXT_TS##*[![:space:]]}"}"
                if [[ "$raw_next" == *"|"* ]]; then
                    existing_tag="${raw_next#*|}"
                    existing_tag="${existing_tag#"${existing_tag%%[![:space:]]*}"}"
                    existing_tag="${existing_tag%"${existing_tag##*[![:space:]]}"}"
                fi
                if (( file_mtime > 0 && boot_ts > 0 && file_mtime < boot_ts )) && [[ "$existing_tag" != "silence" ]]; then
                    rm -f "$NEXT_CHECK_FILE"
                    NEXT_TS=0
                fi
            fi
            release_state_lock
        fi
        NOW_TS=$(date +%s)
        if [[ "$NEXT_TS" =~ ^[0-9]+$ ]] && (( NEXT_TS > NOW_TS + 30 )); then
            target_time=$(date -d "@$NEXT_TS" +%H:%M 2>/dev/null || echo "00:00")
            log_step "Scheduled check is in the future ($target_time). Woke up early. Exiting."
            exit 0
        fi
    fi
fi

if [[ -n "$SETTINGS_CONF" && -f "$SETTINGS_CONF" && -f "$SETTINGS_DEFAULT" ]]; then
    has_new_features=false
    while read -r key; do
        if [[ -n "$key" ]] && ! grep -qE "^[[:space:]]*(#)?[[:space:]]*${key}[[:space:]]*(\+)?=" "$SETTINGS_CONF"; then
            has_new_features=true
            break
        fi
    done < <(grep -E '^[A-Za-z0-9_]+[[:space:]]*(\+)?=' "$SETTINGS_DEFAULT" | cut -d= -f1 | sed -E 's/\+//g; s/[[:space:]]+$//' | tr -d '\r')

    if [[ "$has_new_features" == "true" && "$DAEMON_MODE" == "false" ]]; then
        echo -e "${yellow}Notice: Your settings.conf may be missing newer configuration options present in settings.default.conf.${reset}"
        echo -e "${dim}It is recommended to run this script with ${white}--reconfigure${dim} to regenerate your settings and configure new options.${reset}\n"
    fi
fi

if [[ -f "$PKG_CONF" ]]; then
    mapfile -t NUCLEAR_PKGS < <(parse_bash_array "$PKG_CONF" "NUCLEAR_PKGS")
    mapfile -t CRITICAL_PKGS < <(parse_bash_array "$PKG_CONF" "CRITICAL_PKGS")
    mapfile -t FEATURE_PKGS < <(parse_bash_array "$PKG_CONF" "FEATURE_PKGS")
else
    echo -e "${red}Could not load packages.conf. Using built-in basic fallbacks.${reset}"
fi

if [[ -n "$SETTINGS_CONF" && -f "$SETTINGS_CONF" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line%%[[:space:]]#*}"
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val#"${val%%[![:space:]]*}"}"
            val="${val%"${val##*[![:space:]]}"}"
            if [[ "$val" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ || "$val" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
                val="${BASH_REMATCH[1]}"
            else
                val="${val%%#*}"
                val="${val%"${val##*[![:space:]]}"}"
            fi
            case "$key" in
                AUR_HELPER_OVERRIDE|PROMPT_MIRROR_REFRESH|MAX_BACKUP_COPIES|CHECK_INTERVAL|START_DELAY|ENABLE_BACKGROUND_CHECK|T_MIRROR_H|T_FEAT_H|T_CRIT_H|T_DE_H|T_NUKE_H|IGNORE_PATCH_TIMERS|GENERATE_LOGS|MAX_LOG_NUMBERS|CUSTOM_RATE_MIRRORS_CMD|CUSTOM_REFLECTOR_CMD|ENABLE_POST_CLEANUP|ENABLE_AUR_REBUILD_CHECK|MIN_DISK_SPACE_MB|MIN_BTRFS_SPACE_MB|SILENCE_UPDATES|NOTIFICATION_TIMEOUT)
                    declare -g "$key=$val"
                    ;;
            esac
        fi
    done < "$SETTINGS_CONF"

    mapfile -t USER_NUKE < <(parse_bash_array "$SETTINGS_CONF" "USER_NUCLEAR_PKGS")
    [[ ${#USER_NUKE[@]} -gt 0 ]] && NUCLEAR_PKGS+=("${USER_NUKE[@]}")

    mapfile -t USER_CRIT < <(parse_bash_array "$SETTINGS_CONF" "USER_CRITICAL_PKGS")
    [[ ${#USER_CRIT[@]} -gt 0 ]] && CRITICAL_PKGS+=("${USER_CRIT[@]}")

    mapfile -t USER_FEAT < <(parse_bash_array "$SETTINGS_CONF" "USER_FEATURE_PKGS")
    [[ ${#USER_FEAT[@]} -gt 0 ]] && FEATURE_PKGS+=("${USER_FEAT[@]}")

    mapfile -t CUSTOM_CMDS < <(parse_bash_array "$SETTINGS_CONF" "CUSTOM_CMDS")

    [[ "$T_MIRROR_H" =~ ^[0-9]+$ ]] || T_MIRROR_H="$DEFAULT_T_MIRROR_H"
    [[ "$T_FEAT_H" =~ ^[0-9]+$ ]] || T_FEAT_H="$DEFAULT_T_FEAT_H"
    [[ "$T_CRIT_H" =~ ^[0-9]+$ ]] || T_CRIT_H="$DEFAULT_T_CRIT_H"
    [[ "$T_DE_H" =~ ^[0-9]+$ ]] || T_DE_H="$DEFAULT_T_DE_H"
    [[ "$T_NUKE_H" =~ ^[0-9]+$ ]] || T_NUKE_H="$DEFAULT_T_NUKE_H"
    [[ "$MIN_DISK_SPACE_MB" =~ ^[0-9]+$ ]] || MIN_DISK_SPACE_MB="$DEFAULT_MIN_DISK_SPACE_MB"
    [[ "$MIN_BTRFS_SPACE_MB" =~ ^[0-9]+$ ]] || MIN_BTRFS_SPACE_MB="$DEFAULT_MIN_BTRFS_SPACE_MB"
    [[ -z "${CHECK_INTERVAL:-}" ]] && CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    [[ -z "${START_DELAY:-}" ]] && START_DELAY="$DEFAULT_START_DELAY"
    [[ -z "${SILENCE_UPDATES:-}" ]] && SILENCE_UPDATES="$DEFAULT_SILENCE_UPDATES"
    parse_timeout_to_ms "${NOTIFICATION_TIMEOUT:-$DEFAULT_NOTIFICATION_TIMEOUT}" NOTIFICATION_TIMEOUT "$DEFAULT_NOTIFICATION_TIMEOUT"
fi

declare -A NUKE_MAP
for pkg in "${NUCLEAR_PKGS[@]+"${NUCLEAR_PKGS[@]}"}"; do NUKE_MAP["$pkg"]=1; done

declare -A CRIT_MAP
for pkg in "${CRITICAL_PKGS[@]+"${CRITICAL_PKGS[@]}"}"; do CRIT_MAP["$pkg"]=1; done

declare -A FEAT_MAP
for pkg in "${FEATURE_PKGS[@]+"${FEATURE_PKGS[@]}"}"; do FEAT_MAP["$pkg"]=1; done

if [[ "${GENERATE_LOGS,,}" == "true" ]]; then
    LOG_DIR="$CONFIG_DIR/logs"
    mkdir -p "$LOG_DIR"

    if [[ "$DAEMON_MODE" == true ]]; then
        log_prefix="daemon_log"
    else
        log_prefix="log"
    fi

    latest_log=$(find "$LOG_DIR" -maxdepth 1 -name "${log_prefix}_*" 2>/dev/null | grep -E "/${log_prefix}_[0-9]+$" | sort -V | tail -n 1 || true)
    if [[ -z "$latest_log" ]]; then
        next_num=1
    else
        latest_num="${latest_log##*_}"
        next_num=$(( 10#$latest_num + 1 ))
    fi

    printf -v log_name "${log_prefix}_%06d" "$next_num"
    LOG_FILE="$LOG_DIR/$log_name"

    {
        echo "======================================================================="
        echo "Arch Smart Update Log"
        echo "Time: $(date +'%Y-%m-%d %H:%M:%S')"
        echo "Mode: $(if $DAEMON_MODE; then echo "Daemon (Background)"; else echo "Interactive"; fi)"
        echo "======================================================================="
    } > "$LOG_FILE"

    if $DAEMON_MODE; then
        exec >> "$LOG_FILE" 2>&1
    else
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi

    SANITIZED_MAX_LOGS=${MAX_LOG_NUMBERS:-$DEFAULT_MAX_LOG_NUMBERS}
    [[ "$SANITIZED_MAX_LOGS" =~ ^[0-9]+$ ]] || SANITIZED_MAX_LOGS="$DEFAULT_MAX_LOG_NUMBERS"

    mapfile -t existing_logs < <(find "$LOG_DIR" -maxdepth 1 -name "${log_prefix}_*" 2>/dev/null | grep -E "/${log_prefix}_[0-9]+$" | sort -V)
    if (( ${#existing_logs[@]} > SANITIZED_MAX_LOGS )); then
        remove_count=$(( ${#existing_logs[@]} - SANITIZED_MAX_LOGS ))
        for (( i=0; i<remove_count; i++ )); do
            rm -f "${existing_logs[$i]}"
        done
    fi
fi

sync_daemon_state

# --- 5. Temporary Files ---
create_temp_file OUTPUT_FILE "asu_out"
create_temp_file SYNC_LOG "asu_sync"
create_temp_file REFL_LOG "asu_refl"

create_temp_dir CHECK_DB "checkupdates-db"
chmod 755 "$CHECK_DB"

# --- 6. Helper Functions ---
get_update_type() {
    local old="${1:-}"
    local new="${2:-}"
    local level="${3:-3}"

    local v_old="${old#*:}"
    local v_new="${new#*:}"

    if [[ "$v_new" == "latest-commit" ]]; then
        echo "MINOR"
        return
    fi

    if [[ "$old" == *":"* || "$new" == *":"* ]]; then
        local e_old="0"
        local e_new="0"
        [[ "$old" == *":"* ]] && e_old="${old%%:*}"
        [[ "$new" == *":"* ]] && e_new="${new%%:*}"
        if [[ "$e_old" != "$e_new" ]]; then
            echo "EPOCH"
            return
        fi
    fi

    local up_old="${v_old%-*}"
    local up_new="${v_new%-*}"

    local -a segs_old segs_new
    IFS='.-_' read -ra segs_old <<< "$up_old" || true
    IFS='.-_' read -ra segs_new <<< "$up_new" || true

    local len="${#segs_new[@]}"
    local i
    for (( i=0; i<len; i++ )); do
        local s_old=0
        if (( i < ${#segs_old[@]} )); then
            s_old="${segs_old[$i]}"
        fi
        local s_new=0
        if (( i < ${#segs_new[@]} )); then
            s_new="${segs_new[$i]}"
        fi

        if [[ "$s_new" != "$s_old" ]]; then
            if [[ "$s_new" =~ ^[0-9]+$ ]]; then
                if [[ "$s_new" =~ ^[0-9]{4}$ ]] && (( 10#$s_new >= 2020 && 10#$s_new <= 2100 )); then
                    echo "CALVER"
                    return
                elif [[ "$s_new" =~ ^[0-9]{8}$ ]] && (( 10#$s_new >= 20200000 && 10#$s_new <= 21001231 )); then
                    echo "CALVER"
                    return
                fi
            fi

            if (( i == 0 )); then
                echo "MAJOR"
                return
            elif (( i == 1 )); then
                echo "MINOR"
                return
            else
                if (( level == 0 )); then
                    echo "MINOR"
                else
                    echo "Patch"
                fi
                return
            fi
        fi
    done

    echo "Patch"
}

get_type_color() {
    case "${1:-}" in
        "MAJOR") echo "$red$bold" ;;
        "CALVER") echo "$blue$bold" ;;
        "MINOR") echo "$cyan" ;;
        "EPOCH") echo "$magenta" ;;
        *) echo "$gray" ;;
    esac
}

AUR_RPC_CACHE=""
AUR_RPC_CACHE_SET=false

fetch_aur_updates_rpc() {
    if [[ "${AUR_RPC_CACHE_SET:-false}" == "true" ]]; then
        return 0
    fi
    AUR_RPC_CACHE=$(python3 -c '
import urllib.request, json, sys, subprocess, urllib.parse
try:
    res = subprocess.run(["pacman", "-Qm"], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(0)
    local_pkgs = {line.split()[0]: line.split()[1] for line in res.stdout.strip().splitlines() if len(line.split()) >= 2}
    if not local_pkgs:
        sys.exit(0)
    names = list(local_pkgs.keys())
    aur_data = []
    for i in range(0, len(names), 100):
        chunk = names[i:i+100]
        args = "&".join(f"arg[]={urllib.parse.quote(n)}" for n in chunk)
        req = urllib.request.Request(f"https://aur.archlinux.org/rpc/?v=5&type=info&{args}", headers={"User-Agent": "ArchSmartUpdate/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("type") != "error":
                aur_data.extend(data.get("results", []))
    for item in aur_data:
        name, new_ver = item.get("Name"), item.get("Version")
        old_ver = local_pkgs.get(name)
        if old_ver and new_ver:
            vc = subprocess.run(["vercmp", new_ver, old_ver], capture_output=True, text=True)
            if vc.returncode == 0 and int(vc.stdout.strip() or 0) > 0:
                print(f"{name} {old_ver} -> {new_ver}")
except Exception:
    pass
' 2>/dev/null || true)
    AUR_RPC_CACHE_SET=true
}

check_arch_news() {
    log_step "Starting Arch News check (Python)..."
    echo -ne "${gray}Checking Arch News...${reset}"

    local news_ts now_time diff_hours
    if news_ts=$(python3 <<'EOF' 2>/dev/null
import sys, urllib.request, xml.etree.ElementTree as ET, email.utils
try:
    req = urllib.request.Request('https://archlinux.org/feeds/news/', headers={'User-Agent': 'ArchSmartUpdate/1.0'})
    with urllib.request.urlopen(req, timeout=5) as resp:
        root = ET.fromstring(resp.read())
    item = root.find('./channel/item')
    if item is not None:
        pubDate = item.find('pubDate').text
        parsed = email.utils.parsedate_tz(pubDate)
        print(int(email.utils.mktime_tz(parsed)))
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
EOF
    ) && [[ "$news_ts" =~ ^[0-9]+$ ]]; then
        now_time=$(date +%s)
        diff_hours=$(( (now_time - news_ts) / 3600 ))
        (( diff_hours < 0 )) && diff_hours=0

        if (( diff_hours < 336 )); then
            local NEWS_CACHE="$CONFIG_DIR/news.cache"
            local OLD_NEWS_TS=0
            local NEWS_SILENCED=false

            if [[ -f "$NEWS_CACHE" ]]; then
                local cache_val
                cache_val=$(cat "$NEWS_CACHE" 2>/dev/null)
                OLD_NEWS_TS="${cache_val%%|*}"

                if [[ ! "$OLD_NEWS_TS" =~ ^[0-9]+$ ]]; then
                    OLD_NEWS_TS=0
                fi

                if [[ "$news_ts" == "$OLD_NEWS_TS" ]] && [[ "$cache_val" == *"|silenced" ]]; then
                    NEWS_SILENCED=true
                fi
            fi

            if [[ "$DAEMON_MODE" == false ]]; then
                if [[ "$NEWS_SILENCED" == "true" ]]; then
                    echo -e "\r\033[2K${green}Fresh Arch News detected ($diff_hours h ago), but already acknowledged/silenced.${reset}"
                else
                    echo -e "\r\033[2K${red}${bold}Fresh Arch News detected ($diff_hours h ago)!${reset}"
                    echo -e "${red}Check https://archlinux.org/ before updating.${reset}"
                fi
            fi

            if [[ "$DAEMON_MODE" == true ]]; then
                local first_run_this_boot=false
                
                local session_dir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
                if [[ ! -d "$session_dir" || ! -w "$session_dir" ]]; then
                    session_dir="/tmp"
                fi
                local BOOT_SESSION_FILE="${session_dir}/asu_boot_session_${EUID}.active"

                if [[ ! -f "$BOOT_SESSION_FILE" ]]; then
                    first_run_this_boot=true
                fi

                local should_notify=false
                if (( news_ts != OLD_NEWS_TS )); then
                    should_notify=true
                elif [[ "$NEWS_SILENCED" == "false" ]] && [[ "$first_run_this_boot" == "true" ]]; then
                    should_notify=true
                fi

                touch "$BOOT_SESSION_FILE" 2>/dev/null

                if [[ "$should_notify" == "true" ]]; then
                    echo "$news_ts" > "$NEWS_CACHE"
                    if command -v notify-send >/dev/null 2>&1; then
                        local notif_icon="dialog-warning"
                        [[ -f "$ICON_PATH" ]] && notif_icon="$ICON_PATH"
                        local target_script
                        target_script="$(realpath "$(command -v "${BASH_SOURCE:-$0}" 2>/dev/null || echo "${BASH_SOURCE:-$0}")")"

                        launch_detached "$target_script" --news-worker "$notif_icon" "$diff_hours" "$news_ts"
                    fi
                fi
            fi
        else
            echo -e "\r\033[2K${green}No fresh Arch News (last: ${diff_hours}h ago).${reset}"
        fi
    else
        echo -e "\r\033[2K${dim}Could not check Arch News (Connection or XML error).${reset}"
    fi
}

backup_pacman_db() {
    local BACKUP_DIR="/var/lib/pacman/backup"
    local KEEP_COPIES=${MAX_BACKUP_COPIES:-$DEFAULT_MAX_BACKUP_COPIES}
    [[ "$KEEP_COPIES" =~ ^[0-9]+$ ]] || KEEP_COPIES="$DEFAULT_MAX_BACKUP_COPIES"
    log_step "Creating Pacman DB backup..."
    if [[ ! -d "$BACKUP_DIR" ]]; then
        sudo mkdir -p "$BACKUP_DIR"
    fi
    local BACKUP_DATE
    BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
    local BACKUP_FILE="$BACKUP_DIR/pacman_database_$BACKUP_DATE.tar.zst"
    if sudo tar --xattrs --warning=no-file-changed -I 'zstd -3' -cf "$BACKUP_FILE" -C /var/lib/pacman/ local; then
        echo -e "${green}Backup created: ${white}$(basename "$BACKUP_FILE")${reset}"
        sudo bash -c "find \"$BACKUP_DIR\" -maxdepth 1 -type f \( -name 'pacman_database_*.tar.zst' -o -name 'pacman_database_*.tar.gz' \) -printf '%T@\t%p\0' 2>/dev/null | sort -z -rn | tail -z -n +$((KEEP_COPIES + 1)) | cut -z -f2- | xargs -0 -r rm -f --"
    else
        echo -e "${red}Failed to create backup!${reset}"
        echo -ne "${yellow}Continue anyway? [y/N]: ${reset}"
        local cont
        read -r cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

LAST_TASK_OUTPUT=""

execute_update_task() {
    local cmd="${1:-}"
    LAST_TASK_OUTPUT=""

    local safe_tmp_dir="${XDG_RUNTIME_DIR:-$CONFIG_DIR}"
    if [[ ! -d "$safe_tmp_dir" || ! -w "$safe_tmp_dir" ]]; then
        safe_tmp_dir="/tmp"
    fi

    local task_capture=""
    task_capture=$(mktemp "$safe_tmp_dir/asu_capture.XXXXXX" 2>/dev/null || mktemp "/tmp/asu_capture.XXXXXX")
    CURRENT_TASK_CAPTURE="$task_capture"
    local ret=0

    local has_custom_tty=false
    if [[ "${ASU_TTY_OUT:-}" =~ ^[0-9]+$ ]] && [[ "${ASU_TTY_ERR:-}" =~ ^[0-9]+$ ]]; then
        if { true >&"$ASU_TTY_OUT"; } 2>/dev/null && { true >&"$ASU_TTY_ERR"; } 2>/dev/null; then
            has_custom_tty=true
        fi
    fi

    local wrapper="$cmd"
    local first_word=""
    if [[ "$cmd" =~ ^[[:space:]]*([^[:space:]]+) ]]; then
        first_word="${BASH_REMATCH[1]}"
    fi
    if [[ "$first_word" =~ ^(yay|paru|pikaur|trizen|pacaur|pakku|aura|rua|topgrade|eos-update|cachy-update|arch-update)$ ]]; then
        wrapper="sudo -v && $cmd"
    fi

    local executed_with_script=false
    if $has_custom_tty && [ -t "$ASU_TTY_OUT" ] && [ -t 0 ] && command -v script >/dev/null 2>&1; then
        if env SHELL=/bin/bash script -f -q -e -c "true" /dev/null >/dev/null 2>&1; then
            local tmp_log=""
            tmp_log=$(mktemp "$safe_tmp_dir/asu_task.XXXXXX" 2>/dev/null || mktemp "/tmp/asu_task.XXXXXX")
            CURRENT_TMP_LOG="$tmp_log"

            env SHELL=/bin/bash script -f -q -e -c "$wrapper" "$tmp_log" <&0 1>&$ASU_TTY_OUT 2>&$ASU_TTY_ERR
            ret=$?

            if [ -f "$tmp_log" ]; then
                env PYTHONIOENCODING=utf-8 python3 - "$tmp_log" > "$task_capture" 2>/dev/null <<'EOF'
import sys, re

ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace", newline="\n") as f:
        for line in f:
            line_clean = ansi_escape.sub("", line.rstrip("\r\n"))
            if "\r" in line_clean:
                parts = [p.strip() for p in line_clean.split("\r") if p.strip()]
                if parts:
                    print(parts[-1])
            else:
                print(line_clean)
except BaseException:
    sys.exit(0)
EOF
                rm -f "$tmp_log" 2>/dev/null || true
            fi
            CURRENT_TMP_LOG=""
            executed_with_script=true
        fi
    fi

    if [[ "$executed_with_script" == "false" ]]; then
        if $has_custom_tty; then
            /bin/bash -c "$wrapper" 2>&1 | tee "$task_capture" 1>&$ASU_TTY_OUT 2>&$ASU_TTY_ERR
            ret=${PIPESTATUS[0]}
        else
            /bin/bash -c "$wrapper" 2>&1 | tee "$task_capture"
            ret=${PIPESTATUS[0]}
        fi
    fi

    if [ -f "$task_capture" ]; then
        LAST_TASK_OUTPUT=$(tail -n 300 "$task_capture" 2>/dev/null | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B\([B0]//g' || true)
        if [[ "${GENERATE_LOGS,,}" == "true" && -n "${LOG_FILE:-}" ]]; then
            cat "$task_capture" >> "$LOG_FILE" 2>/dev/null || true
        fi
        rm -f "$task_capture" 2>/dev/null || true
    fi
    CURRENT_TASK_CAPTURE=""

    return "$ret"
}

check_reboot_needed() {
    local critical_pkgs="^(linux|nvidia|systemd|wayland|dbus|mesa|glibc)(-[a-z0-9-]+)?$|ucode$"
    local log_file
    log_file=$(pacman-conf LogFile 2>/dev/null)
    : "${log_file:=/var/log/pacman.log}"
    
    if [[ ! -r "$log_file" ]] && ! sudo test -r "$log_file" 2>/dev/null; then
        return 0
    fi
    
    local boot_ts
    boot_ts=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null)
    [[ -z "$boot_ts" || ! "$boot_ts" =~ ^[0-9]+$ ]] && return 0
    
    local read_cmd=(tail -n 4000 "$log_file")
    if [[ ! -r "$log_file" ]]; then
        read_cmd=(sudo tail -n 4000 "$log_file")
    fi
    
    local updated_pkgs
    updated_pkgs=$("${read_cmd[@]}" 2>/dev/null | awk -v boot_ts="$boot_ts" -v crit="$critical_pkgs" '
        / upgraded | installed | downgraded / {
            idx1 = index($0, "[")
            idx2 = index($0, "]")
            if (idx1 == 1 && idx2 > idx1) {
                ts_str = substr($0, idx1 + 1, idx2 - idx1 - 1)
                gsub(/[-T:+]/, " ", ts_str)
                split(ts_str, d, " ")
                if (!d[6]) d[6] = "00"
                spec = sprintf("%04d %02d %02d %02d %02d %02d", d[1], d[2], d[3], d[4], d[5], d[6])
                epoch = mktime(spec)
                if (epoch > boot_ts) {
                    pkg_name = ""
                    for (i = 1; i <= NF; i++) {
                        if ($i == "upgraded" || $i == "installed" || $i == "downgraded") {
                            pkg_name = $(i + 1)
                            break
                        }
                    }
                    if (pkg_name != "" && pkg_name ~ crit) {
                        pkgs[pkg_name] = 1
                    }
                }
            }
        }
        END {
            out = ""
            for (p in pkgs) {
                out = out p " "
            }
            if (out != "") {
                sub(/ $/, "", out)
                print out
            }
        }
    ')
    if [[ -n "$updated_pkgs" ]]; then
        echo -e "\n${yellow}${bold}System reboot recommended!${reset}"
        echo -e "${dim}The following critical components were upgraded during this session:${reset}"
        echo -e "${white}$updated_pkgs${reset}\n"
    fi
}

check_disk_space() {
    log_step "Checking available disk space..."
    local cache_dir
    cache_dir=$(pacman-conf CacheDir 2>/dev/null | head -n 1)
    [[ -z "$cache_dir" ]] && cache_dir="/var/cache/pacman/pkg"
    cache_dir="${cache_dir%/}"
    
    local resolved_cache_dir="$cache_dir"
    local depth_guard=0
    while [[ ! -d "$resolved_cache_dir" && "$resolved_cache_dir" != "/" && "$resolved_cache_dir" == *"/"* ]] && (( depth_guard < 32 )); do
        resolved_cache_dir=$(dirname "$resolved_cache_dir")
        ((depth_guard++))
    done
    [[ ! -d "$resolved_cache_dir" ]] && resolved_cache_dir="/"

    local root_free_kb=0 cache_free_kb=0 boot_free_kb=0
    root_free_kb=$(env LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$root_free_kb" =~ ^[0-9]+$ ]] || root_free_kb=0

    cache_free_kb=$(env LC_ALL=C df -Pk "$resolved_cache_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$cache_free_kb" =~ ^[0-9]+$ ]] || cache_free_kb=0

    local is_btrfs=false has_snaps=false
    local root_fs cache_fs
    root_fs=$(env LC_ALL=C df -PT / 2>/dev/null | awk 'NR==2 {print $2}')
    cache_fs=$(env LC_ALL=C df -PT "$resolved_cache_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    [[ "${root_fs,,}" == "btrfs" || "${cache_fs,,}" == "btrfs" ]] && is_btrfs=true

    if command -v snapper >/dev/null 2>&1 || command -v timeshift >/dev/null 2>&1 || pacman -Qq snap-pac >/dev/null 2>&1; then
        has_snaps=true
    fi

    local min_space_mb=${MIN_DISK_SPACE_MB:-$DEFAULT_MIN_DISK_SPACE_MB}
    if [[ "$is_btrfs" == "true" || "$has_snaps" == "true" ]]; then
        min_space_mb=${MIN_BTRFS_SPACE_MB:-$DEFAULT_MIN_BTRFS_SPACE_MB}
    fi

    if [[ -n "${total_download_size:-}" ]]; then
        local dl_num dl_unit est_mb=0
        read -r dl_num dl_unit <<< "$total_download_size"
        if [[ "$dl_num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            case "${dl_unit^^}" in
                GIB|GB) est_mb=$(env LC_ALL=C awk -v n="$dl_num" 'BEGIN { printf "%d", n * 1024 * 2.5 }' 2>/dev/null || echo 0) ;;
                MIB|MB) est_mb=$(env LC_ALL=C awk -v n="$dl_num" 'BEGIN { printf "%d", n * 2.5 }' 2>/dev/null || echo 0) ;;
            esac
            [[ "$est_mb" =~ ^[0-9]+$ ]] || est_mb=0
            if (( est_mb > min_space_mb )); then
                min_space_mb=$est_mb
            fi
        fi
    fi

    local min_space_kb=$(( min_space_mb * 1024 ))
    local root_free_mb=$(( root_free_kb / 1024 ))
    local cache_free_mb=$(( cache_free_kb / 1024 ))

    local space_failed=false
    local fail_msg=""

    if (( root_free_kb < min_space_kb )); then
        space_failed=true
        fail_msg="Root partition (/) has only ${root_free_mb} MB free space."
    elif (( cache_free_kb < min_space_kb )); then
        space_failed=true
        fail_msg="Package cache directory (${cache_dir}) has only ${cache_free_mb} MB free space."
    fi

    if [[ "$space_failed" == "true" ]]; then
        echo -e "\n${bg_nuke} LOW DISK SPACE WARNING ${reset}"
        echo -e "${red}${fail_msg}${reset}"
        if [[ "$is_btrfs" == "true" || "$has_snaps" == "true" ]]; then
            echo -e "${yellow}Btrfs/Snapshots detected: updates require at least ${white}${min_space_mb} MB${yellow} to prevent transaction freeze.${reset}"
        else
            echo -e "${yellow}Recommended minimum free space is ${white}${min_space_mb} MB${yellow}.${reset}"
        fi

        if $DAEMON_MODE; then
            log_step "Error: Insufficient disk space for update in background mode."
            return 1
        fi

        echo -ne "${white}Continue update despite low disk space? [y/N]: ${reset}"
        local ans_space=""
        read -r ans_space </dev/tty 2>/dev/null || read -r ans_space 2>/dev/null || ans_space="n"
        if [[ ! "$ans_space" =~ ^[Yy]$ ]]; then
            echo -e "${red}Update aborted due to low disk space.${reset}"
            exit 1
        fi
    fi

    local boot_candidates=("/boot" "/efi" "/boot/efi")
    local checked_mount_devices=()
    for boot_target in "${boot_candidates[@]}"; do
        if mountpoint -q "$boot_target" 2>/dev/null || sudo -n mountpoint -q "$boot_target" 2>/dev/null; then
            local dev_id
            dev_id=$(stat -Lc '%d' "$boot_target" 2>/dev/null || true)
            [[ -z "$dev_id" ]] && dev_id=$(sudo -n stat -Lc '%d' "$boot_target" 2>/dev/null || true)

            if [[ -n "$dev_id" ]]; then
                local already_checked=false
                for seen in "${checked_mount_devices[@]+"${checked_mount_devices[@]}"}"; do
                    if [[ "$seen" == "$dev_id" ]]; then
                        already_checked=true
                        break
                    fi
                done
                [[ "$already_checked" == "true" ]] && continue
                checked_mount_devices+=("$dev_id")
            fi

            boot_free_kb=$(env LC_ALL=C df -Pk "$boot_target" 2>/dev/null | awk 'NR==2 {print $4}')
            if [[ ! "$boot_free_kb" =~ ^[0-9]+$ ]]; then
                boot_free_kb=$(sudo -n env LC_ALL=C df -Pk "$boot_target" 2>/dev/null | awk 'NR==2 {print $4}')
            fi
            if [[ "$boot_free_kb" =~ ^[0-9]+$ ]] && (( boot_free_kb < 65536 )); then
                local boot_free_mb=$(( boot_free_kb / 1024 ))
                if $DAEMON_MODE; then
                    log_step "Error: ${boot_target} partition is low on space (${boot_free_mb} MB free)."
                    return 1
                fi
                echo -e "\n${yellow}Warning: ${boot_target} partition is low on space (${white}${boot_free_mb} MB${yellow} free).${reset}"
                echo -ne "${white}Continue anyway? [y/N]: ${reset}"
                local ans_boot="n"
                read -r ans_boot </dev/tty 2>/dev/null || read -r ans_boot 2>/dev/null || ans_boot="n"
                if [[ ! "$ans_boot" =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
    done
    return 0
}

fix_pacman_keyrings() {
    echo -e "\n${yellow}${bold}Signature verification failed. Initializing Keyring Hotfix...${reset}"
    log_step "Running pacman-key reinitialization and population..."

    local cache_dir
    cache_dir=$(pacman-conf CacheDir 2>/dev/null | head -n 1)
    cache_dir="${cache_dir%/}"
    [[ -z "$cache_dir" ]] && cache_dir="/var/cache/pacman/pkg"

    sudo gpgconf --homedir /etc/pacman.d/gnupg --kill all >/dev/null 2>&1 || true
    sudo rm -rf /etc/pacman.d/gnupg/S.* 2>/dev/null || true
    if [[ -d "$cache_dir" ]]; then
        sudo rm -f "$cache_dir"/*.part "$cache_dir"/*.sig 2>/dev/null || true
        sudo rm -f "$cache_dir"/*keyring*.pkg.tar* "$cache_dir"/*trusted*.pkg.tar* 2>/dev/null || true
    fi

    if ! sudo env LC_ALL=C pacman-key --init; then
        echo -e "${red}Failed to initialize pacman keyring.${reset}"
        return 1
    fi

    if ! sudo env LC_ALL=C pacman-key --populate; then
        echo -e "${red}Failed to populate distribution keys.${reset}"
        return 1
    fi

    local pkgs_keyrings=("archlinux-keyring")
    pacman -Qq cachyos-keyring >/dev/null 2>&1 && pkgs_keyrings+=("cachyos-keyring")
    pacman -Qq cachyos-trusted >/dev/null 2>&1 && pkgs_keyrings+=("cachyos-trusted")
    pacman -Qq endeavouros-keyring >/dev/null 2>&1 && pkgs_keyrings+=("endeavouros-keyring")

    if [[ "${IS_OFFLINE_MODE:-false}" != "true" ]]; then
        sudo env LC_ALL=C pacman -Sy --needed --noconfirm "${pkgs_keyrings[@]}" >/dev/null 2>&1 || true
    fi
    echo -e "${green}Keyrings successfully restored and synchronized.${reset}\n"
    return 0
}

check_aur_rebuild_needed() {
    if [[ "${ENABLE_AUR_REBUILD_CHECK,,}" != "true" ]]; then
        return 0
    fi

    if ! command -v checkrebuild >/dev/null 2>&1; then
        return 0
    fi

    log_step "Checking for foreign packages requiring rebuild (checkrebuild)..."
    local cr_raw
    cr_raw=$(env LC_ALL=C checkrebuild 2>/dev/null || true)
    [[ -z "$cr_raw" ]] && return 0

    local raw_extracted foreign_installed pkgs_to_rebuild=""
    raw_extracted=$(printf "%s\n" "$cr_raw" | awk '
        $1 == "foreign" && $2 != "" {
            pkg = $2
            split(pkg, a, "[:(]")
            pkg = a[1]
            gsub(/[^a-zA-Z0-9@._+-]/, "", pkg)
            if (pkg != "" && pkg !~ /^(warning|error|info|note)$/i) print pkg
        }
    ' | sort -u)

    [[ -z "$raw_extracted" ]] && return 0

    foreign_installed=$(pacman -Qqm 2>/dev/null || true)
    if [[ -n "$foreign_installed" ]]; then
        pkgs_to_rebuild=$(awk 'NR==FNR {if ($1 != "") a[$1]=1; next} ($1 != "" && a[$1]) {print $1}' <(printf "%s\n" "$foreign_installed") <(printf "%s\n" "$raw_extracted") | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')
    fi

    if [[ -n "$pkgs_to_rebuild" ]]; then
        local count
        count=$(echo "$pkgs_to_rebuild" | wc -w)
        local rebuild_cmd=""
        local can_auto_rebuild=true

        if [[ "$HELPER_BIN" =~ ^(yay|paru|pikaur)$ ]]; then
            rebuild_cmd="$AUR_HELPER -S --rebuild $pkgs_to_rebuild"
        elif [[ "$HELPER_BIN" == "aura" ]]; then
            rebuild_cmd="aura -A $pkgs_to_rebuild"
        elif [[ "$HELPER_BIN" == "rua" ]]; then
            rebuild_cmd="rua install $pkgs_to_rebuild"
        elif [[ -n "$AUR_HELPER" ]]; then
            rebuild_cmd="$AUR_HELPER -S $pkgs_to_rebuild"
        else
            can_auto_rebuild=false
            rebuild_cmd="makepkg -sric (for: $pkgs_to_rebuild)"
        fi

        echo -e "\n${yellow}${bold}Attention:${reset} ${white}${count}${yellow} AUR package(s) (${white}${pkgs_to_rebuild}${yellow}) depend on older libraries.${reset}"

        if [[ "$can_auto_rebuild" == "true" ]]; then
            echo -e "${dim}Command: ${white}${rebuild_cmd}${reset}"
            if ! $DAEMON_MODE; then
                echo -ne "${white}Rebuild outdated AUR package(s) now? [Y/n]: ${reset}"
                local ans_rebuild=""
                read -r ans_rebuild </dev/tty 2>/dev/null || read -r ans_rebuild 2>/dev/null || ans_rebuild="n"
                if [[ "$ans_rebuild" =~ ^[Yy]$ || -z "$ans_rebuild" ]]; then
                    sudo -v 2>/dev/null || true
                    echo -e "\n${blue}${bold}Rebuilding AUR package(s)...${reset}\n"
                    execute_update_task "$rebuild_cmd"
                    local rb_exit=$?
                    if [[ $rb_exit -eq 0 ]]; then
                        echo -e "\n${green}AUR packages rebuilt successfully.${reset}\n"
                    else
                        echo -e "\n${red}Failed to rebuild some AUR packages (exit code $rb_exit).${reset}\n"
                    fi
                else
                    echo -e "${dim}AUR package rebuild skipped by user.${reset}\n"
                fi
            fi
        else
            echo -e "${dim}Manual rebuild needed: ${white}${rebuild_cmd}${reset}\n"
        fi
    fi
}

get_current_mirror() {
    local mirror
    mirror=$(awk '/^[ \t]*Server[ \t]*=/ {
        sub(/^[ \t]*Server[ \t]*=[ \t]*/, "");
        sub(/^[a-z]+:\/\//, "");
        split($0, a, "/");
        if (a[1] != "") { print a[1]; exit }
    }' /etc/pacman.d/mirrorlist 2>/dev/null)
    echo "${mirror:-Unknown}"
}

run_refl_and_check() {
    local cmd="$1"

    bash -o pipefail -c "$cmd" 2>&1 | tee "$REFL_LOG"
    local exit_code=${PIPESTATUS[0]}

    local err_count
    err_count=$(grep -cEi "warning: failed to rate|timed out|error" "$REFL_LOG" 2>/dev/null || true)

    if [[ $exit_code -ne 0 ]] && (( err_count >= 15 )); then
        echo -e "\n${yellow}Mirror ranker encountered problems: $err_count mirrors are unavailable or timed out.${reset}"
        echo -e "${yellow}The connection might be unstable, or the mirrors are currently down.${reset}"

        local force_cont
        echo -ne "${white}Continue with the old mirrorlist anyway? [y/N]: ${reset}"
        read -r force_cont

        if [[ ! "$force_cont" =~ ^[Yy]$ ]]; then
            echo -e "${red}The update was interrupted by the user.${reset}"
            exit 1
        fi

        return 255
    fi

    return "$exit_code"
}

refresh_mirrors() {
    if [[ "$DAEMON_MODE" == true ]]; then
        return 1
    fi
    local reason="${1:-Mirror instability detected (timeouts or errors).}"

    local mirror_list="/etc/pacman.d/mirrorlist"
    local current_mirror
    current_mirror=$(get_current_mirror)
    local mirror_age="Unknown"
    local ans refl_res new_mirror

    if [[ -f "$mirror_list" ]]; then
        local file_ts
        file_ts=$(stat -c %Y "$mirror_list" 2>/dev/null)
        if [[ -n "$file_ts" ]]; then
            local now_ts
            now_ts=$(date +%s)
            local diff_sec=$((now_ts - file_ts))
            local diff_days diff_hours diff_mins

            if (( diff_sec < 0 )); then
                mirror_age="just now"
            else
                diff_days=$((diff_sec / 86400))
                diff_hours=$(( (diff_sec % 86400) / 3600 ))
                diff_mins=$(( (diff_sec % 3600) / 60 ))
                if (( diff_days > 0 )); then
                    mirror_age="${diff_days}d ${diff_hours}h ago"
                elif (( diff_hours > 0 )); then
                    mirror_age="${diff_hours}h ${diff_mins}m ago"
                else
                    mirror_age="${diff_mins}m ago"
                fi
            fi
        fi
    fi

    local CUSTOM_RM="${CUSTOM_RATE_MIRRORS_CMD:-}"
    local CUSTOM_REFL="${CUSTOM_REFLECTOR_CMD:-}"
    local DEFAULT_REFL="sudo reflector --country Germany,Netherlands,France,Norway --protocol https --age 12 --latest 50 --number 20 --sort rate --save /etc/pacman.d/mirrorlist --download-timeout 10"

    local DISPLAY_CMD=""
    if [[ -n "$CUSTOM_RM" ]]; then
        DISPLAY_CMD="$CUSTOM_RM"
    elif command -v rate-mirrors &>/dev/null; then
        DISPLAY_CMD="rate-mirrors --concurrency=30 --disable-comments-in-file --protocol=https arch | sudo tee /etc/pacman.d/mirrorlist"
    elif [[ -n "$CUSTOM_REFL" ]]; then
        DISPLAY_CMD="$CUSTOM_REFL"
    else
        DISPLAY_CMD="$DEFAULT_REFL"
    fi

    echo -e "\n${yellow}${bold}!  $reason${reset}"
    echo -e "${dim}Current mirror: ${white}$current_mirror${dim} (Last ranked: $mirror_age)${reset}"
    echo -e "${dim}Command: ${white}$DISPLAY_CMD${reset}"
    echo -e "${dim}Can be changed in the settings.conf file.${reset}"
    echo -ne "${white}Refresh mirrors now? [Y/n]: ${reset}"
    if read -r ans; then
        if [[ "$ans" =~ ^[Yy]$ || -z "$ans" ]]; then

            if command -v eos-rankmirrors &>/dev/null; then
                echo -e "${blue}Ranking EndeavourOS mirrors (Timeout: 5s)...${reset}"
                if sudo eos-rankmirrors -t 5 > /dev/null; then
                    echo -e "${green}EndeavourOS mirrors updated.${reset}"
                else
                    echo -e "${red}Failed to rank EOS mirrors.${reset}"
                fi
            fi

            if command -v cachyos-rate-mirrors &>/dev/null; then
                echo -e "${blue}Ranking CachyOS mirrors...${reset}"
                if sudo cachyos-rate-mirrors; then
                    echo -e "${green}CachyOS mirrors updated.${reset}"
                else
                    echo -e "${red}Failed to rank CachyOS mirrors.${reset}"
                fi
            fi

            local REFL_SUCCESS=false

            if [[ -n "$CUSTOM_RM" ]]; then
                echo -e "\n${blue}Running custom rate-mirrors command...${reset}"
                local pre_mtime
                pre_mtime=$(stat -c %Y /etc/pacman.d/mirrorlist 2>/dev/null || echo 0)
                run_refl_and_check "$CUSTOM_RM"
                refl_res=$?
                local post_mtime
                post_mtime=$(stat -c %Y /etc/pacman.d/mirrorlist 2>/dev/null || echo 0)
                local srv_valid=0
                srv_valid=$(grep -c "^[[:space:]]*Server[[:space:]]*=" /etc/pacman.d/mirrorlist 2>/dev/null || echo 0)
                if [[ $refl_res -eq 0 && -s /etc/pacman.d/mirrorlist ]] && (( post_mtime >= pre_mtime && srv_valid >= 1 )); then
                    new_mirror=$(get_current_mirror)
                    echo -e "${green}Arch mirrors updated successfully. New mirror: ${white}$new_mirror${reset}\n"
                    REFL_SUCCESS=true
                elif [[ $refl_res -eq 255 ]]; then
                    echo -e "${yellow}Proceeding with old mirrors...${reset}\n"
                    return 0
                else
                    echo -e "${yellow}Custom rate-mirrors command failed or mirrorlist was not modified. Falling back to reflector...${reset}"
                fi
            elif command -v rate-mirrors &>/dev/null; then
                echo -e "\n${blue}Ranking mirrors using rate-mirrors (Fast)...${reset}"
                local rm_tmp rm_exit
                create_temp_file rm_tmp "asu_ratemirrors"

                env LC_ALL=C rate-mirrors --concurrency=30 --disable-comments-in-file --save="$rm_tmp" --protocol=https arch 2>&1 | tee "$REFL_LOG"
                rm_exit=${PIPESTATUS[0]}

                if [[ $rm_exit -eq 0 && -s "$rm_tmp" ]]; then
                    local srv_count
                    srv_count=$(grep -c "^[[:space:]]*Server[[:space:]]*=" "$rm_tmp" 2>/dev/null || true)
                    srv_count=${srv_count:-0}
                    if (( srv_count >= 3 )); then
                        if sudo cp "$rm_tmp" /etc/pacman.d/mirrorlist && sudo chmod 644 /etc/pacman.d/mirrorlist; then
                            new_mirror=$(get_current_mirror)
                            echo -e "\n${green}Arch mirrors updated via rate-mirrors ($srv_count mirrors). New mirror: ${white}$new_mirror${reset}\n"
                            REFL_SUCCESS=true
                        fi
                    fi
                fi

                rm -f "$rm_tmp" 2>/dev/null || true
                if ! $REFL_SUCCESS; then
                    echo -e "${yellow}rate-mirrors failed or returned insufficient mirrors. Falling back to reflector...${reset}"
                fi
            fi

            if ! $REFL_SUCCESS; then
                if command -v reflector &>/dev/null; then
                    if [[ -n "$CUSTOM_REFL" ]]; then
                        echo -e "\n${blue}Running custom reflector command...${reset}"
                        run_refl_and_check "$CUSTOM_REFL"
                        refl_res=$?
                        if [[ $refl_res -eq 0 ]]; then
                            new_mirror=$(get_current_mirror)
                            echo -e "${green}Custom Arch mirrors updated successfully. New mirror: ${white}$new_mirror${reset}\n"
                            return 0
                        elif [[ $refl_res -eq 255 ]]; then
                            echo -e "${yellow}Proceeding with old mirrors...${reset}\n"
                            return 0
                        else
                            echo -e "${yellow}Custom reflector command failed. Falling back to default...${reset}"
                        fi
                    fi

                    echo -e "\n${blue}Running reflector for Arch Linux (Fallback)...${reset}"
                    echo -e "${dim}Ranking mirrors... WARNINGS are expected.${reset}"
                    run_refl_and_check "$DEFAULT_REFL"
                    refl_res=$?
                    if [[ $refl_res -eq 0 ]]; then
                        new_mirror=$(get_current_mirror)
                        echo -e "${green}Arch mirrors updated successfully. New mirror: ${white}$new_mirror${reset}\n"
                        return 0
                    elif [[ $refl_res -eq 255 ]]; then
                        echo -e "${yellow}Proceeding with old mirrors...${reset}\n"
                        return 0
                    else
                        echo -e "${red}Reflector failed (Try changing the settings.conf settings).${reset}\n"
                        return 1
                    fi
                else
                    echo -e "${red}Error: Primary mirror ranking failed and 'reflector' is not installed for fallback.${reset}\n"
                    return 1
                fi
            fi
            return 0
        fi
    fi
    return 1
}

handle_daemon_sync_fail() {
    if [[ "$DAEMON_MODE" == true ]]; then
        if acquire_state_lock "x"; then
            local count_file="$CONFIG_DIR/sync_failures.count"
            local count=0
            if [[ -f "$count_file" ]]; then
                count=$(cat "$count_file" 2>/dev/null || echo 0)
            fi
            if [[ ! "$count" =~ ^[0-9]+$ ]]; then
                count=0
            fi
            count=$((count + 1))
            echo "$count" > "$count_file"
            if (( count > 0 && count % 3 == 0 )); then
                if command -v notify-send >/dev/null 2>&1; then
                    local notif_icon="dialog-error"
                    [[ -f "$ICON_PATH" ]] && notif_icon="$ICON_PATH"
                    launch_detached notify-send -a "Arch Smart Update" -u critical -i "$notif_icon" \
                        "Connection Warning" "Failed to connect to mirrors 3 times consecutively."
                fi
            fi
            release_state_lock
        fi
    fi
}

handle_daemon_sync_success() {
    if [[ "$DAEMON_MODE" == true ]]; then
        if acquire_state_lock "x"; then
            rm -f "$CONFIG_DIR/sync_failures.count"
            release_state_lock
        fi
    fi
}

# --- 7. Update Analysis & Database Query ---
log_step "Requesting Sudo access..."
if ! $DAEMON_MODE; then
    if ! sudo -v; then
        echo -e "${red}Error: Sudo authentication failed.${reset}"
        exit 1
    fi

    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null
            sleep 60
        done
    ) &
    SUDO_KEEP_ALIVE_PID=$!
fi

AUR_HELPER=""
HELPER_BIN=""
if [[ -n "${AUR_HELPER_OVERRIDE:-}" ]]; then
    check_bin=""
    read -r check_bin _ <<< "$AUR_HELPER_OVERRIDE" || true
    if [[ -n "$check_bin" ]] && command -v "$check_bin" &>/dev/null; then
        AUR_HELPER="$AUR_HELPER_OVERRIDE"
    else
        echo -e "${yellow}Warning: Override AUR helper '$check_bin' not found. Falling back to auto-detect.${reset}"
    fi
    unset check_bin
fi

if [[ -z "$AUR_HELPER" ]]; then
    for helper in "paru" "yay" "pikaur" "trizen" "aura" "pacaur" "pakku" "rua"; do
        if command -v "$helper" &>/dev/null; then
            AUR_HELPER="$helper"
            break
        fi
    done
fi

declare -a HELPER_CMD=()
if [[ -n "$AUR_HELPER" ]]; then
    read -ra HELPER_CMD <<< "$AUR_HELPER"
    HELPER_BIN="${HELPER_CMD[0]}"
fi

if [[ "$DAEMON_MODE" == "false" ]]; then
    if [[ -n "$AUR_HELPER" ]]; then
        if [[ -n "$CONFIG_DIR" && -d "$CONFIG_DIR" && -f "$CONFIG_DIR/.aur_warned" ]]; then
            rm -f "$CONFIG_DIR/.aur_warned" 2>/dev/null
        fi
    else
        if [[ ! -f "$CONFIG_DIR/.aur_warned" ]]; then
            echo -e "${yellow}Warning: No supported AUR helper detected on your system.${reset}"
            echo -e "${gray}Arch Smart Update will only manage official repository packages.${reset}"
            echo -e "${gray}To enable AUR support, consider installing an AUR helper like 'yay' or 'paru'.${reset}"
            echo -e "${dim}Note: This warning is shown only once. The limitation persists silently on future runs.${reset}\n"
            if [[ -n "$CONFIG_DIR" && -d "$CONFIG_DIR" ]]; then
                touch "$CONFIG_DIR/.aur_warned" 2>/dev/null
            fi
        fi
    fi
fi

echo -e "\n${blue}${bold}Checking for updates...${reset}"

if [[ -f /var/lib/pacman/db.lck ]]; then
    if $DAEMON_MODE; then exit 0; fi
    lock_active=false
    if command -v fuser &>/dev/null; then
        if sudo fuser /var/lib/pacman/db.lck >/dev/null 2>&1; then
            lock_active=true
        fi
    else
        lock_pid=$(sudo cat /var/lib/pacman/db.lck 2>/dev/null)
        if [[ "$lock_pid" =~ ^[0-9]+$ ]] && sudo kill -0 "$lock_pid" 2>/dev/null; then
            lock_comm=$(ps -p "$lock_pid" -o comm= 2>/dev/null || sudo cat "/proc/$lock_pid/comm" 2>/dev/null)
            lock_regex='pacman|yay|paru|pamac|trizen|pikaur|aura|pacaur|pakku|rua'
            if [[ "$lock_comm" =~ $lock_regex ]]; then
                lock_active=true
            fi
        fi
        
        if [[ "$lock_active" == false ]]; then
            if pgrep -x "pacman|yay|paru|pikaur|pakku|aura|trizen|pacaur|pamac|rua" >/dev/null 2>&1; then
                lock_active=true
            fi
        fi
    fi
    if [ "$lock_active" = true ]; then
        echo -e "${red}Error: Pacman database is locked (/var/lib/pacman/db.lck).${reset}"
        echo -e "${yellow}Another package manager process is running.${reset}"
        exit 1
    else
        echo -e "${yellow}Stale lock file found (/var/lib/pacman/db.lck), but no active process detected.${reset}"
        echo -ne "${white}Remove the stale lock file and continue? [y/N]: ${reset}"
        read -r rm_lock
        if [[ "$rm_lock" =~ ^[Yy]$ ]]; then
            sudo rm /var/lib/pacman/db.lck
            echo -e "${green}Lock file removed. Proceeding...${reset}"
        else
            echo -e "${red}Update aborted by user (database locked).${reset}"
            exit 1
        fi
    fi
fi

if [[ "$DAEMON_MODE" == true ]] && command -v gamemoded >/dev/null 2>&1; then
    if gamemoded -status 2>/dev/null | grep -qi "is active"; then
        log_step "GameMode is active. Background check postponed."
        exit 0
    fi
fi

check_arch_news

MIRROR_LIST="/etc/pacman.d/mirrorlist"
did_prompt_mirrors=false

if [[ -f "$MIRROR_LIST" ]]; then
    now_ts=$(date +%s)
    file_ts=$(stat -c %Y "$MIRROR_LIST" 2>/dev/null || echo "$now_ts")

    mirror_age_days=$(( (now_ts - file_ts) / 86400 ))

    if (( mirror_age_days >= 7 )); then
        refresh_mirrors "Mirrors are old (${mirror_age_days} days)."
        did_prompt_mirrors=true
    fi
fi

if $DAEMON_MODE; then
    did_prompt_mirrors=true
    PROMPT_MIRROR_REFRESH=false
fi

if [[ "$did_prompt_mirrors" == false ]] && [[ "${PROMPT_MIRROR_REFRESH,,}" == "true" ]]; then
    refresh_mirrors "Pre-update mirror refresh is enabled in settings.conf."
fi

log_step "Copying local DB..."
if $DAEMON_MODE; then
    if ! cp -a --no-preserve=ownership /var/lib/pacman/local "$CHECK_DB/" > /dev/null 2>&1; then
        log_step "Error: Failed to copy local DB."
        exit 1
    fi
else
    if ! sudo cp -a /var/lib/pacman/local "$CHECK_DB/" > /dev/null 2>&1; then
        echo -e "${red}Error: Failed to copy local DB.${reset}"
        exit 1
    fi
    sudo chown -R "$(id -u):$(id -g)" "$CHECK_DB"
    sudo chmod 755 "$CHECK_DB"
fi

MAX_RETRIES=1
attempt=0

while (( attempt <= MAX_RETRIES )); do
    log_step "Syncing temporary database (pacman -Sy)..."

    if $DAEMON_MODE; then
        declare -a PACMAN_OPTS=()
        if pacman --disable-sandbox --version >/dev/null 2>&1; then
            PACMAN_OPTS+=("--disable-sandbox")
        fi

        if command -v timeout >/dev/null 2>&1; then
            timeout -k 10s -s INT 600 env LC_ALL=C fakeroot pacman "${PACMAN_OPTS[@]}" -Sy --dbpath "$CHECK_DB" --logfile /dev/null 2>&1 | tee "$SYNC_LOG"
            PACMAN_EXIT=${PIPESTATUS[0]}

            if [[ "$PACMAN_EXIT" == "124" || "$PACMAN_EXIT" == "137" ]]; then
                log_step "Error: Database synchronization timed out after 10 minutes in daemon mode."
                handle_daemon_sync_fail
                exit 1
            fi
        else
            env LC_ALL=C fakeroot pacman "${PACMAN_OPTS[@]}" -Sy --dbpath "$CHECK_DB" --logfile /dev/null 2>&1 | tee "$SYNC_LOG"
            PACMAN_EXIT=${PIPESTATUS[0]}
        fi
    else
        sudo env LC_ALL=C pacman -Sy --dbpath "$CHECK_DB" --logfile /dev/null 2>&1 | tee "$SYNC_LOG"
        PACMAN_EXIT=${PIPESTATUS[0]}
    fi

    if grep -iqE "error|failed|timed out|could not resolve" "$SYNC_LOG"; then
        IS_DIRTY=1
    else
        IS_DIRTY=0
    fi

    err_count=$(grep -cEi "error|failed|timed out|could not resolve" "$SYNC_LOG" 2>/dev/null || true)

    if [[ $PACMAN_EXIT -eq 0 && $IS_DIRTY -eq 0 ]]; then
        break
    else
        if (( attempt < MAX_RETRIES )); then
            if refresh_mirrors "Failed to sync cleanly. Updating mirrors..."; then
                ((attempt++))
                log_step "Retrying sync..."
                continue
            fi
        fi

        if [[ $PACMAN_EXIT -ne 0 ]]; then
            if $DAEMON_MODE; then
                log_step "Network or mirror synchronization error in background mode. Postponing."
                handle_daemon_sync_fail
                exit 0
            fi

            echo -e "\n${yellow}Could not synchronize remote package databases (Offline or mirror error).${reset}"
            echo -ne "${white}Continue anyway using local state? [y/N]: ${reset}"
            read -r force_cont
            if [[ ! "$force_cont" =~ ^[Yy]$ ]]; then
                echo -e "${red}Update aborted by user.${reset}"
                exit 1
            fi
            IS_OFFLINE_MODE=true
            if [[ -d /var/lib/pacman/sync ]]; then
                mkdir -p "$CHECK_DB/sync"
                cp -a /var/lib/pacman/sync/. "$CHECK_DB/sync/" 2>/dev/null || true
                chmod -R u+rw "$CHECK_DB/sync" 2>/dev/null || true
            fi
            if ! find "$CHECK_DB/sync" -mindepth 1 -name "*.db" -print -quit 2>/dev/null | grep -q .; then
                echo -e "${red}No usable local package databases found in /var/lib/pacman/sync.${reset}"
                exit 1
            fi
            break
        fi

        if (( err_count >= 15 )); then
            if $DAEMON_MODE; then
                log_step "Mirror synchronization warnings in background mode. Postponing."
                handle_daemon_sync_fail
                exit 0
            fi

            echo -e "\n${yellow}The selected mirror might not be optimal.${reset}"
            echo -ne "${white}Continue anyway? [y/N]: ${reset}"
            read -r force_cont
            if [[ ! "$force_cont" =~ ^[Yy]$ ]]; then
                echo -e "${red}Update aborted by user.${reset}"
                exit 1
            fi
            break
        fi

        echo -e "${yellow}Proceeding despite mirror warnings...${reset}"
        break
    fi
done

if ! $DAEMON_MODE; then
    sudo chown -R "$(id -u):$(id -g)" "$CHECK_DB"
fi

if ! find "$CHECK_DB/sync" -mindepth 1 -name "*.db" -print -quit 2>/dev/null | grep -q .; then
    if $DAEMON_MODE; then
        log_step "Error: No package databases found in sync directory."
        handle_daemon_sync_fail
        exit 1
    fi
    echo -e "${red}Error: No local package databases found in /var/lib/pacman/sync.${reset}"
    echo -e "${yellow}Please run 'sudo pacman -Sy' while online to initialize package databases.${reset}"
    exit 1
fi

if [[ "$DAEMON_MODE" == true && $PACMAN_EXIT -eq 0 ]]; then
    handle_daemon_sync_success
fi

log_step "Calculating update list (pacman -Qu)..."

ignored_pkgs=$(pacman-conf IgnorePkg 2>/dev/null | tr ' ' '\n' || true)
ignored_groups=$(pacman-conf IgnoreGroup 2>/dev/null | tr ' ' '\n' || true)

if [[ -n "$ignored_groups" ]]; then
    group_pkgs=$(printf "%s\n" "$ignored_groups" | xargs -r pacman -Sgq 2>/dev/null || true)
    ignored_pkgs="$ignored_pkgs"$'\n'"$group_pkgs"
fi

ignored_pkgs=$(printf "%s\n" "$ignored_pkgs" | sed '/^$/d' | sort -u || true)

repo_updates=$(LC_ALL=C pacman -Qu --dbpath "$CHECK_DB" --color never || true)

aur_updates=""
if [[ "${IS_OFFLINE_MODE:-false}" != "true" ]]; then
    if [[ "$HELPER_BIN" =~ ^(yay|paru|pikaur|trizen|pacaur|pakku)$ ]]; then
        if aur_raw=$("${HELPER_CMD[@]}" -Qua --dbpath "$CHECK_DB" --color never 2>/dev/null) && [[ -n "$aur_raw" ]]; then
            aur_updates="$aur_raw"
        fi
    else
        fetch_aur_updates_rpc
        if [[ -n "$AUR_RPC_CACHE" ]]; then
            aur_updates="$AUR_RPC_CACHE"
        fi
    fi
fi

ignored_updates=""
if [[ -n "$ignored_pkgs" ]]; then
    awk_base='BEGIN { split(ig, a, "\n"); for (i in a) if(a[i] != "") ign[a[i]]=1 }'

    all_raw_updates=$(printf "%s\n%s" "$repo_updates" "$aur_updates" | sed '/^$/d' || true)
    ignored_updates=$(printf "%s\n" "$all_raw_updates" | awk -v ig="$ignored_pkgs" "$awk_base ign[\$1]" || true)

    [[ -n "$repo_updates" ]] && repo_updates=$(printf "%s\n" "$repo_updates" | awk -v ig="$ignored_pkgs" "$awk_base !ign[\$1]" || true)
    [[ -n "$aur_updates" ]]  && aur_updates=$(printf "%s\n" "$aur_updates" | awk -v ig="$ignored_pkgs" "$awk_base !ign[\$1]" || true)
fi

repo_pkgs=""
aur_pkgs=""

[[ -n "$repo_updates" ]] && repo_pkgs=$(printf "%s\n" "$repo_updates" | awk '{print $1}')
[[ -n "$aur_updates" ]] && aur_pkgs=$(printf "%s\n" "$aur_updates" | awk '{print $1}')

updates="$repo_updates"
[[ -n "$aur_updates" ]] && updates="$updates"$'\n'"$aur_updates"
updates=$(printf "%s\n" "$updates" | sed '/^$/d')

if [[ -z "$updates" ]]; then
    echo -e "${green}System is fully up to date.${reset}\n"

    if [[ -n "$ignored_updates" ]]; then
        while read -r pkg old_ver _ new_ver rest; do
            echo -e "${dim}- ${pkg}: ${gray}${old_ver}${reset} ${blue}→${reset} ${white}${new_ver}${reset}"
        done <<< "$ignored_updates"
        echo ""
    fi

    if acquire_state_lock "x"; then
        existing_ts=0
        existing_tag=""
        raw_existing=""
        raw_ts=""
        if [[ -f "$CONFIG_DIR/next_check.conf" ]]; then
            raw_existing=$(cat "$CONFIG_DIR/next_check.conf" 2>/dev/null || echo 0)
            raw_ts="${raw_existing%%|*}"
            raw_ts="${raw_ts#"${raw_ts%%[![:space:]]*}"}"
            raw_ts="${raw_ts%"${raw_ts##*[![:space:]]}"}"
            if [[ "$raw_existing" == *"|"* ]]; then
                existing_tag="${raw_existing#*|}"
                existing_tag="${existing_tag#"${existing_tag%%[![:space:]]*}"}"
                existing_tag="${existing_tag%"${existing_tag##*[![:space:]]}"}"
            fi
            if [[ "$raw_ts" =~ ^[0-9]+$ ]]; then
                existing_ts=$(( 10#$raw_ts ))
            fi
        fi
        if [[ "$existing_tag" != "silence" ]] || (( existing_ts <= $(date +%s) )); then
            rm -f "$CONFIG_DIR/next_check.conf"
        fi
        rm -f "$CONFIG_DIR/updates.cache"
        release_state_lock
    fi

    sync_daemon_state >/dev/null 2>&1
    exit 0
fi

dependency_warnings=""
sim_error_warning=""

if [[ -n "$ignored_updates" ]]; then
    log_step "Checking for dependency conflicts with ignored packages..."

    sim_out=$(LC_ALL=C pacman -Sup --dbpath "$CHECK_DB" --print-format "%n" --noconfirm 2>&1)
    sim_exit=$?

    if [[ $sim_exit -ne 0 ]]; then
        if echo "$sim_out" | grep -qE "could not satisfy dependencies|conflicting dependencies|unresolvable package conflicts"; then
            dependency_warnings=$(echo "$sim_out" | awk '/could not satisfy dependencies|conflicting dependencies|unresolvable package conflicts/{flag=1; next} flag {print $0}')

            if [[ -z "$dependency_warnings" ]]; then
                dependency_warnings=$(echo "$sim_out" | awk '/error:/ {flag=1} flag {print $0}')
                [[ -z "$dependency_warnings" ]] && dependency_warnings="$sim_out"
            fi
        else
            sim_error_warning="${yellow}The update simulation failed due to a transaction error.${reset}\n${dim}${sim_out}${reset}"
        fi
    fi
fi

pkg_count=$(grep -c . <<< "$updates")
if [[ -n "$aur_updates" ]]; then
    aur_count=$(grep -c . <<< "$aur_updates")
else
    aur_count=0
fi

log_step "Found $pkg_count updates ($aur_count from AUR). Starting detailed analysis..."
echo -e "${blue}${bold}Analyzing updates: ${white}$pkg_count packages${reset}"

all_pkgs=$(printf "%s\n" "$updates" | awk '{print $1}')

log_step "Fetching remote metadata (pacman -Si)..."
declare -A NEW_DATA

parse_metadata() {
    local default_repo="$1"
    awk -v def_repo="$default_repo" '
        /^Name[ \t]*:/ {n=$0; sub(/^[^:]*:[ \t]*/, "", n)}
        /^Repository[ \t]*:/ {r=$0; sub(/^[^:]*:[ \t]*/, "", r)}
        /^(Build Date|Last Modified)[ \t]*:/ {b=$0; sub(/^[^:]*:[ \t]*/, "", b)}
        /^Download Size[ \t]*:/ {s=$0; sub(/^[^:]*:[ \t]*/, "", s)}
        /^Description[ \t]*:/ {d=$0; sub(/^[^:]*:[ \t]*/, "", d); gsub(/[|\t~]/, " ", d)}
        /^$/ {
            if (n) {
                print n "~|~" (r ? r : def_repo) "|" b "|" (s ? s : "N/A") "|" d
                n=""; r=""; b=""; s=""; d=""
            }
        }
        END {if (n) print n "~|~" (r ? r : def_repo) "|" b "|" (s ? s : "N/A") "|" d}
    '
}

if [[ -n "$repo_pkgs" ]]; then
    while IFS='' read -r line; do
        NEW_DATA["${line%%~|~*}"]="${line#*~|~}"
    done < <(printf "%s\n" "$repo_pkgs" | xargs -r env LC_ALL=C pacman -Si --dbpath "$CHECK_DB" --color never 2>/dev/null | parse_metadata "")
fi

if [[ -n "$aur_pkgs" ]]; then
    log_step "Fetching AUR metadata..."
    if [[ "$HELPER_BIN" =~ ^(yay|paru|pikaur|trizen|pacaur|pakku)$ ]]; then
        while IFS='' read -r line; do
            NEW_DATA["${line%%~|~*}"]="${line#*~|~}"
        done < <(printf "%s\n" "$aur_pkgs" | xargs -r env LC_ALL=C "${HELPER_CMD[@]}" -Si 2>/dev/null | parse_metadata "AUR")
    else
        while IFS='' read -r line; do
            NEW_DATA["${line%%~|~*}"]="${line#*~|~}"
        done < <(printf "%s\n" "$aur_pkgs" | python3 -c '
import urllib.request, json, sys, urllib.parse, datetime
try:
    names = [line.strip() for line in sys.stdin if line.strip()]
    if not names: sys.exit(0)
    aur_data = []
    for i in range(0, len(names), 100):
        chunk = names[i:i+100]
        args = "&".join(f"arg[]={urllib.parse.quote(n)}" for n in chunk)
        req = urllib.request.Request(f"https://aur.archlinux.org/rpc/?v=5&type=info&{args}", headers={"User-Agent": "ArchSmartUpdate/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("type") != "error": aur_data.extend(data.get("results", []))
    for item in aur_data:
        name = item.get("Name")
        if not name:
            continue
        last_mod = item.get("LastModified")
        date_str = "N/A"
        if last_mod:
            try:
                date_str = datetime.datetime.fromtimestamp(int(last_mod), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
            except Exception:
                pass
        raw_desc = item.get("Description") or ""
        desc = raw_desc.replace("\n", " ").replace("\r", " ").replace("|", " ").replace("\t", " ").replace("~", " ")
        print(f"{name}~|~AUR|{date_str}|N/A|{desc}")
except Exception: pass' 2>/dev/null)
    fi
    while read -r pkg; do
        [[ -n "$pkg" && -z "${NEW_DATA[$pkg]:-}" ]] && NEW_DATA["$pkg"]="AUR|N/A|N/A|"
    done <<< "$aur_pkgs"
fi

log_step "Fetching local metadata (pacman -Qi)..."
declare -A OLD_DATA
while IFS='|' read -r name bdate reason; do
    [[ -z "${OLD_DATA[$name]:-}" ]] && OLD_DATA["$name"]="$bdate|$reason"
done < <(printf "%s\n" "$all_pkgs" | xargs -r env LC_ALL=C pacman -Qi 2>/dev/null | awk '
    /^Name[ \t]*:/ {n=$0; sub(/^[^:]*:[ \t]*/, "", n)}
    /^Build Date[ \t]*:/ {b=$0; sub(/^[^:]*:[ \t]*/, "", b)}
    /^Install Reason[ \t]*:/ {r=$0; sub(/^[^:]*:[ \t]*/, "", r)}
    /^$/ {
        if (n) {
            print n "|" b "|" r
            n=""; b=""; r=""
        }
    }
    END {if (n) print n "|" b "|" r}
')

log_step "Processing data and calculating diffs..."

now=$(date +%s)
current_idx=0

max_name=7
max_old=3
max_new=3
max_repo=4
max_size=4

declare -A DATE_CACHE

while read -r pkgname old_ver _ new_ver _rest; do
    ((current_idx++))
    percent=$(( current_idx * 100 / pkg_count ))

    if ! $DAEMON_MODE; then
        if (( percent % 5 == 0 || current_idx == pkg_count )); then
            filled=$(( percent / 5 ))
            empty=$(( 20 - filled ))
            printf '\r\033[2K%bAnalysis: %b[' "$gray" "$blue"
            printf "%${filled}s" | tr ' ' '='
            printf ">"
            printf "%${empty}s" | tr ' ' '-'
            printf '] %s%%%b' "$percent" "$reset"
        fi
    fi

    IFS='|' read -r repo date_new size desc <<< "${NEW_DATA[$pkgname]:-}"
    IFS='|' read -r _ reason <<< "${OLD_DATA[$pkgname]:-}"

    is_explicit=0
    [[ "$reason" == *"Explicitly"* ]] && is_explicit=1

    (( ${#pkgname} > max_name )) && max_name=${#pkgname}
    (( ${#old_ver} > max_old )) && max_old=${#old_ver}
    (( ${#new_ver} > max_new )) && max_new=${#new_ver}
    (( ${#repo} > max_repo )) && max_repo=${#repo}
    (( ${#size} > max_size )) && max_size=${#size}

    epoch_new=0
    fmt_date_new=""
    diff_hours=9999

    if [[ -n "$date_new" && "$date_new" != "N/A" ]]; then
        if [[ -z "${DATE_CACHE["$date_new"]:-}" ]]; then
            DATE_CACHE["$date_new"]=$(LC_TIME=C date -d "$date_new" +'%s|%d %b %H:%M' 2>/dev/null || echo "0|")
        fi

        IFS='|' read -r epoch_new fmt_date_new <<< "${DATE_CACHE["$date_new"]:-}"

        if [[ -n "$epoch_new" ]] && (( epoch_new > 0 )); then
            diff_hours=$(( (now - epoch_new) / 3600 ))
        fi
    fi

    is_nuke=0
    is_crit=0
    is_feat=0

    [[ ${NUKE_MAP["$pkgname"]:-} ]] && is_nuke=1
    [[ ${CRIT_MAP["$pkgname"]:-} ]] && is_crit=1
    [[ ${FEAT_MAP["$pkgname"]:-} ]] && is_feat=1

    if (( is_nuke )); then
        pkg_level=0
    elif (( is_crit )); then
        pkg_level=1
    elif (( is_feat )); then
        pkg_level=2
    else
        pkg_level=3
    fi

    upd_type=$(get_update_type "$old_ver" "$new_ver" "$pkg_level")

    sort_key=$(printf "%d.%05d" "$pkg_level" "$diff_hours")

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$sort_key" "$diff_hours" "$pkg_level" "$upd_type" "$pkgname" "$old_ver" "$new_ver" \
        "$repo" "$size" "$is_explicit" "$epoch_new" "$fmt_date_new" "$desc" >> "$OUTPUT_FILE"

done <<< "$updates"

echo -e "\n"

total_download_size="0.00 MiB"
if [[ -s "$OUTPUT_FILE" ]]; then
    total_download_size=$(env LC_ALL=C awk -F'\t' -f - "$OUTPUT_FILE" <<'EOF'
{
    if (tolower($8) != "aur" && $9 != "N/A" && $9 != "") {
        split($9, a, " ")
        val = a[1]
        unit = tolower(a[2])

        if (unit == "kib" || unit == "kb" || unit == "k") val /= 1024
        else if (unit == "gib" || unit == "gb" || unit == "g") val *= 1024
        else if (unit == "b" || unit == "bytes") val /= (1024 * 1024)

        sum += val
    }
}
END {
    if (sum >= 1024) {
        printf "%.2f GiB", sum / 1024
    } else {
        printf "%.2f MiB", sum + 0
    }
}
EOF
)
fi

w_age=8
w_stat=8
w_repo=$(( max_repo ))
w_type=6
w_name=$(( max_name ))
w_old=$(( max_old ))
w_new=$(( max_new ))
w_size=$(( max_size ))
w_date=12

term_cols=$(tput cols 2>/dev/null || echo 120)
used_width=$(( w_age + 1 + w_stat + 1 + w_repo + 1 + w_type + 1 + w_name + 1 + w_old + 3 + w_new + 1 + w_size + 1 + w_date + 1 ))
w_desc=$(( term_cols - used_width - 1 ))

if (( w_desc < 5 )); then
    w_desc=0
fi

sep_line=$(printf "%${term_cols}s" | tr ' ' '-')

printf "${dim}%s${reset}\n" "$sep_line"

fmt_center() {
    local str="$1"
    local width="$2"
    local len=${#str}
    if (( len >= width )); then
        printf "%s" "$str"
    else
        local l_pad=$(( (width - len) / 2 ))
        local r_pad=$(( width - len - l_pad ))
        printf "%*s%s%*s" $l_pad "" "$str" $r_pad ""
    fi
}

h_age=$(fmt_center "AGE" "$w_age")
h_stat=$(fmt_center "STATUS" "$w_stat")
h_repo=$(fmt_center "REPO" "$w_repo")
h_type=$(fmt_center "TYPE" "$w_type")
h_size=$(fmt_center "SIZE" "$w_size")
h_date=$(fmt_center "NEW DATE" "$w_date")

printf -v h_name "%-${w_name}s" "PACKAGE"
printf -v h_old "%${w_old}s" "OLD"
printf -v h_new "%-${w_new}s" "NEW"

h_desc="DESCRIPTION"
(( w_desc == 0 )) && h_desc=""

printf "${bold}${gray}%s %s %s %s %s %s   %s %s %s %s${reset}\n" \
    "$h_age" "$h_stat" "$h_repo" "$h_type" "$h_name" "$h_old" "$h_new" "$h_size" "$h_date" "$h_desc"

printf "${dim}%s${reset}\n" "$sep_line"

env LC_ALL=C sort -n "$OUTPUT_FILE" | while IFS=$'\t' read -r key diff_hours pkg_level upd_type pkgname old_ver new_ver repo size is_explicit epoch_new fmt_date_new desc; do

    if (( diff_hours == 9999 )); then age_disp="[?]"; age_col=$dim
    else
        age_disp="[${diff_hours}h]"
        if (( diff_hours < 12 )); then age_col="${red}${bold}"
        elif (( diff_hours < 48 )); then age_col="${yellow}"
        else age_col="${green}"; fi
    fi
    printf -v f_age "%-${w_age}s" "$age_disp"
    out_age="${age_col}${f_age}${reset}"

    if (( pkg_level == 0 )); then
        out_stat="${bg_nuke} ☢ NUKE ${reset}"
    elif (( pkg_level == 1 )); then
        out_stat="${bg_crit} ! CRIT ${reset}"
    elif (( pkg_level == 2 )); then
        out_stat="${bg_feat} * FEAT ${reset}"
    else
        out_stat="$(printf "%-${w_stat}s" " ")"
    fi

    printf -v f_repo "%-${w_repo}s" "$repo"
    if [[ "${repo,,}" == "aur" ]]; then
        out_repo="${magenta}${f_repo}${reset}"
    else
        out_repo="${dim}${f_repo}${reset}"
    fi

    type_col=$(get_type_color "$upd_type")
    printf -v f_type "%-${w_type}s" "$upd_type"
    out_type="${type_col}${f_type}${reset}"

    if (( is_explicit == 1 )); then
        name_col="${white}${bold}"
    else
        name_col="${gray}"
    fi
    printf -v f_name "%-${w_name}s" "$pkgname"
    out_name="${name_col}${f_name}${reset}"

    printf -v f_date_padded "%-${w_date}s" "$fmt_date_new"
    out_date_new="${dim}${f_date_padded}${reset}"

    printf -v f_size "%${w_size}s" "$size"
    out_size="${white}${f_size}${reset}"

    if (( w_desc > 0 )); then
        safe_desc="${desc//\\/\\\\}"
        if (( ${#safe_desc} > w_desc )); then
            out_desc="${dim}${safe_desc:0:$((w_desc-1))}…${reset}"
        else
            out_desc="${dim}${safe_desc}${reset}"
        fi
    else
        out_desc=""
    fi

    printf "%b %b %b %b %b ${gray}%${w_old}s${reset} ${blue}→${reset} ${white}%-${w_new}s${reset} %b %b %b\n" \
        "$out_age" "$out_stat" "$out_repo" "$out_type" "$out_name" \
        "$old_ver" "$new_ver" "$out_size" "$out_date_new" "$out_desc"

done

printf "${dim}%s${reset}\n" "$sep_line"
echo -e "${gray}Total Download Size: ${white}${bold}${total_download_size}${reset}"

give_advice() {
    local now
    now=$(date +%s)

    local T_MIRROR_SEC=$(( T_MIRROR_H * 3600 ))
    local T_FEAT_SEC=$(( T_FEAT_H * 3600 ))
    local T_CRIT_SEC=$(( T_CRIT_H * 3600 ))
    local T_DE_SEC=$(( T_DE_H * 3600 ))
    local T_NUKE_SEC=$(( T_NUKE_H * 3600 ))

    local fresh_pkg_count=0
    local fresh_feat_count=0
    local fresh_de_count=0
    local fresh_crit_count=0
    local fresh_nuke_count=0

    local min_age_norm_sec=999999999
    local min_age_feat_sec=999999999
    local min_age_de_sec=999999999
    local min_age_crit_sec=999999999
    local min_age_nuke_sec=999999999

    local risky_norm_pkg=""
    local risky_feat_pkg=""
    local risky_de_pkg=""
    local risky_crit_pkg=""
    local risky_nuke_pkg=""

    local DE_PATTERN="^(plasma-|gnome-|hyprland|kwin|mutter|cinnamon|xfce4|qt[56]-|gtk[34]|kf[56]-|frameworkintegration)"

    local pkg_level="" upd_type="" pkgname="" repo="" epoch_new="0"

    while IFS=$'\t' read -r _ _ pkg_level upd_type pkgname _ _ repo _ _ epoch_new _ _; do
        [[ "${repo,,}" == "aur" ]] && continue

        local pkg_ts=${epoch_new:-0}
        (( pkg_ts == 0 )) && continue

        local age_sec=$(( now - pkg_ts ))
        (( age_sec < 0 )) && age_sec=0

        local is_patch_override=0
        if [[ "${IGNORE_PATCH_TIMERS,,}" == "true" && "$upd_type" == "Patch" ]]; then
            is_patch_override=1
        fi

        if (( is_patch_override == 0 )); then
            if (( pkg_level == 0 )); then
                if (( age_sec < T_NUKE_SEC )); then
                    ((fresh_nuke_count++))
                    if (( age_sec < min_age_nuke_sec )); then
                        min_age_nuke_sec=$age_sec
                        risky_nuke_pkg=$pkgname
                    fi
                fi
            fi

            if (( pkg_level == 1 )); then
                if (( age_sec < T_CRIT_SEC )); then
                    ((fresh_crit_count++))
                    if (( age_sec < min_age_crit_sec )); then
                        min_age_crit_sec=$age_sec
                        risky_crit_pkg=$pkgname
                    fi
                fi
            fi

            if [[ "$pkgname" =~ $DE_PATTERN ]]; then
                if (( age_sec < T_DE_SEC )); then
                    ((fresh_de_count++))
                    if (( age_sec < min_age_de_sec )); then
                        min_age_de_sec=$age_sec
                        risky_de_pkg=$pkgname
                    fi
                fi
            fi

            if (( pkg_level == 2 )); then
                if (( age_sec < T_FEAT_SEC )); then
                    ((fresh_feat_count++))
                    if (( age_sec < min_age_feat_sec )); then
                        min_age_feat_sec=$age_sec
                        risky_feat_pkg=$pkgname
                    fi
                fi
            fi
        fi

        if (( age_sec < T_MIRROR_SEC )); then
            ((fresh_pkg_count++))
            if (( age_sec < min_age_norm_sec )); then
                min_age_norm_sec=$age_sec
                risky_norm_pkg=$pkgname
            fi
        fi

    done < "$OUTPUT_FILE"

    echo -e "${dim}---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------${reset}"

    local max_wait_sec=0
    local verdict_level=0 # 0=Safe, 1=Yellow, 2=Red, 3=NUCLEAR
    local reasons=()

    if (( fresh_nuke_count > 0 )); then
        local wait=$(( T_NUKE_SEC - min_age_nuke_sec ))
        (( wait > max_wait_sec )) && max_wait_sec=$wait
        verdict_level=3
        reasons+=("${red}${bold}HIGH RISK${dim} System Core updates (< ${T_NUKE_H}h). Wait for stability! (e.g., $risky_nuke_pkg)")
    fi

    if (( fresh_crit_count > 0 )); then
        local wait=$(( T_CRIT_SEC - min_age_crit_sec ))
        (( wait > max_wait_sec )) && max_wait_sec=$wait
        (( verdict_level < 2 )) && verdict_level=2
        reasons+=("Critical updates (< ${T_CRIT_H}h). (e.g., $risky_crit_pkg)")
    fi

    if (( fresh_de_count > 0 )); then
        local wait=$(( T_DE_SEC - min_age_de_sec ))
        (( wait > max_wait_sec )) && max_wait_sec=$wait
        (( verdict_level < 2 )) && verdict_level=2
        reasons+=("Major DE update detected (< ${T_DE_H}h). (e.g., $risky_de_pkg)")
    fi

    if (( fresh_feat_count > 0 )); then
        local wait=$(( T_FEAT_SEC - min_age_feat_sec ))
        (( wait > max_wait_sec )) && max_wait_sec=$wait
        (( verdict_level < 1 )) && verdict_level=1
        reasons+=("Fresh Feature updates (< ${T_FEAT_H}h). (e.g., $risky_feat_pkg)")
    fi

    if (( fresh_pkg_count > 0 )); then
        local wait=$(( T_MIRROR_SEC - min_age_norm_sec ))
        (( wait > max_wait_sec )) && max_wait_sec=$wait
        (( verdict_level < 1 )) && verdict_level=1
        reasons+=("Mirrors might not be fully synced (< ${T_MIRROR_H}h). (e.g., $risky_norm_pkg)")
    fi

    local color=$green
    local verdict="SAFE"

    case $verdict_level in
        1) color=$yellow; verdict="REVIEW" ;;
        2) color=$red; verdict="HOLD" ;;
        3) color="${red}${bold}"; verdict="DANGER" ;;
    esac

    printf '%bADVISOR:%b ' "$bold" "$reset"

    if (( max_wait_sec == 0 )); then
        echo -e "${green}${bold}GO FOR IT!${reset} ${dim}(Packages have stabilized. Mirrors synced.)${reset}"
        GLOBAL_ADVISOR_SAFE=true
    else
        local target_time
        target_time=$(date -d "@$(( now + max_wait_sec ))" +%H:%M || echo "00:00")

        local wait_h=$(( max_wait_sec / 3600 ))
        local wait_m=$(( (max_wait_sec % 3600) / 60 ))

        local dur_str="+"
        (( wait_h > 0 )) && dur_str+="${wait_h}h "
        dur_str+="${wait_m}m"

        echo -e "${color}${bold}$verdict${reset} ${white}Recommend waiting until ${bold}$target_time${reset} ($dur_str)"

        if (( ${#reasons[@]} > 0 )); then
             echo -ne "${dim}Reason: ${reasons[0]}${reset}"
             for (( i=1; i<${#reasons[@]}; i++ )); do
                 echo -ne "\n${dim}+ ${reasons[$i]}${reset}"
             done
             echo ""
        fi

        GLOBAL_ADVISOR_SAFE=false
    fi

    if acquire_state_lock "x"; then
        local existing_next_ts=0 existing_tag=""
        if [[ -f "$CONFIG_DIR/next_check.conf" ]]; then
            local raw_existing
            raw_existing=$(cat "$CONFIG_DIR/next_check.conf" 2>/dev/null || echo 0)
            local raw_ts="${raw_existing%%|*}"
            raw_ts="${raw_ts#"${raw_ts%%[![:space:]]*}"}"
            raw_ts="${raw_ts%"${raw_ts##*[![:space:]]}"}"
            if [[ "$raw_existing" == *"|"* ]]; then
                existing_tag="${raw_existing#*|}"
                existing_tag="${existing_tag#"${existing_tag%%[![:space:]]*}"}"
                existing_tag="${existing_tag%"${existing_tag##*[![:space:]]}"}"
            fi
            if [[ "$raw_ts" =~ ^[0-9]+$ ]]; then
                existing_next_ts=$(( 10#$raw_ts ))
            fi
        fi

        if [[ "$existing_tag" == "silence" ]] && (( existing_next_ts > now )); then
            :
        elif [[ "$GLOBAL_ADVISOR_SAFE" == "true" ]]; then
            rm -f "$CONFIG_DIR/next_check.conf"
        else
            local target_hold=$(( now + max_wait_sec ))
            echo "${target_hold}|advisor" > "$CONFIG_DIR/next_check.conf"
        fi
        release_state_lock
    fi

    sync_daemon_state >/dev/null 2>&1
    echo -e "${dim}---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------${reset}"
}

GLOBAL_ADVISOR_SAFE=false
give_advice

if [[ -n "$ignored_updates" ]]; then
    echo -e "\n${magenta}${bold}Skipped Packages (IgnorePkg / IgnoreGroup):${reset}"
    while read -r pkg old_ver _ new_ver rest; do
        echo -e "${dim}- ${pkg}: ${gray}${old_ver}${reset} ${blue}→${reset} ${white}${new_ver}${reset}"
    done <<< "$ignored_updates"

    if [[ -n "$dependency_warnings" ]]; then
        echo -e "\n${bg_nuke}${white}${bold}DEPENDENCY BREAKAGE DETECTED${reset}"
        echo -e "${red}Updating now will likely abort because of unresolved dependencies!${reset}"
        echo -e "${gray}Pacman reports the following conflicts:${reset}"
        echo -e "${red}${dependency_warnings}${reset}\n"
    elif [[ -n "$sim_error_warning" ]]; then
        echo -e "\n${sim_error_warning}\n"
    else
        echo -e "\n${green}No dependency conflicts detected from skipped packages ${dim}(Official repos only)${green}.${reset}"
    fi
fi

if [[ "$DAEMON_MODE" == true ]]; then
    CACHE_FILE="$CONFIG_DIR/updates.cache"

    if ! check_disk_space >/dev/null 2>&1; then
        log_step "Error: Insufficient disk space detected in background mode. Notification suppressed."
        exit 0
    fi

    if [[ "$GLOBAL_ADVISOR_SAFE" == true ]] && (( pkg_count > 0 )) && command -v notify-send >/dev/null 2>&1; then
        OLD_COUNT=0
        should_notify=false
        if acquire_state_lock "x"; then
            if [[ -f "$CACHE_FILE" ]]; then
                OLD_COUNT=$(cat "$CACHE_FILE" 2>/dev/null || echo 0)
            fi
            [[ ! "$OLD_COUNT" =~ ^[0-9]+$ ]] && OLD_COUNT=0
            if [[ "${1:-}" == "--check" ]] || (( pkg_count != OLD_COUNT )); then
                rm -f "$CACHE_FILE"
                echo "$pkg_count" > "$CACHE_FILE"
                should_notify=true
            fi
            release_state_lock
        fi

        if [[ "$should_notify" == "true" ]]; then
            notif_icon="software-update-available"
            [[ -f "$ICON_PATH" ]] && notif_icon="$ICON_PATH"
            target_script="$(realpath "$(command -v "${BASH_SOURCE:-$0}" 2>/dev/null || echo "${BASH_SOURCE:-$0}")")"

            launch_detached "$target_script" --notify-worker "$notif_icon" "$pkg_count" "$aur_count" "$NOTIFICATION_TIMEOUT"
        fi
    fi
    exit 0
fi

# --- 8. Update Request ---
check_pending_updates() {
    local check_mode="${1:-all}"
    local pending aur_pending=""
    AUR_RPC_CACHE=""
    AUR_RPC_CACHE_SET=false
    pending=$(LC_ALL=C pacman -Qu 2>/dev/null || true)

    if [[ "$check_mode" != "repo_only" && "${IS_OFFLINE_MODE:-false}" != "true" ]]; then
        if [[ "$HELPER_BIN" =~ ^(yay|paru|pikaur|trizen|pacaur|pakku)$ ]]; then
            aur_pending=$("${HELPER_CMD[@]}" -Qua --color never 2>/dev/null || true)
        else
            fetch_aur_updates_rpc
            aur_pending="$AUR_RPC_CACHE"
        fi

        if [[ -n "$aur_pending" ]]; then
            if [[ -n "$pending" ]]; then
                pending="$pending"$'\n'"$aur_pending"
            else
                pending="$aur_pending"
            fi
        fi
    fi

    if [[ -n "${ignored_pkgs:-}" && -n "$pending" ]]; then
        pending=$(echo "$pending" | awk -v ig="${ignored_pkgs:-}" '
            BEGIN { split(ig, a, "\n"); for (i in a) if(a[i] != "") ign[a[i]]=1 }
            { if (!ign[$1]) print $0 }
        ')
    fi
    echo "$pending"
}

BEST_UPDATE_TOOL=""
for tool in eos-update cachy-update arch-update; do
    if command -v "$tool" &>/dev/null; then
        BEST_UPDATE_TOOL="$tool"
        break
    fi
done

HAS_TOPGRADE=false
command -v topgrade &>/dev/null && HAS_TOPGRADE=true

if [[ "${IS_OFFLINE_MODE:-false}" == "true" && ${#CUSTOM_CMDS[@]} -eq 0 ]]; then
    PROMPT_CMD="sudo pacman -Su"
elif [[ ${#CUSTOM_CMDS[@]} -gt 0 ]]; then
    if [[ ${#CUSTOM_CMDS[@]} -eq 1 ]]; then
        PROMPT_CMD="${CUSTOM_CMDS[0]}"
    else
        PROMPT_CMD="Custom config (${#CUSTOM_CMDS[@]} commands)"
    fi
elif [[ -n "$BEST_UPDATE_TOOL" && "$HAS_TOPGRADE" == "true" ]]; then
    PROMPT_CMD="$BEST_UPDATE_TOOL && topgrade"
elif [[ -n "$BEST_UPDATE_TOOL" ]]; then
    PROMPT_CMD="$BEST_UPDATE_TOOL"
    [[ -n "$AUR_HELPER" ]] && PROMPT_CMD="$PROMPT_CMD (fallback: $HELPER_BIN)"
elif [[ "$HAS_TOPGRADE" == "true" ]]; then
    PROMPT_CMD="topgrade"
else
    if [[ "$HELPER_BIN" == "rua" ]]; then
        PROMPT_CMD="sudo pacman -Syu && rua upgrade"
    elif [[ "$HELPER_BIN" == "aura" ]]; then
        PROMPT_CMD="sudo pacman -Syu && aura -Aua"
    elif [[ -n "$AUR_HELPER" ]]; then
        PROMPT_CMD="$AUR_HELPER -Syu"
    else
        PROMPT_CMD="sudo pacman -Syu"
    fi
fi

sudo -v

echo -ne "\n${bold}${white}Apply updates?${reset} ${dim}(${PROMPT_CMD})${reset} [Y/n]: "
if ! read -r answer; then
    echo -e "${red}Input stream closed. Cancelling.${reset}\n"
    exit 1
fi

if [[ "$answer" =~ ^[Yy]$ || -z "$answer" ]]; then
    sudo -v
    echo -e "\n"
    if ! check_disk_space; then
        exit 1
    fi
    backup_pacman_db
    UPDATE_SUCCESS=false
    RUN_STANDARD=true

    if [[ ${#CUSTOM_CMDS[@]} -gt 0 ]]; then
        RUN_STANDARD=false

        has_pkg_mgr=false
        for cmd in "${CUSTOM_CMDS[@]}"; do
            if [[ "$cmd" =~ (pacman|yay|paru|eos-update|cachy-update|arch-update|topgrade|pikaur|trizen|aura|pacaur|pakku|rua) ]]; then
                has_pkg_mgr=true
                break
            fi
        done

        if [[ "$has_pkg_mgr" == false && -n "$(check_pending_updates)" ]]; then
            echo -e "${yellow}Warning: Your custom commands do not seem to include a system package manager.${reset}"
            echo -e "${dim}By default, custom commands OVERRIDE standard system updates.${reset}"
            echo -ne "${white}Would you like to also run standard updates AFTER your custom commands? [Y/n]: ${reset}"
            if read -r ans_std; then
                if [[ "$ans_std" =~ ^[Yy]$ || -z "$ans_std" ]]; then
                    RUN_STANDARD=true
                fi
            fi
            echo ""
        fi

        echo -e "${blue}${bold}Running custom update commands...${reset}\n"
        UPDATE_SUCCESS=true

        for cmd in "${CUSTOM_CMDS[@]}"; do
            echo -e "${dim}Executing: ${white}$cmd${reset}"
            execute_update_task "$cmd"
            core_exit=$?

            if [[ $core_exit -ne 0 ]]; then
                UPDATE_SUCCESS=false
                RUN_STANDARD=false
                echo -e "\n${red}Command failed with exit code $core_exit: $cmd${reset}"
                break
            fi
        done

        if $UPDATE_SUCCESS && [[ "$RUN_STANDARD" == false ]]; then
            check_mode="all"
            [[ -z "$AUR_HELPER" ]] && check_mode="repo_only"
            if [[ -n "$(check_pending_updates "$check_mode")" ]]; then
                echo -e "\n${yellow}Custom commands finished successfully, but standard pacman updates were skipped.${reset}"
                echo -e "${dim}To update the system too, answer 'Y' to the prompt or add 'yay -Syu' to CUSTOM_CMDS.${reset}"
            elif [[ -z "$AUR_HELPER" && -n "$(check_pending_updates)" ]]; then
                echo -e "\n${yellow}Custom commands finished successfully for official repository packages.${reset}"
                echo -e "${yellow}Note: AUR packages were skipped because no AUR helper is installed.${reset}"
            fi
        fi

        if $UPDATE_SUCCESS && $RUN_STANDARD; then
            echo -e "\n${green}Custom commands finished successfully. Moving to standard updates...${reset}\n"
        fi
    fi

    if $RUN_STANDARD; then
        PGP_SIG_ERROR_REGEX='(\[GNUPG:\]|\b(BADSIG|ERRSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY|KEYEXPIRED|SIGEXPIRED|KEYREVOKED|NODATA|TRUST_UNDEFINED)\b|\bGPGME(\s+error|_ERR_)|\([^)]*\b(PGP|GPG)\b[^)]*\)|\b(trustdb\.gpg|pubring\.(gpg|kbx)|pacman-key)\b)'

        if [[ "${IS_OFFLINE_MODE:-false}" == "true" ]]; then
            echo -e "${yellow}Offline mode active: Skipping keyring database sync and external update wrappers.${reset}\n"
            echo -e "${blue}${bold}Running offline system update (sudo pacman -Su)...${reset}"
            execute_update_task "sudo pacman -Su"
            core_exit=$?

            if [[ $core_exit -ne 0 && $core_exit -ne 130 && $core_exit -ne 143 && $core_exit -ne 2 ]]; then
                if printf '%s\n' "$LAST_TASK_OUTPUT" | grep -iqE "$PGP_SIG_ERROR_REGEX"; then
                    if fix_pacman_keyrings; then
                        echo -e "${blue}${bold}Retrying offline update after keyring hotfix...${reset}\n"
                        execute_update_task "sudo pacman -Su"
                        core_exit=$?
                    fi
                fi
            fi

            if [[ $core_exit -eq 0 && -z "$(check_pending_updates "repo_only")" ]]; then
                UPDATE_SUCCESS=true
                echo -e "\n${green}Official repository packages updated successfully from local cache.${reset}"
            else
                echo -e "\n${red}Offline update failed or left unapplied packages.${reset}"
            fi
        else
            echo -e "${blue}${bold}Updating keyrings to prevent signature errors...${reset}"
            keyrings=("archlinux-keyring")

            if pacman -Qq cachyos-keyring &>/dev/null; then
                keyrings+=("cachyos-keyring")
            fi
            if pacman -Qq cachyos-trusted &>/dev/null; then
                keyrings+=("cachyos-trusted")
            fi
            if pacman -Qq endeavouros-keyring &>/dev/null; then
                keyrings+=("endeavouros-keyring")
            fi

            sudo pacman -Sy --needed --noconfirm "${keyrings[@]}" 2>&1
            key_exit=$?

            if [[ $key_exit -eq 0 ]]; then
                echo -e "${green}Keyrings are up to date.${reset}\n"
            else
                echo -e "${yellow}Warning: Failed to update keyrings. Proceeding anyway...${reset}\n"
            fi

            if [[ -n "$BEST_UPDATE_TOOL" && "$HAS_TOPGRADE" == "true" ]]; then
                tool_name="$BEST_UPDATE_TOOL"

                echo -e "${blue}${bold}Running $tool_name (Keyrings & Packages)...${reset}"
                execute_update_task "$tool_name"
                core_exit=$?

                if [[ $core_exit -ne 0 && $core_exit -ne 130 && $core_exit -ne 143 && $core_exit -ne 2 ]]; then
                    if printf '%s\n' "$LAST_TASK_OUTPUT" | grep -iqE "$PGP_SIG_ERROR_REGEX"; then
                        if fix_pacman_keyrings; then
                            echo -e "${blue}${bold}Retrying $tool_name after keyring hotfix...${reset}\n"
                            execute_update_task "$tool_name"
                            core_exit=$?
                        fi
                    fi
                fi

                pending_updates=$(check_pending_updates "repo_only")

                if [[ $core_exit -eq 0 && -z "$pending_updates" ]]; then
                    echo -e "\n${green}Core updates applied successfully.${reset}"
                    echo -e "\n${blue}${bold}Running Topgrade (Firmware, Flatpaks, Dotfiles)...${reset}\n"
                    execute_update_task "topgrade"
                    topgrade_exit=$?
                    UPDATE_SUCCESS=true
                    if [[ $topgrade_exit -ne 0 ]]; then
                        echo -e "\n${yellow}Warning: Topgrade finished with exit code $topgrade_exit (some secondary updates may have been skipped).${reset}"
                    fi
                    if [[ -z "$AUR_HELPER" && -n "$(check_pending_updates)" ]]; then
                        echo -e "\n${yellow}Note: AUR packages were skipped because no AUR helper (e.g. yay/paru) is installed.${reset}"
                    fi
                else
                    echo -e "\n${yellow}$tool_name was cancelled or did not fully apply updates.${reset}"
                    echo -ne "${white}Run topgrade anyway? (Flatpaks/AUR etc) [y/N]: ${reset}"
                    read -r force_extra
                    if [[ "$force_extra" =~ ^[Yy]$ ]]; then
                        execute_update_task "topgrade"
                        topgrade_exit=$?
                        pending_repo_after=$(check_pending_updates "repo_only")
                        if [[ -z "$pending_repo_after" ]]; then
                            UPDATE_SUCCESS=true
                            if [[ $topgrade_exit -ne 0 ]]; then
                                echo -e "\n${yellow}Warning: Topgrade exited with code $topgrade_exit, but repository updates were successfully applied.${reset}"
                            fi
                            if [[ -z "$AUR_HELPER" && -n "$(check_pending_updates)" ]]; then
                                echo -e "\n${yellow}Note: AUR packages were skipped because no AUR helper (e.g. yay/paru) is installed.${reset}"
                            fi
                        else
                            echo -e "\n${red}Topgrade finished with exit code $topgrade_exit, and repository updates remain unapplied.${reset}"
                        fi
                    else
                        echo -e "${dim}Skipping extra updates.${reset}\n"
                    fi
                fi

            elif [[ -n "$BEST_UPDATE_TOOL" ]]; then
                tool_name="$BEST_UPDATE_TOOL"

                echo -e "${blue}${bold}Running $tool_name...${reset}\n"
                execute_update_task "$tool_name"
                core_exit=$?

                if [[ $core_exit -ne 0 && $core_exit -ne 130 && $core_exit -ne 143 && $core_exit -ne 2 ]]; then
                    if printf '%s\n' "$LAST_TASK_OUTPUT" | grep -iqE "$PGP_SIG_ERROR_REGEX"; then
                        if fix_pacman_keyrings; then
                            echo -e "${blue}${bold}Retrying $tool_name after keyring hotfix...${reset}\n"
                            execute_update_task "$tool_name"
                            core_exit=$?
                        fi
                    fi
                fi

                pending_updates=$(check_pending_updates)
                pending_repo=$(check_pending_updates "repo_only")

                if [[ $core_exit -eq 0 && -z "$pending_updates" ]]; then
                    UPDATE_SUCCESS=true
                elif [[ $core_exit -eq 0 && -z "$pending_repo" ]]; then
                    if [[ -z "$AUR_HELPER" ]]; then
                        UPDATE_SUCCESS=true
                        echo -e "\n${yellow}Official repository packages updated successfully via $tool_name.${reset}"
                        echo -e "${yellow}Note: AUR packages were skipped because no AUR helper (e.g. yay/paru) is installed.${reset}"
                    else
                        aur_flags="-Syu"
                        if [[ "$HELPER_BIN" =~ ^(yay|paru|pikaur|trizen|pacaur|pakku)$ ]]; then
                            aur_flags="-Sua"
                        elif [[ "$HELPER_BIN" == "aura" ]]; then
                            aur_flags="-Aua"
                        elif [[ "$HELPER_BIN" == "rua" ]]; then
                            aur_flags="upgrade"
                        fi

                        echo -ne "${white}Run $HELPER_BIN to apply remaining updates? [Y/n]: ${reset}"
                        if read -r force_aur; then
                            if [[ "$force_aur" =~ ^[Yy]$ || -z "$force_aur" ]]; then
                                execute_update_task "$AUR_HELPER $aur_flags"
                                aur_task_exit=$?

                                if [[ $aur_task_exit -eq 0 && -z "$(check_pending_updates)" ]]; then
                                    UPDATE_SUCCESS=true
                                else
                                    echo -e "\n${red}Some updates are still pending or failed.${reset}"
                                fi
                            else
                                UPDATE_SUCCESS=true
                                echo -e "\n${yellow}Official repository packages updated successfully. AUR updates skipped by user.${reset}"
                            fi
                        fi
                    fi
                else
                    if [[ $core_exit -ne 0 ]]; then
                        echo -e "\n${red}Core repository updates were not fully applied by $tool_name (exit code: $core_exit).${reset}"
                    elif [[ -n "$pending_repo" ]]; then
                        echo -e "\n${red}Repository updates remain unapplied after running $tool_name.${reset}"
                    fi
                fi

            elif [[ "$HAS_TOPGRADE" == "true" ]]; then
                echo -e "${blue}${bold}Running Topgrade (System, AUR, Firmware, etc.)...${reset}\n"
                execute_update_task "topgrade"
                topgrade_exit=$?

                if [[ $topgrade_exit -ne 0 && $topgrade_exit -ne 130 && $topgrade_exit -ne 143 && $topgrade_exit -ne 2 ]]; then
                    if printf '%s\n' "$LAST_TASK_OUTPUT" | grep -iqE "$PGP_SIG_ERROR_REGEX"; then
                        if fix_pacman_keyrings; then
                            echo -e "${blue}${bold}Retrying Topgrade after keyring hotfix...${reset}\n"
                            execute_update_task "topgrade"
                            topgrade_exit=$?
                        fi
                    fi
                fi

                pending_repo=$(check_pending_updates "repo_only")
                pending_all=$(check_pending_updates "all")
                if [[ $topgrade_exit -eq 0 && -z "$pending_all" ]]; then
                    UPDATE_SUCCESS=true
                elif [[ $topgrade_exit -eq 0 && -z "$pending_repo" ]]; then
                    UPDATE_SUCCESS=true
                    if [[ -z "$AUR_HELPER" ]]; then
                        echo -e "\n${yellow}Official repository packages updated successfully via Topgrade.${reset}"
                        echo -e "${yellow}Note: AUR packages were skipped because no AUR helper (e.g. yay/paru) is installed.${reset}"
                    else
                        echo -e "\n${yellow}Official repository packages updated successfully via Topgrade.${reset}"
                        echo -e "${yellow}Note: Some AUR package updates remain unapplied.${reset}"
                    fi
                else
                    echo -e "\n${red}Topgrade finished with exit code $topgrade_exit or system updates remain unapplied.${reset}"
                fi

            else
                echo -e "${blue}${bold}Running standard system update...${reset}"
                std_update_cmd=""
                if [[ -n "$AUR_HELPER" ]]; then
                    if [[ "$HELPER_BIN" == "rua" ]]; then
                        std_update_cmd="sudo pacman -Syu && rua upgrade"
                    elif [[ "$HELPER_BIN" == "aura" ]]; then
                        std_update_cmd="sudo pacman -Syu && aura -Aua"
                    else
                        std_update_cmd="$AUR_HELPER -Syu"
                    fi
                else
                    std_update_cmd="sudo pacman -Syu"
                fi

                execute_update_task "$std_update_cmd"
                core_exit=$?

                if [[ $core_exit -ne 0 && $core_exit -ne 130 && $core_exit -ne 143 && $core_exit -ne 2 ]]; then
                    if printf '%s\n' "$LAST_TASK_OUTPUT" | grep -iqE "$PGP_SIG_ERROR_REGEX"; then
                        if fix_pacman_keyrings; then
                            echo -e "${blue}${bold}Retrying system update after keyring hotfix...${reset}\n"
                            execute_update_task "$std_update_cmd"
                            core_exit=$?
                        fi
                    fi
                fi

                if [[ $core_exit -eq 0 && -z "$(check_pending_updates)" ]]; then
                    UPDATE_SUCCESS=true
                elif [[ $core_exit -eq 0 && -z "$AUR_HELPER" && -z "$(check_pending_updates "repo_only")" ]]; then
                    UPDATE_SUCCESS=true
                    echo -e "\n${yellow}Official repository packages updated successfully.${reset}"
                    echo -e "${yellow}Note: AUR packages were skipped because no AUR helper is installed.${reset}"
                fi
            fi
        fi
    fi

    if $UPDATE_SUCCESS; then
        remaining_pkgs=$(check_pending_updates "all" 2>/dev/null || true)
        if acquire_state_lock "x"; then
            if [[ -n "$remaining_pkgs" ]]; then
                rem_count=$(grep -c . <<< "$remaining_pkgs")
                echo "$rem_count" > "$CONFIG_DIR/updates.cache"
            else
                rm -f "$CONFIG_DIR/updates.cache"
            fi
            rm -f "$CONFIG_DIR/next_check.conf"
            release_state_lock
        fi

        if [[ "${ENABLE_BACKGROUND_CHECK,,}" == "true" ]] && command -v systemctl >/dev/null 2>&1; then
            sync_daemon_state >/dev/null 2>&1
        fi

        echo -e "\n${green}Update process finished successfully.${reset}"

        if [[ "${ENABLE_POST_CLEANUP,,}" == "true" ]]; then
            echo -e "\n${blue}${bold}Performing post-update system cleanup...${reset}"

            orphans=$(pacman -Qdtq 2>/dev/null)
            if [[ -n "$orphans" ]]; then
                echo -e "${dim}Removing orphaned packages...${reset}"
                printf "%s\n" "$orphans" | xargs -r -o sudo pacman -Rns
            else
                echo -e "${dim}No orphaned packages to remove.${reset}"
            fi

            echo -e "${dim}Clearing partial downloads and package cache...${reset}"
            sudo rm -rf /var/cache/pacman/pkg/download-* 2>/dev/null
            if [[ -n "$AUR_HELPER" ]]; then
                $AUR_HELPER -Sc --noconfirm >/dev/null 2>&1
            else
                sudo pacman -Sc --noconfirm >/dev/null 2>&1
            fi

            helpers_to_clean=()
            
            if [[ -n "$HELPER_BIN" ]]; then
                helpers_to_clean+=("$HELPER_BIN")
            fi
            
            for h in "yay" "paru" "pikaur" "trizen" "pacaur" "pakku" "aura" "rua"; do
                if [[ "$h" != "$HELPER_BIN" ]]; then
                    helpers_to_clean+=("$h")
                fi
            done

            user_cache_dir="${XDG_CACHE_HOME:-$USER_HOME/.cache}"
            if [[ -n "$user_cache_dir" && "$user_cache_dir" != "/" && -d "$user_cache_dir" ]]; then
                cleaned_aur="false"
                for h in "${helpers_to_clean[@]+"${helpers_to_clean[@]}"}"; do
                    if [[ -n "$h" && -d "$user_cache_dir/$h" ]]; then
                        if [[ "$cleaned_aur" == "false" ]]; then
                            echo -e "${dim}Clearing AUR helper build caches...${reset}"
                            cleaned_aur="true"
                        fi
                        rm -rf -- "${user_cache_dir:?}/${h:?}" 2>/dev/null
                    fi
                done

                if [[ -d "$user_cache_dir/thumbnails" ]]; then
                    echo -e "${dim}Clearing user thumbnail cache...${reset}"
                    find "$user_cache_dir/thumbnails" -mindepth 1 -delete 2>/dev/null
                fi
            fi

            if command -v flatpak >/dev/null 2>&1; then
                echo -e "${dim}Removing unused Flatpak runtimes...${reset}"
                flatpak uninstall --unused -y >/dev/null 2>&1
            fi

            echo -e "${dim}Vacuuming systemd journal (keeping 100M)...${reset}"
            sudo journalctl --vacuum-size=100M >/dev/null 2>&1

            echo -e "${green}System cleanup complete!${reset}\n"
        else
            echo ""
        fi
        check_aur_rebuild_needed
        check_reboot_needed
    else
        echo -e "\n${red}Update process completed with errors, partial updates, or was cancelled.${reset}\n"
    fi

else
    echo -e "${yellow}Operation cancelled.${reset}\n"
fi

if [[ "$DAEMON_MODE" == "false" ]] && [ -t 0 ]; then
    if [[ "${GENERATE_LOGS,,}" == "true" && -n "${LOG_FILE:-}" ]]; then
        echo -e "${green}Log was written to ${white}$LOG_FILE${reset}"
    fi

    if [[ "${ASU_SPAWNED:-}" == "true" ]]; then
        echo -ne "${gray}Press Enter to close terminal.${reset}"
    else
        echo -ne "${gray}Press Enter to finish update.${reset}"
    fi

    read -r </dev/tty 2>/dev/null || read -r
    trap - EXIT INT TERM
    cleanup
fi

sleep 0.1
exit 0
