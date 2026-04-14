#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="list"

list_rules() {
    TEMP="/tmp/nft_$$"
    nft list ruleset 2>/dev/null > "$TEMP"
    
    if [ ! -s "$TEMP" ]; then
        rm -f "$TEMP"
        echo '{"status":"ok","rules":[]}'
        return
    fi
    
    echo '{'
    echo '  "status": "ok",'
    echo '  "rules": ['
    
    FIRST=1
    CHAIN=""
    
    while IFS= read -r line; do
        case "$line" in
            *"chain "*)
                CHAIN=$(echo "$line" | awk '{print $2}')
                ;;
            *"dport"*|*"drop"*|*"reject"*)
                SRC=$(echo "$line" | grep -o "ip saddr [0-9./]*" | awk '{print $3}')
                [ -z "$SRC" ] && SRC="any"
                
                DEST=$(echo "$line" | grep -o "ip daddr [0-9./]*" | awk '{print $3}')
                [ -z "$DEST" ] && DEST="any"
                
                PORT=$(echo "$line" | grep -o "dport [0-9]*" | awk '{print $2}')
                [ -z "$PORT" ] && PORT="any"
                
                if echo "$line" | grep -q "accept"; then
                    TARGET="ACCEPT"
                elif echo "$line" | grep -q "drop"; then
                    TARGET="DROP"
                elif echo "$line" | grep -q "reject"; then
                    TARGET="REJECT"
                else
                    continue
                fi
                
                [ "$FIRST" = "1" ] && FIRST=0 || echo ","
                cat << EOF
    {
      "name": "$CHAIN",
      "src": "$SRC",
      "dest": "$DEST",
      "port": "$PORT",
      "target": "$TARGET"
    }
EOF
                ;;
        esac
    done < "$TEMP"
    
    rm -f "$TEMP"
    
    echo '  ]'
    echo '}'
}

get_status() {
    FW4_RUNNING="false"
    if pgrep -f fw4 >/dev/null 2>&1 || [ -f /var/run/fw4.lock ]; then
        FW4_RUNNING="true"
    fi
    
    cat << EOF
{
  "status": "ok",
  "firewall_running": $FW4_RUNNING
}
EOF
}

case "$ACTION" in
    list) list_rules ;;
    status) get_status ;;
    *) echo '{"status":"error","message":"Invalid action"}' ;;
esac
