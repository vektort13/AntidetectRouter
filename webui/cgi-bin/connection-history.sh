#!/bin/sh
# Connection History - хранит последние 20-25 записей latency

HISTORY_FILE="/tmp/vpn-connection-history.log"
MAX_ENTRIES=25

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="read"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sanitize_history_field() {
    printf '%s' "$1" | tr -d '\r\n' | tr '|' ' '
}

case "$ACTION" in
    read)
        # Read history file
        if [ ! -f "$HISTORY_FILE" ]; then
            echo '{"status":"ok","entries":[]}'
            exit 0
        fi
        
        echo '{"status":"ok","entries":['
        
        FIRST=1
        while IFS='|' read -r timestamp latency mode location ip; do
            # Backward compatibility for old 4-field rows.
            if [ -z "$ip" ]; then
                ip="$location"
                location="Unknown"
            fi

            # Skip N/A entries
            if [ "$latency" = "N/A" ] || [ "$ip" = "N/A" ] || [ "$mode" = "Unknown" ]; then
                continue
            fi

            timestamp="$(json_escape "$timestamp")"
            latency="$(json_escape "$latency")"
            mode="$(json_escape "$mode")"
            location="$(json_escape "$location")"
            ip="$(json_escape "$ip")"
            
            [ "$FIRST" = "1" ] && FIRST=0 || echo ","
            cat << EOF
{
  "timestamp": "$timestamp",
  "latency": "$latency",
  "mode": "$mode",
  "location": "$location",
  "ip": "$ip"
}
EOF
        done < "$HISTORY_FILE"
        
        echo ']}'
        ;;
        
    add)
        # Add new entry
        TIMESTAMP="$(get_param timestamp)"
        [ -z "$TIMESTAMP" ] && TIMESTAMP="$(date '+%H:%M:%S')"

        LATENCY="$(get_param latency)"
        [ -z "$LATENCY" ] && LATENCY="N/A"

        MODE="$(get_param mode)"
        [ -z "$MODE" ] && MODE="Unknown"

        LOCATION="$(get_param location)"
        [ -z "$LOCATION" ] && LOCATION="Unknown"

        IP="$(get_param ip)"
        [ -z "$IP" ] && IP="Unknown"

        TIMESTAMP="$(sanitize_history_field "$TIMESTAMP")"
        LATENCY="$(sanitize_history_field "$LATENCY")"
        MODE="$(sanitize_history_field "$MODE")"
        LOCATION="$(sanitize_history_field "$LOCATION")"
        IP="$(sanitize_history_field "$IP")"
        
        # Append to file
        echo "$TIMESTAMP|$LATENCY|$MODE|$LOCATION|$IP" >> "$HISTORY_FILE"
        
        # Keep only last MAX_ENTRIES
        if [ -f "$HISTORY_FILE" ]; then
            tail -n "$MAX_ENTRIES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
            mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        fi
        
        echo '{"status":"ok","message":"Entry added"}'
        ;;
        
    clear)
        # Clear history
        rm -f "$HISTORY_FILE"
        echo '{"status":"ok","message":"History cleared"}'
        ;;
        
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
