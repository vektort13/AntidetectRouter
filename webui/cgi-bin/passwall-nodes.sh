#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
read_post_data

ACTION="$(get_param action)"
NODE="$(get_param node)"
[ -z "$ACTION" ] && ACTION="list"

is_valid_uci_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    return 0
}

json_escape_val() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_headers

case "$ACTION" in
    list)
        # List all Passwall nodes with full details
        NODES=""
        for node in $(uci show passwall 2>/dev/null | grep "=nodes" | cut -d. -f2 | cut -d= -f1); do
            if [ -n "$NODES" ]; then
                NODES="$NODES,"
            fi
            
            # Get node properties
            REMARKS=$(uci get passwall.$node.remarks 2>/dev/null || echo "")
            TYPE=$(uci get passwall.$node.type 2>/dev/null || echo "Xray")
            PROTOCOL=$(uci get passwall.$node.protocol 2>/dev/null || echo "N/A")
            ADDRESS=$(uci get passwall.$node.address 2>/dev/null || echo "N/A")
            PORT=$(uci get passwall.$node.port 2>/dev/null || echo "N/A")
            TLS=$(uci get passwall.$node.tls 2>/dev/null || echo "0")
            TRANSPORT=$(uci get passwall.$node.transport 2>/dev/null || echo "tcp")
            
            # ULTRA aggressive cleaning - ONLY alphanumeric, space, dash, underscore
            # Remove everything else including slashes, dots, special chars
            REMARKS_CLEAN=$(echo "$REMARKS" | tr -cd 'a-zA-Z0-9 _-' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 50)
            
            # If empty or very short (less than 2 chars), use node ID
            if [ -z "$REMARKS_CLEAN" ] || [ ${#REMARKS_CLEAN} -lt 2 ]; then
                REMARKS_CLEAN="Node_${node}"
            fi
            
            # Escape for JSON (only needed for quotes and backslashes now)
            REMARKS_SAFE=$(echo "$REMARKS_CLEAN" | sed 's/\\/\\\\/g; s/"/\\"/g')
            
            # Clean other fields
            TYPE_SAFE=$(echo "$TYPE" | tr -cd 'a-zA-Z0-9')
            PROTOCOL_SAFE=$(echo "$PROTOCOL" | tr -cd 'a-zA-Z0-9_-')
            ADDRESS_SAFE=$(echo "$ADDRESS" | tr -cd 'a-zA-Z0-9.:_-')
            PORT_SAFE=$(echo "$PORT" | tr -cd '0-9')
            
            NODES="$NODES{\"id\":\"$node\",\"name\":\"$REMARKS_SAFE\",\"type\":\"$TYPE_SAFE\",\"protocol\":\"$PROTOCOL_SAFE\",\"address\":\"$ADDRESS_SAFE\",\"port\":\"$PORT_SAFE\",\"tls\":\"$(echo "$TLS" | tr -cd '01')\",\"transport\":\"$(echo "$TRANSPORT" | tr -cd 'a-zA-Z0-9_-')\"}"
        done
        
        echo "{\"status\":\"ok\",\"nodes\":[$NODES]}"
        ;;
    
    get)
        # Get full node configuration
        if [ -z "$NODE" ]; then
            echo '{"status":"error","message":"Node ID required"}'
            exit 0
        fi
        if ! is_valid_uci_name "$NODE"; then
            echo '{"status":"error","message":"Invalid node ID"}'
            exit 0
        fi

            REMARKS=$(uci get passwall.$NODE.remarks 2>/dev/null || echo "")
            TYPE=$(uci get passwall.$NODE.type 2>/dev/null || echo "")
            PROTOCOL=$(uci get passwall.$NODE.protocol 2>/dev/null || echo "")
            ADDRESS=$(uci get passwall.$NODE.address 2>/dev/null || echo "")
            PORT=$(uci get passwall.$NODE.port 2>/dev/null || echo "")
            USERNAME=$(uci get passwall.$NODE.username 2>/dev/null || echo "")
            PASSWORD=$(uci get passwall.$NODE.password 2>/dev/null || echo "")
            UUID=$(uci get passwall.$NODE.uuid 2>/dev/null || echo "")
            TLS=$(uci get passwall.$NODE.tls 2>/dev/null || echo "0")
            TRANSPORT=$(uci get passwall.$NODE.transport 2>/dev/null || echo "tcp")
            
            printf '{"status":"ok","node":{"id":"%s","remarks":"%s","type":"%s","protocol":"%s","address":"%s","port":"%s","username":"%s","password":"%s","uuid":"%s","tls":"%s","transport":"%s"}}\n' \
                "$(json_escape_val "$NODE")" \
                "$(json_escape_val "$REMARKS")" \
                "$(json_escape_val "$TYPE")" \
                "$(json_escape_val "$PROTOCOL")" \
                "$(json_escape_val "$ADDRESS")" \
                "$(json_escape_val "$PORT")" \
                "$(json_escape_val "$USERNAME")" \
                "$(json_escape_val "$PASSWORD")" \
                "$(json_escape_val "$UUID")" \
                "$(json_escape_val "$TLS")" \
                "$(json_escape_val "$TRANSPORT")"
        ;;
    
    ping)
        # Ping node
        if [ -n "$NODE" ] && is_valid_uci_name "$NODE"; then
            ADDRESS=$(uci get passwall.$NODE.address 2>/dev/null)
            if [ -n "$ADDRESS" ]; then
                LATENCY=$(ping -c 1 -W 2 "$ADDRESS" 2>/dev/null | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/')
                if [ -n "$LATENCY" ]; then
                    echo "{\"status\":\"ok\",\"latency\":\"${LATENCY}ms\"}"
                else
                    echo '{"status":"error","message":"Timeout"}'
                fi
            else
                echo '{"status":"error","message":"Node not found"}'
            fi
        else
            echo '{"status":"error","message":"Node ID required"}'
        fi
        ;;
    
    delete)
        # Delete node
        if [ -n "$NODE" ] && is_valid_uci_name "$NODE"; then
            uci delete passwall.$NODE 2>/dev/null
            uci commit passwall
            /etc/init.d/passwall restart >/dev/null 2>&1 &
            echo '{"status":"ok","message":"Node deleted"}'
        else
            echo '{"status":"error","message":"Node ID required"}'
        fi
        ;;
        
    save)
        echo '{"status":"error","message":"Use passwall-node-config.sh for save action"}'
        ;;
    
    *)
        echo '{"status":"error","message":"Unknown action: '"$ACTION"'"}'
        ;;
esac
