#!/bin/sh
# Network Interfaces Management

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="list"

INTERFACE="$(get_param interface)"
COMMAND="$(get_param command)"

# List all interfaces
list_interfaces() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "interfaces": ['
    
    FIRST=1
    for iface in $(ls /sys/class/net/); do
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        
        # Get status
        STATUS="down"
        [ -f "/sys/class/net/$iface/operstate" ] && STATUS=$(cat /sys/class/net/$iface/operstate)
        
        # Get IP
        IP=$(ip -4 addr show $iface 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        [ -z "$IP" ] && IP="N/A"
        
        # Get MAC
        MAC=$(cat /sys/class/net/$iface/address 2>/dev/null)
        [ -z "$MAC" ] && MAC="N/A"
        
        # Get RX/TX bytes
        RX=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        TX=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        
        # Get MTU
        MTU=$(cat /sys/class/net/$iface/mtu 2>/dev/null || echo 0)
        
        # Get speed (if available)
        SPEED=$(ethtool $iface 2>/dev/null | grep Speed | awk '{print $2}' || echo "N/A")
        
        # Determine type
        TYPE="unknown"
        case $iface in
            eth*|wan*) TYPE="ethernet" ;;
            br-*) TYPE="bridge" ;;
            tun*|tap*) TYPE="vpn" ;;
            wlan*) TYPE="wireless" ;;
            lo) TYPE="loopback" ;;
        esac
        
        cat << EOF
    {
      "name": "$iface",
      "type": "$TYPE",
      "status": "$STATUS",
      "ip": "$IP",
      "mac": "$MAC",
      "rx_bytes": $RX,
      "tx_bytes": $TX,
      "mtu": $MTU,
      "speed": "$SPEED"
    }
EOF
    done
    
    echo '  ]'
    echo '}'
}

# Interface actions
control_interface() {
    local cmd="$1"
    
    case "$cmd" in
        up)
            ip link set "$INTERFACE" up 2>&1
            echo '{"status":"ok","message":"Interface brought up"}'
            ;;
        down)
            ip link set "$INTERFACE" down 2>&1
            echo '{"status":"ok","message":"Interface brought down"}'
            ;;
        restart)
            ifdown "$INTERFACE" 2>&1
            sleep 1
            ifup "$INTERFACE" 2>&1
            echo '{"status":"ok","message":"Interface restarted"}'
            ;;
        *)
            echo '{"status":"error","message":"Invalid command"}'
            ;;
    esac
}

# Main logic
case "$ACTION" in
    list)
        list_interfaces
        ;;
    control)
        if [ -z "$INTERFACE" ] || [ -z "$COMMAND" ]; then
            echo '{"status":"error","message":"Interface and command required"}'
        else
            control_interface "$COMMAND"
        fi
        ;;
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
