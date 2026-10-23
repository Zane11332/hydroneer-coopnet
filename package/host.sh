#!/usr/bin/env bash
# Hydroneer Co-op: host. Creates a friends-only Steam lobby; keep this terminal open while playing.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$PKG/installed-linux.txt" ]; then echo "Run: bash install.sh first."; exit 1; fi
if ! command -v python3 >/dev/null; then echo "python3 is needed (it comes with most Linux systems; install it with your package manager)."; exit 1; fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' || { echo "python3 3.7 or newer is needed."; exit 1; }
mkdir -p "$PKG/logs"
cd "$PKG/relay"
exec python3 -u -I coopnet_relay.py --role host --transport steam --run-dir "$PKG/run" --log "$PKG/logs/relay-host.log" --stop-file "$PKG/run/stop.txt" "$@"
