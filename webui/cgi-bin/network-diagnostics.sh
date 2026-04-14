#!/bin/sh
# Network Diagnostics Tools

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="ping"

HOST="$(get_param host)"
[ -z "$HOST" ] && HOST="8.8.8.8"

COUNT="$(get_param count)"
[ -z "$COUNT" ] && COUNT="4"
case "$COUNT" in
    ''|*[!0-9]*) COUNT="4" ;;
esac
[ "$COUNT" -lt 1 ] && COUNT=1
[ "$COUNT" -gt 10 ] && COUNT=10

is_valid_host() {
    case "$1" in
        ''|-*|.*|*.|*..*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if ! is_valid_host "$HOST"; then
    echo '{"status":"error","message":"Invalid host"}'
    exit 0
fi

HOST_JSON="$(json_escape "$HOST")"

# Ping test
do_ping() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "tool": "ping",'
    printf '  "host": "%s",\n' "$HOST_JSON"
    echo '  "results": ['
    
    FIRST=1
    ping -c "$COUNT" -W 2 "$HOST" 2>&1 | while read line; do
        if echo "$line" | grep -q "bytes from"; then
            [ "$FIRST" = "1" ] && FIRST=0 || echo ","
            
            SEQ=$(echo "$line" | grep -o "icmp_seq=[0-9]*" | cut -d= -f2)
            TIME=$(echo "$line" | grep -o "time=[0-9.]*" | cut -d= -f2)
            TTL=$(echo "$line" | grep -o "ttl=[0-9]*" | cut -d= -f2)
            
            echo "    {\"seq\": $SEQ, \"time\": \"${TIME}ms\", \"ttl\": $TTL}"
        fi
    done
    
    echo '  ]'
    echo '}'
}

# Traceroute
do_traceroute() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "tool": "traceroute",'
    printf '  "host": "%s",\n' "$HOST_JSON"
    echo '  "hops": ['
    
    FIRST=1
    traceroute -m 15 -w 2 "$HOST" 2>&1 | tail -n +2 | while read line; do
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        
        HOP=$(echo "$line" | awk '{print $1}')
        IP=$(echo "$line" | awk '{print $2}' | tr -d '()')
        TIME=$(echo "$line" | grep -o "[0-9.]*\s*ms" | head -1)
        
        echo "    {\"hop\": $HOP, \"ip\": \"$IP\", \"time\": \"$TIME\"}"
    done
    
    echo '  ]'
    echo '}'
}

# DNS lookup
do_nslookup() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "tool": "nslookup",'
    printf '  "host": "%s",\n' "$HOST_JSON"
    
    RESULT=$(nslookup "$HOST" 2>&1)
    
    # Extract IPs
    IPS=$(echo "$RESULT" | grep "Address" | tail -n +2 | awk '{print $2}')
    
    echo '  "addresses": ['
    FIRST=1
    for ip in $IPS; do
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        echo "    \"$ip\""
    done
    echo '  ]'
    echo '}'
}

# Network scan (simple arp scan)
do_scan() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "tool": "scan",'
    echo '  "devices": ['
    
    FIRST=1
    ip neigh | while read line; do
        IP=$(echo "$line" | awk '{print $1}')
        MAC=$(echo "$line" | awk '{print $5}')
        STATE=$(echo "$line" | grep -o "REACHABLE\|STALE\|DELAY")
        
        if [ -n "$MAC" ] && [ "$MAC" != "FAILED" ]; then
            [ "$FIRST" = "1" ] && FIRST=0 || echo ","
            echo "    {\"ip\": \"$IP\", \"mac\": \"$MAC\", \"state\": \"$STATE\"}"
        fi
    done
    
    echo '  ]'
    echo '}'
}

# Speedtest (simple download test)
do_speedtest() {
    local speed_bps speed_mbps

    echo '{'
    echo '  "status": "ok",'
    echo '  "tool": "speedtest",'

    speed_bps="$(curl -o /dev/null -s --max-time 20 -w "%{speed_download}" https://speed.hetzner.de/1MB.bin 2>/dev/null)"
    if printf '%s' "$speed_bps" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && [ "$speed_bps" != "0" ]; then
        speed_mbps="$(awk "BEGIN {printf \"%.2f\", ($speed_bps * 8) / 1000000}")"
    else
        speed_mbps="N/A"
    fi

    echo "  \"download_mbps\": \"$speed_mbps\"," 
    echo '  "upload_mbps": "N/A",'
    echo '  "ping_ms": "N/A"'
    echo '}'
}

# Main logic
case "$ACTION" in
    ping)
        do_ping
        ;;
    traceroute)
        do_traceroute
        ;;
    nslookup)
        do_nslookup
        ;;
    scan)
        do_scan
        ;;
    speedtest)
        do_speedtest
        ;;
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
