#!/usr/bin/env bash
# Hydroneer Co-op menu for Linux: install, uninstall, host, join, logs, read me.
# Graphical with zenity when it is available; otherwise a text menu in this terminal.
# The separate scripts (install.sh, uninstall.sh, host.sh, join.sh) still work on their own.
#   bash hydroneer-coop.sh            (HC_TEXT=1 forces the text menu)
set -uo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PKG"
RELAY_ARGS=()
# test hook: extra relay arguments (for example --transport mocksteam ...)
if [ -n "${HC_RELAY_ARGS:-}" ]; then read -r -a RELAY_ARGS <<< "$HC_RELAY_ARGS"; fi
INSTALL_ARGS=()
if [ -n "${HC_INSTALL_ARGS:-}" ]; then read -r -a INSTALL_ARGS <<< "$HC_INSTALL_ARGS"; fi

GUI=0
if [ "${HC_TEXT:-0}" != 1 ] && command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then GUI=1; fi
TITLE="Hydroneer Co-op 0.3"

installed() { bash "$PKG/install.sh" --detect "${INSTALL_ARGS[@]}" 2>/dev/null | grep -qx 'INSTALLED=yes'; }   # the game folder decides

status_text() {
    local g v
    g="$(bash "$PKG/install.sh" --detect "${INSTALL_ARGS[@]}" 2>/dev/null | sed -n 's/^GAME=//p')"
    v="$(bash "$PKG/install.sh" --detect "${INSTALL_ARGS[@]}" 2>/dev/null | sed -n 's/^VERSION=//p')"
    if [ -n "$g" ]; then echo "Hydroneer: $g"; else echo "Hydroneer: not found in your Steam libraries"; fi
    case "$v" in
        match) echo "Game version: the tested one (Steam build 23218978)" ;;
        mismatch) echo "Game version: DIFFERENT from the tested one (may not work; both players need the same)" ;;
        *) echo "Game version: unknown" ;;
    esac
    if installed; then echo "Co-op: installed"; else echo "Co-op: not installed"; fi
}

show() {   # title, text
    if [ "$GUI" = 1 ]; then printf '%s\n' "$2" | zenity --text-info --title "$TITLE - $1" --width 700 --height 450 2>/dev/null
    else printf '\n%s\n' "$2"; fi
}
confirm() {   # question
    if [ "$GUI" = 1 ]; then zenity --question --title "$TITLE" --text "$1" --width 420 2>/dev/null
    else read -r -p "$1 (y/N) " a; [[ "$a" =~ ^([yY]|[yY][eE][sS])$ ]]; fi
}

do_install() {
    local out rc
    out="$(bash "$PKG/install.sh" --non-interactive "${INSTALL_ARGS[@]}" 2>&1)"; rc=$?
    if [ "$rc" = 3 ]; then
        if confirm "Your Hydroneer version is not the one this was tested with. It may crash at start, and both players need the same version. Install anyway?"; then
            out="$(bash "$PKG/install.sh" --non-interactive --yes "${INSTALL_ARGS[@]}" 2>&1)"; rc=$?
        else
            out="$out"$'\n'"Nothing changed."
        fi
    fi
    show "Install" "$out"
}

do_uninstall() {
    confirm "Remove Hydroneer Co-op from the game folder? Your save backups stay in the backups folder." || return
    show "Uninstall" "$(bash "$PKG/uninstall.sh" "${INSTALL_ARGS[@]}" 2>&1)"
}

do_connect() {   # host | join
    local role="$1" extra=()
    if [ "$role" = join ]; then
        local lobby=""
        if [ "$GUI" = 1 ]; then
            lobby="$(zenity --entry --title "$TITLE - Join" --text "Lobby number (leave empty to find your friend automatically):" 2>/dev/null)" || return
        else
            read -r -p "Lobby number (Enter = find your friend automatically): " lobby
        fi
        [[ "$lobby" =~ ^[0-9]+$ ]] && extra=(--lobby "$lobby")
    fi
    rm -f "$PKG/run/stop.txt"
    if [ "$GUI" = 1 ]; then
        # live log in a window; closing the window stops the connection cleanly (stop file)
        bash "$PKG/$role.sh" "${extra[@]}" "${RELAY_ARGS[@]}" 2>&1 \
            | zenity --text-info --auto-scroll --title "$TITLE - $role (close this window to stop)" --width 760 --height 480 2>/dev/null
        mkdir -p "$PKG/run"; touch "$PKG/run/stop.txt"
        sleep 1
    else
        echo "Starting the connection. When it is ready: start Hydroneer, start a NEW game, press F7 in the world."
        echo "Press Ctrl+C here to stop it."
        trap 'touch "$PKG/run/stop.txt"' INT
        bash "$PKG/$role.sh" "${extra[@]}" "${RELAY_ARGS[@]}"
        trap - INT
    fi
}

do_logs() {
    mkdir -p "$PKG/logs"
    if command -v xdg-open >/dev/null 2>&1 && [ "$GUI" = 1 ]; then xdg-open "$PKG/logs" >/dev/null 2>&1 &
    else show "Logs" "Logs are in: $PKG/logs"$'\n'"Also send: <Hydroneer folder>/Mining/Binaries/Win64/ue4ss/UE4SS.log"; fi
}

while true; do
    st="$(status_text)"
    if [ "$GUI" = 1 ]; then
        choice="$(zenity --list --title "$TITLE" --text "$st" --column "Choose" \
            "Install" "Uninstall" "Host" "Join" "Open logs" "Read me" "Quit" --width 560 --height 420 2>/dev/null)" || exit 0
    else
        printf '\n=== %s ===\n%s\n\n  1) Install\n  2) Uninstall\n  3) Host\n  4) Join\n  5) Open logs\n  6) Read me\n  7) Quit\n' "$TITLE" "$st"
        read -r -p "Choose 1-7: " n || exit 0
        case "$n" in 1) choice=Install ;; 2) choice=Uninstall ;; 3) choice=Host ;; 4) choice=Join ;;
                     5) choice="Open logs" ;; 6) choice="Read me" ;; *) choice=Quit ;; esac
    fi
    case "$choice" in
        Install) if installed; then show "Install" "Already installed."; else do_install; fi ;;
        Uninstall) if installed; then do_uninstall; else show "Uninstall" "Not installed."; fi ;;
        Host) if installed; then do_connect host; else show "Host" "Install first."; fi ;;
        Join) if installed; then do_connect join; else show "Join" "Install first."; fi ;;
        "Open logs") do_logs ;;
        "Read me") if [ "$GUI" = 1 ]; then zenity --text-info --title "$TITLE - Read me" --filename "$PKG/README.txt" --width 760 --height 600 2>/dev/null; else cat "$PKG/README.txt"; fi ;;
        *) exit 0 ;;
    esac
done
