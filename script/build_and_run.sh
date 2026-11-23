#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Desktop can be iCloud-backed; Finder metadata can invalidate strict signing.
APP_BUNDLE="${VPSMONITOR_APP_DIR:-$HOME/Library/Caches/VPSMonitor/Builds/VPSMonitor Proview.app}"
case "$MODE" in run|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2;; esac
# Stop only this bundle; a preview must never terminate the daily app.
TARGET_EXE="$APP_BUNDLE/Contents/MacOS/VPSMonitor"
while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill "$pid"
done < <(ps -axo pid=,comm= | awk -v target="$TARGET_EXE" '{pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == target) print pid}')
VPSMONITOR_APP_DIR="$APP_BUNDLE" VPSMONITOR_BUNDLE_ID="${VPSMONITOR_BUNDLE_ID:-local.komari.monitor.preview}" "$ROOT_DIR/scripts/build-app.sh"
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/VPSMonitor" ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "VPSMonitor"'
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE" --args --show
    sleep 2
    ps -axo comm= | /usr/bin/grep -Fx "$TARGET_EXE" >/dev/null
    echo "VPSMonitor launched: $APP_BUNDLE"
    ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
