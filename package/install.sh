#!/usr/bin/env bash
# Hydroneer Co-op (CoopNet) installer for Linux (Hydroneer runs through Steam's Proton).
# Adds UE4SS (experimental build) and the CoopNet mod to Hydroneer's Win64 folder, after backing
# up your Proton save folder. Undo with uninstall.sh.
#   bash install.sh [--game-dir DIR] [--save-root DIR] [--yes] [--detect] [--non-interactive]
#   --detect: only print GAME=<dir> and VERSION=match|mismatch|missing, change nothing
#   --non-interactive: never ask; on a version mismatch exit with code 3 (the menu asks)
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTED_EXE="df27b86e4564100fa792464ea625f64c96c4d155c6c911486fe3769c8d5570b1"   # Steam build 23218978
MARKER="HydroneerCoop-installed.txt"
GAME_DIR=""; SAVE_ROOT=""; YES=0; DETECT=0; NONINT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --save-root) SAVE_ROOT="$2"; shift 2 ;;
        --yes) YES=1; shift ;;
        --detect) DETECT=1; shift ;;
        --non-interactive) NONINT=1; shift ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done

ask() {
    [ "$YES" = 1 ] && return 0
    read -r -p "$1 (y/N) " a
    [[ "$a" =~ ^([yY]|[yY][eE][sS])$ ]]
}

find_game() {
    # Steam's usual homes: native, Flatpak, Snap
    local root lib acf dir
    for root in "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
                "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "$HOME/snap/steam/common/.local/share/Steam"; do
        [ -d "$root/steamapps" ] || continue
        local libs=("$root")
        if [ -f "$root/steamapps/libraryfolders.vdf" ]; then
            while IFS= read -r lib; do libs+=("$lib"); done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$root/steamapps/libraryfolders.vdf")
        fi
        for lib in "${libs[@]}"; do
            acf="$lib/steamapps/appmanifest_1106840.acf"
            if [ -f "$acf" ]; then
                dir="$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"/\1/p' "$acf" | head -n1)"
                echo "$lib/steamapps/common/$dir"
                return 0
            fi
        done
    done
    return 1
}

if [ -z "$GAME_DIR" ]; then
    GAME_DIR="$(find_game || true)"
fi
if [ -z "$GAME_DIR" ]; then
    if [ "$DETECT" = 1 ]; then echo "GAME="; echo "VERSION=missing"; echo "INSTALLED=no"; exit 0; fi
    echo "Could not find Hydroneer in your Steam libraries. Run: bash install.sh --game-dir \"/path/to/steamapps/common/Hydroneer\""
    exit 1
fi
W64="$GAME_DIR/Mining/Binaries/Win64"
EXE="$W64/Mining-Win64-Shipping.exe"
if [ ! -f "$EXE" ]; then
    if [ "$DETECT" = 1 ]; then echo "GAME=$GAME_DIR"; echo "VERSION=missing"; echo "INSTALLED=no"; exit 0; fi
    echo "This does not look like a Hydroneer install (no $EXE)."; exit 1
fi
HASH="$(sha256sum "$EXE" | cut -d' ' -f1)"
if [ "$DETECT" = 1 ]; then
    echo "GAME=$GAME_DIR"; [ "$HASH" = "$TESTED_EXE" ] && echo "VERSION=match" || echo "VERSION=mismatch"
    [ -f "$W64/ue4ss/$MARKER" ] && echo "INSTALLED=yes" || echo "INSTALLED=no"; exit 0
fi
echo "Hydroneer found: $GAME_DIR"

if [ "$HASH" != "$TESTED_EXE" ]; then
    echo "WARNING: your Hydroneer version is not the one this was tested with (Steam build 23218978)."
    echo "It may still work, or it may crash at start. Both players need the same game version."
    if [ "$NONINT" = 1 ] && [ "$YES" = 0 ]; then echo "VERSION_MISMATCH: nothing changed."; exit 3; fi
    ask "Install anyway?" || { echo "Nothing changed."; exit 1; }
fi

if [ -f "$W64/ue4ss/$MARKER" ]; then echo "Hydroneer Co-op is already installed in $W64. Nothing changed (use Uninstall first to reinstall)."; exit 1; fi
for n in dwmapi.dll ue4ss UE4SS.dll xinput1_3.dll; do
    if [ -e "$W64/$n" ]; then
        echo "Another mod is already using $n in $W64."
        echo "This installer does not touch other mods. Remove that mod first, then run install.sh again."
        echo "Nothing changed."
        exit 1
    fi
done

# 1. back up saves and settings (they live inside Proton's prefix for the game, next to the library)
if [ -z "$SAVE_ROOT" ]; then
    SAVE_ROOT="$(dirname "$(dirname "$GAME_DIR")")/compatdata/1106840/pfx/drive_c/users/steamuser/AppData/Local/Mining/Saved"
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="$PKG/backups/Saved-$STAMP"
mkdir -p "$BAK"
COPIED=0
for sub in SaveGames Config; do
    if [ -d "$SAVE_ROOT/$sub" ]; then
        cp -a "$SAVE_ROOT/$sub" "$BAK/$sub"
        COPIED=$((COPIED + $(find "$BAK/$sub" -type f | wc -l)))
    fi
done
if [ "$COPIED" = 0 ]; then
    echo "No saves found at $SAVE_ROOT (fine if you never played it on this PC)."
else
    echo "Backed up $COPIED save/settings files to $BAK"
fi

# 2. copy UE4SS and the mod
cp -a "$PKG/files/dwmapi.dll" "$W64/"
cp -a "$PKG/files/ue4ss" "$W64/ue4ss"

# 3. tell the mod where this package's run folder is; the game sees Linux paths under Z: in Proton
RUN="$PKG/run"
mkdir -p "$RUN"
printf 'return { run_dir = "Z:%s" }\n' "$RUN" > "$W64/ue4ss/Mods/CoopNet/Scripts/coopnet_config.lua"

# 4. record what we added, so uninstall.sh removes exactly that
MF="$PKG/installed-linux.txt"
{
    echo "win64=$W64"
    echo "backup=$BAK"
    echo "installed=$STAMP"
    (cd "$W64" && sha256sum dwmapi.dll && find ue4ss -type f -print0 | sort -z | xargs -0 sha256sum)
} > "$MF"
cp "$MF" "$W64/ue4ss/HydroneerCoop-installed-linux.txt"   # so any package copy can uninstall
echo "Installed by Hydroneer Co-op from $PKG on $STAMP" > "$W64/ue4ss/$MARKER"
echo "Installed $(($(wc -l < "$MF") - 3)) files into $W64"
echo
echo "ONE MORE STEP (Proton needs it to load the mod):"
echo "  Steam > Library > right-click Hydroneer > Properties > General > Launch Options, paste:"
echo
echo '      WINEDLLOVERRIDES="dwmapi=n,b" %command%'
echo
echo "Then: bash host.sh (the host) or bash join.sh (the friend). See README.txt."
