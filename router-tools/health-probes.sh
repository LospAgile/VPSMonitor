#!/bin/ash
# Helpers share WORK, TIMEOUT_SECONDS and PING_COUNT with the collector.
bounded() {
    output=$1; shift
    "$@" > "$output" 2>&1 & job=$!
    (sleep "$TIMEOUT_SECONDS"; kill -TERM "$job" 2>/dev/null; sleep 1; kill -KILL "$job" 2>/dev/null) & guard=$!
    wait "$job" 2>/dev/null; result=$?
    kill "$guard" 2>/dev/null || true; wait "$guard" 2>/dev/null || true
    return "$result"
}
ping_result() {
    bounded "$WORK/ping" ping -n -c "$PING_COUNT" -W 1 -w "$TIMEOUT_SECONDS" "$1" || true
    awk '
    /packet loss/ { for(i=2;i<NF;i++)if($i=="packet" && $(i+1)~/^loss/){ loss=$(i-1); sub(/%/,"",loss); loss+=0; seen=1 } }
    /min\/avg\/max/ { split($0,a,"="); split(a[2],b,"/"); latency=b[2]+0; haslatency=1 }
    END { if(!seen)print "null null null"; else printf "%s %s %s\n",(loss<100?"true":"false"),(haslatency?latency:"null"),loss }
    ' "$WORK/ping"
}
probe_clock() {
    # BusyBox ash has no sub-second timer; /proc/uptime carries 10 ms resolution.
    read -r uptime_seconds _ < /proc/uptime 2>/dev/null && { echo "$uptime_seconds"; return; }
    date +%s
}
elapsed_ms() {
    awk -v a="$1" -v b="$(probe_clock)" 'BEGIN{ms=(b-a)*1000; printf "%d",(ms<0?0:ms)}'
}
ssh_result() {
    command -v nc >/dev/null 2>&1 || { echo 'null null null'; return; }
    # The routers' minimal BusyBox nc exits on stdin EOF. Hold stdin open while
    # waiting for the remote SSH greeting; a listening NPS port alone is not proof.
    fifo="$WORK/ssh-input"; output="$WORK/ssh-banner"
    rm -f "$fifo"; mkfifo "$fifo" || { echo 'null null null'; return; }
    : > "$output"
    started=$(probe_clock); budget=$((TIMEOUT_SECONDS * 1000))
    sleep "$TIMEOUT_SECONDS" > "$fifo" & writer=$!
    nc "$1" "$2" < "$fifo" > "$output" 2>&1 & client=$!
    ok=false; latency=null; polls=0
    # Busy-poll: BusyBox ash only sleeps in whole seconds, which is coarser than
    # the greeting itself. Read the clock every tenth pass instead of every pass,
    # since each read forks and would inflate what it is meant to measure.
    while [ "$polls" -lt 200000 ]; do
        if grep -Eq '^SSH-(2\.0|1\.99)-[^[:space:]]+' "$output"; then
            ok=true; latency=$(elapsed_ms "$started"); break
        fi
        kill -0 "$client" 2>/dev/null || break
        [ "$(wc -c < "$output")" -le 8192 ] || break
        polls=$((polls+1))
        if [ $((polls % 10)) -eq 0 ] && [ "$(elapsed_ms "$started")" -ge "$budget" ]; then break; fi
    done
    # Include a response arriving during the final interval.
    if [ "$ok" = false ] && grep -Eq '^SSH-(2\.0|1\.99)-[^[:space:]]+' "$output"; then
        ok=true; latency=$(elapsed_ms "$started")
    fi
    kill "$client" "$writer" 2>/dev/null || true
    wait "$client" 2>/dev/null || true; wait "$writer" 2>/dev/null || true
    rm -f "$fifo"
    # Time to the SSH greeting, not an ICMP round trip: it covers the TCP
    # handshake plus any proxy on the router's own outbound path. No loss rate:
    # a single connection attempt cannot produce one.
    printf '%s %s null\n' "$ok" "$latency"
}
