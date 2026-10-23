#!/usr/bin/env bash
# Hydroneer Co-op uninstaller for Linux: removes what install.sh added (dwmapi.dll and the ue4ss
# folder it created). Works from any copy of this package: it finds the game in your Steam
# libraries when this folder has no installed-linux.txt. Save backups stay in backups/.
#   bash uninstall.sh [--game-dir DIR]
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="HydroneerCoop-installed.txt"
MF="$PKG/installed-linux.txt"
GAME_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --save-root) shift 2 ;;   # accepted for symmetry with install.sh; not used
        --yes) shift ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done

# where is the game? this folder's record first, else the same search install.sh uses
W64=""
[ -f "$MF" ] && W64="$(sed -n 's/^win64=//p' "$MF")"
if [ -z "$W64" ] || [ ! -f "$W64/ue4ss/$MARKER" ]; then
    da=(--detect); [ -n "$GAME_DIR" ] && da+=(--game-dir "$GAME_DIR")
    g="$(bash "$PKG/install.sh" "${da[@]}" | sed -n 's/^GAME=//p')"
    [ -n "$g" ] && W64="$g/Mining/Binaries/Win64"
fi
if [ -z "$W64" ]; then echo "Could not find Hydroneer in your Steam libraries. Run: bash uninstall.sh --game-dir \"/path/to/steamapps/common/Hydroneer\""; exit 1; fi
if [ ! -f "$W64/ue4ss/$MARKER" ]; then
    if [ -d "$W64/ue4ss" ]; then echo "The ue4ss folder in $W64 was not installed by Hydroneer Co-op. Not touching it."
    else echo "Hydroneer Co-op is not installed in $W64. Nothing to remove."; fi
    rm -f "$MF"
    exit 1
fi

# what did we install? this folder's record, else the copy kept in the game's ue4ss folder,
# else (installs from before that copy existed) the dwmapi.dll this package ships
WANT=""
for m in "$MF" "$W64/ue4ss/HydroneerCoop-installed-linux.txt"; do
    if [ -f "$m" ]; then WANT="$(awk '$2 == "dwmapi.dll" {print $1}' "$m")"; break; fi
done
[ -z "$WANT" ] && WANT="$(sha256sum "$PKG/files/dwmapi.dll" | cut -d' ' -f1)"

# dwmapi.dll: only if it is still the file we installed
if [ -f "$W64/dwmapi.dll" ]; then
    if [ "$(sha256sum "$W64/dwmapi.dll" | cut -d' ' -f1)" = "$WANT" ]; then
        rm "$W64/dwmapi.dll"; echo "removed dwmapi.dll"
    else
        echo "dwmapi.dll was changed since install (another mod?). Left in place."
    fi
fi
# the ue4ss folder is ours (marker): it also holds logs and caches written while playing
rm -rf "$W64/ue4ss"
echo "removed $W64/ue4ss"
rm -f "$MF"
echo "Uninstalled. Save backups are still in $PKG/backups."
echo "Also remove the Launch Options line in Steam (WINEDLLOVERRIDES=...) for Hydroneer."
