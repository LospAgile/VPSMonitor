#!/bin/ash
# Read-only probes; state lives on the configured data partition, latest in tmpfs.
set -u
umask 077
CONFIG=${HEALTH_CONFIG:-/etc/vpsmonitor/health-collector.conf}
LIB=${HEALTH_JSON_LIBRARY:-/usr/share/libubox/jshn.sh}
HISTORY_AWK=${HEALTH_HISTORY_AWK:-/usr/lib/vpsmonitor/health-history.awk}
PROBES_LIBRARY=${HEALTH_PROBES_LIBRARY:-/usr/lib/vpsmonitor/health-probes.sh}
# jshn.sh expects this namespace to be initialized by callers on OpenWrt.
JSON_PREFIX=${JSON_PREFIX:-}
MODE=${1:-}
die() { echo "vpsmonitor-health: $*" >&2; exit 1; }
[ -r "$CONFIG" ] || die 'missing configuration'
. "$CONFIG"
: "${OUTPUT_DIR:=/tmp/vpsmonitor-network}"
: "${HISTORY_DIR:=/var/lib/vpsmonitor-network}"
: "${INTERVAL_SECONDS:=60}"
: "${PING_COUNT:=2}"
: "${TIMEOUT_SECONDS:=3}"
: "${DNS_NAME:=example.com}"
: "${DNS_SERVER:=}"
: "${WAN_INTERFACE:=wan}"
: "${GATEWAY_TARGET:=auto}"
: "${NPS_TARGET:=}"
: "${NPS_PORT:=8024}"
: "${PROBE_FILE:=/etc/vpsmonitor/probes.conf}"
integer() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
hostname_ok() { case "$1" in ''|-*|*[!a-zA-Z0-9.:-]*) return 1;; *) return 0;; esac; }
integer "$INTERVAL_SECONDS" && [ "$INTERVAL_SECONDS" -ge 30 ] && [ "$INTERVAL_SECONDS" -le 600 ] || die 'interval must be 30..600 seconds'
integer "$PING_COUNT" && [ "$PING_COUNT" -ge 1 ] && [ "$PING_COUNT" -le 5 ] || die 'ping count must be 1..5'
integer "$TIMEOUT_SECONDS" && [ "$TIMEOUT_SECONDS" -ge 1 ] && [ "$TIMEOUT_SECONDS" -le 5 ] || die 'timeout must be 1..5 seconds'
hostname_ok "$DNS_NAME" && hostname_ok "$NPS_TARGET" || die 'invalid DNS/NPS target'
[ -z "$DNS_SERVER" ] || hostname_ok "$DNS_SERVER" || die 'invalid DNS server'
integer "$NPS_PORT" && [ "$NPS_PORT" -ge 1 ] && [ "$NPS_PORT" -le 65535 ] || die 'invalid NPS port'
[ "$GATEWAY_TARGET" = auto ] || hostname_ok "$GATEWAY_TARGET" || die 'invalid gateway'
case "$WAN_INTERFACE" in ''|*[!a-zA-Z0-9_-]*) die 'invalid WAN interface';; esac
[ -r "$PROBE_FILE" ] && [ -r "$HISTORY_AWK" ] && [ -r "$LIB" ] && [ -r "$PROBES_LIBRARY" ] || die 'missing probes/history/json support'
probe_count=0
while IFS='|' read -r id label kind target port; do
    case "$id" in ''|\#*) continue;; esac
    case "$id" in *[!a-zA-Z0-9_-]*) die 'invalid probe id';; esac
    case "$kind" in
        ping) [ -z "$port" ] || die 'ICMP probes must not have a port';;
        ssh) integer "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die 'invalid SSH probe port';;
        *) die 'probe kind must be ping or ssh';;
    esac
    hostname_ok "$target" || die 'invalid probe target'
    probe_count=$((probe_count+1)); [ "$probe_count" -le 16 ] || die 'at most 16 probes'
done < "$PROBE_FILE"
[ "$MODE" = --check-config ] && { echo 'config ok'; exit 0; }
# jshn uses intentionally unset shell variables; do not expose it to ash nounset.
set +u
. "$LIB"
# jshn functions also inspect unset scratch variables during each JSON call.
mkdir -p "$OUTPUT_DIR" "$HISTORY_DIR" || die 'cannot create state directory'
LOCK="$OUTPUT_DIR/collector.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    oldpid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if integer "$oldpid" && kill -0 "$oldpid" 2>/dev/null; then die 'collector already running'; fi
    rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" || die 'cannot acquire collector lock'
