#!/bin/sh
# VEKTORT13 API - VPN Control
# Manages Passwall and OpenVPN with auto-switch

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

VPN_TYPE="$(get_param vpn)"
VPN_ACTION="$(get_param action)"

# Validate parameters
if [ -z "$VPN_TYPE" ] || [ -z "$VPN_ACTION" ]; then
    cat << EOF
{
  "status": "error",
  "message": "Missing parameters. Usage: ?vpn=passwall|openvpn&action=start|stop|restart"
}
EOF
    exit 1
fi

if [ "$VPN_TYPE" != "passwall" ] && [ "$VPN_TYPE" != "openvpn" ]; then
    cat << EOF
{
  "status": "error",
  "message": "Invalid VPN type. Must be 'passwall' or 'openvpn'"
}
EOF
    exit 1
fi

# ==================== Passwall Functions ====================

passwall_start() {
    # Log to file for debugging
    LOG_FILE="/tmp/vpn-control-debug.log"
    echo "[$(date)] passwall_start called" >> "$LOG_FILE"
    
    # Auto-switch: stop OpenVPN first
    if pgrep -f "openvpn.*tun" >/dev/null 2>&1; then
        echo "[$(date)] Stopping OpenVPN..." >> "$LOG_FILE"
        /etc/init.d/openvpn stop >/dev/null 2>&1
        sleep 1
    fi
    
    # Enable and start Passwall
    echo "[$(date)] Setting passwall.enabled=1" >> "$LOG_FILE"
    uci set passwall.@global[0].enabled='1' 2>&1 | tee -a "$LOG_FILE"
    
    echo "[$(date)] Committing UCI" >> "$LOG_FILE"
    uci commit passwall 2>&1 | tee -a "$LOG_FILE"
    
    # Restart to apply
    echo "[$(date)] Restarting Passwall..." >> "$LOG_FILE"
    /etc/init.d/passwall restart 2>&1 | tee -a "$LOG_FILE"
    
    # Wait for startup
    sleep 3
    
    # Check if running
    echo "[$(date)] Checking if running..." >> "$LOG_FILE"
    if pgrep -f xray >/dev/null 2>&1 || pgrep -f v2ray >/dev/null 2>&1; then
        echo "[$(date)] SUCCESS: Passwall started" >> "$LOG_FILE"
        echo '{"status":"ok","vpn":"passwall","action":"start","result":"success","message":"Passwall started successfully"}'
    else
        # Get error from logread
        ERROR_MSG=$(logread | grep -i "passwall" | tail -3 | tr '\n' ' ')
        echo "[$(date)] FAILED: $ERROR_MSG" >> "$LOG_FILE"
        echo "{\"status\":\"ok\",\"vpn\":\"passwall\",\"action\":\"start\",\"result\":\"failed\",\"message\":\"Passwall failed to start. Check /tmp/vpn-control-debug.log\"}"
    fi
}

passwall_stop() {
    # Disable and stop
    uci set passwall.@global[0].enabled='0' 2>/dev/null
    uci commit passwall 2>/dev/null
    /etc/init.d/passwall stop >/dev/null 2>&1
    
    sleep 2
    
    # Verify stopped
    if ! pgrep -f xray >/dev/null 2>&1 && ! pgrep -f v2ray >/dev/null 2>&1; then
        echo '{"status":"ok","vpn":"passwall","action":"stop","result":"success","message":"Passwall stopped successfully"}'
    else
        echo '{"status":"ok","vpn":"passwall","action":"stop","result":"failed","message":"Passwall failed to stop"}'
    fi
}

passwall_restart() {
    /etc/init.d/passwall restart >/dev/null 2>&1
    sleep 3
    
    if pgrep -f xray >/dev/null 2>&1 || pgrep -f v2ray >/dev/null 2>&1; then
        echo '{"status":"ok","vpn":"passwall","action":"restart","result":"success","message":"Passwall restarted successfully"}'
    else
        echo '{"status":"ok","vpn":"passwall","action":"restart","result":"failed","message":"Passwall failed to restart"}'
    fi
}

passwall_status() {
    local enabled=$(uci get passwall.@global[0].enabled 2>/dev/null || echo "0")
    local running="false"
    
    if pgrep -f xray >/dev/null 2>&1 || pgrep -f v2ray >/dev/null 2>&1; then
        running="true"
    fi
    
    cat << EOF
{
  "status": "ok",
  "vpn": "passwall",
  "action": "status",
  "result": "success",
  "data": {
    "enabled": $enabled,
    "running": $running
  }
}
EOF
}

# ==================== OpenVPN Functions ====================

openvpn_start() {
    # Auto-switch: stop Passwall first
    if pgrep -f xray >/dev/null 2>&1 || pgrep -f v2ray >/dev/null 2>&1; then
        uci set passwall.@global[0].enabled='0' 2>/dev/null
        uci commit passwall 2>/dev/null
        /etc/init.d/passwall stop >/dev/null 2>&1
        sleep 2
    fi
    
    # Start OpenVPN (запускает последний enabled конфиг)
    /etc/init.d/openvpn start >/dev/null 2>&1
    
    sleep 3
    
    # Check if running
    if pgrep -f "openvpn.*tun" >/dev/null 2>&1; then
        echo '{"status":"ok","vpn":"openvpn","action":"start","result":"success","message":"OpenVPN started successfully"}'
    else
        echo '{"status":"ok","vpn":"openvpn","action":"start","result":"failed","message":"OpenVPN failed to start"}'
    fi
}

openvpn_stop() {
    /etc/init.d/openvpn stop >/dev/null 2>&1
    sleep 2
    
    if ! pgrep -f "openvpn.*tun" >/dev/null 2>&1; then
        echo '{"status":"ok","vpn":"openvpn","action":"stop","result":"success","message":"OpenVPN stopped successfully"}'
    else
        echo '{"status":"ok","vpn":"openvpn","action":"stop","result":"failed","message":"OpenVPN failed to stop"}'
    fi
}

openvpn_restart() {
    /etc/init.d/openvpn restart >/dev/null 2>&1
    sleep 3
    
    if pgrep -f "openvpn.*tun" >/dev/null 2>&1; then
        echo '{"status":"ok","vpn":"openvpn","action":"restart","result":"success","message":"OpenVPN restarted successfully"}'
    else
        echo '{"status":"ok","vpn":"openvpn","action":"restart","result":"failed","message":"OpenVPN failed to restart"}'
    fi
}

openvpn_status() {
    local running="false"
    
    if pgrep -f "openvpn.*tun" >/dev/null 2>&1; then
        running="true"
    fi
    
    cat << EOF
{
  "status": "ok",
  "vpn": "openvpn",
  "action": "status",
  "result": "success",
  "data": {
    "running": $running
  }
}
EOF
}

# ==================== Route Actions ====================

case "$VPN_TYPE" in
    passwall)
        case "$VPN_ACTION" in
            start) passwall_start ;;
            stop) passwall_stop ;;
            restart) passwall_restart ;;
            status) passwall_status ;;
            *)
                echo '{"status":"error","message":"Invalid action. Must be: start, stop, restart, status"}'
                exit 1
                ;;
        esac
        ;;
    openvpn)
        case "$VPN_ACTION" in
            start) openvpn_start ;;
            stop) openvpn_stop ;;
            restart) openvpn_restart ;;
            status) openvpn_status ;;
            *)
                echo '{"status":"error","message":"Invalid action. Must be: start, stop, restart, status"}'
                exit 1
                ;;
        esac
        ;;
esac
