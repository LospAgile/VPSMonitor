#!/bin/sh
set -eu
AWK=${1:-"$(dirname "$0")/health-history.awk"}
run() { got=$(printf '%s\n' "$1" | awk -v now="$2" -v interval=60 -f "$AWK"); [ "$got" = "$3" ] || { echo "FAIL: got=$got expected=$3" >&2; exit 1; }; }
run '1940 true boot
2000 false boot' 2000 '1 60 1940'
run '1900 true boot
2000 false boot' 2000 '0 0 1900'
run '1940 true boot
2000 false rebooted' 2000 '0 0 1940'
run '1000 true boot
2000 false boot' 3000 '0 0 1000'
echo 'health-history tests passed (transition, long gap, reboot, expired window)'