fi
printf '%s\n' "$$" > "$LOCK/pid"
WORK="$OUTPUT_DIR/work.$$"; mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 0' INT TERM
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
HISTORY="$HISTORY_DIR/observations.tsv"
. "$PROBES_LIBRARY"
add_bool() { if [ "$2" = true ] || [ "$2" = false ]; then json_add_boolean "$1" "$([ "$2" = true ] && echo 1 || echo 0)"; else json_add_null "$1"; fi; }
add_number() { if [ "$2" = null ]; then json_add_null "$1"; else json_add_double "$1" "$2"; fi; }
add_probe() {
    json_add_object ''
    json_add_string id "$1"; json_add_string label "$2"; json_add_string kind "$3"; json_add_string target "$4"
    add_bool ok "$5"; add_number latency_ms "$6"; add_number loss_percent "$7"
    json_close_object
}
collect() {
    cycle_start=$(date +%s)
    gateway=$GATEWAY_TARGET
    [ "$gateway" != auto ] || gateway=$(ip -4 route show default 2>/dev/null | awk '/ via / {print $3;exit}')
    if hostname_ok "$gateway"; then set -- $(ping_result "$gateway"); gwok=$1; gwlat=$2; gwloss=$3
    else gwok=null; gwlat=null; gwloss=null; fi
    dnsok=null
    if command -v nslookup >/dev/null 2>&1; then
        if [ -n "$DNS_SERVER" ]; then bounded "$WORK/dns" nslookup "$DNS_NAME" "$DNS_SERVER" && dnsok=true || dnsok=false
        else bounded "$WORK/dns" nslookup "$DNS_NAME" && dnsok=true || dnsok=false; fi
    fi
    npsrunning=false; pidof npc >/dev/null 2>&1 && npsrunning=true
    npsok=null
    if command -v netstat >/dev/null 2>&1; then
        npsok=false
        netstat -nt 2>/dev/null | awk -v endpoint="$NPS_TARGET:$NPS_PORT" '$5==endpoint && $6=="ESTABLISHED" {found=1} END {exit !found}' && npsok=true
    fi
    json_init; json_add_array probes
    add_probe gateway '上级网关' ping "$gateway" "$gwok" "$gwlat" "$gwloss"
    add_probe dns 'DNS解析' dns "$DNS_NAME" "$dnsok" null null
    add_probe nps 'NPS连接' tcp-session "$NPS_TARGET:$NPS_PORT" "$npsok" null null
    while IFS='|' read -r id label kind target port; do
        case "$id" in ''|\#*) continue;; esac
        if [ "$kind" = ssh ]; then
            set -- $(ssh_result "$target" "$port")
            case "$target" in *:*) target="[$target]:$port";; *) target="$target:$port";; esac
        else set -- $(ping_result "$target"); fi
        add_probe "$id" "$label" "$kind" "$target" "$1" "$2" "$3"
    done < "$PROBE_FILE"
    json_close_array
    ts=$(date +%s)
    wan=$(ubus call "network.interface.$WAN_INTERFACE" status 2>/dev/null | jsonfilter -e @.up 2>/dev/null || true)
    case "$wan" in true|false) ;; *) wan=null;; esac
    printf '%s %s %s\n' "$ts" "$wan" "$BOOT" >> "$HISTORY"
    awk -v cutoff=$((ts-86400-INTERVAL_SECONDS-15)) '$1>=cutoff' "$HISTORY" | tail -n 3000 > "$WORK/history"
    mv "$WORK/history" "$HISTORY"
    set -- $(awk -v now="$ts" -v interval="$INTERVAL_SECONDS" -f "$HISTORY_AWK" "$HISTORY")
    json_add_int version 1; json_add_int timestamp "$ts"; json_add_int observed_since "$3"; json_add_int interval_seconds "$INTERVAL_SECONDS"
    add_bool wan_up "$wan"; add_bool nps_running "$npsrunning"; add_bool dns_ok "$dnsok"
    json_add_int wan_outages_24h "$1"; json_add_int observation_seconds_24h "$2"
    json_dump > "$WORK/latest.json" && mv "$WORK/latest.json" "$OUTPUT_DIR/latest.json"
    cycle_end=$(date +%s); delay=$((INTERVAL_SECONDS-cycle_end+cycle_start)); [ "$delay" -ge 1 ] || delay=1
}
while :; do collect; [ "$MODE" = --once ] && exit 0; sleep "$delay"; done
