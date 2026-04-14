#!/bin/sh
# VEKTORT13 API - Connection Info
# Returns: IP, Location, Latency, VPN Mode

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers

# ==================== Detect VPN Mode ====================
detect_vpn_mode() {
    # Check Passwall
    if pgrep -f xray >/dev/null 2>&1 || pgrep -f v2ray >/dev/null 2>&1; then
        PASSWALL_ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null)
        if [ "$PASSWALL_ENABLED" = "1" ]; then
            echo "Passwall"
            return
        fi
    fi
    
    # Check OpenVPN CLIENT (exclude RW server!)
    # Method 1: Check for client processes (not openvpn(rw))
    if ps | grep openvpn | grep -v grep | grep -v "openvpn(rw)" >/dev/null 2>&1; then
        echo "OpenVPN"
        return
    fi
    
    # Method 2: Check for client TUN interfaces (tun1, tun2, etc - NOT tun0)
    if ls /sys/class/net/ | grep -E "^tun[1-9]" >/dev/null 2>&1; then
        echo "OpenVPN"
        return
    fi
    
    echo "Unknown"
}

# ==================== Get Public IP ====================
get_public_ip() {
    # Try multiple sources with curl max-time (no need for timeout command)
    IP=$(curl -4s --max-time 10 https://icanhazip.com 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    
    if [ -z "$IP" ]; then
        IP=$(curl -4s --max-time 10 https://ifconfig.me/ip 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    fi
    
    if [ -z "$IP" ]; then
        IP=$(curl -4s --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    fi
    
    if [ -z "$IP" ]; then
        IP=$(curl -s --max-time 10 https://ipecho.net/plain 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    fi
    
    if [ -z "$IP" ]; then
        echo "N/A"
    else
        echo "$IP"
    fi
}

# ==================== Get Location ====================
get_location() {
    local ip="$1"
    
    if [ "$ip" = "N/A" ]; then
        echo "{\"city\":\"Unknown\",\"regionName\":\"Unknown\",\"country\":\"Unknown\"}"
        return
    fi
    
    # Use HTTPS geolocation endpoint
    LOCATION_JSON=$(curl -s --max-time 5 "https://ipinfo.io/${ip}/json" 2>/dev/null)
    
    if [ -n "$LOCATION_JSON" ] && echo "$LOCATION_JSON" | grep -q '"ip"'; then
        # Parse JSON properly with grep and cut
        CITY=$(echo "$LOCATION_JSON" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        REGION=$(echo "$LOCATION_JSON" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
        COUNTRY=$(echo "$LOCATION_JSON" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        
        # Fallback to Unknown if empty
        [ -z "$CITY" ] && CITY="Unknown"
        [ -z "$REGION" ] && REGION="Unknown"
        [ -z "$COUNTRY" ] && COUNTRY="Unknown"
        
        # Return JSON
        echo "{\"city\":\"$CITY\",\"regionName\":\"$REGION\",\"country\":\"$COUNTRY\"}"
    else
        echo "{\"city\":\"Unknown\",\"regionName\":\"Unknown\",\"country\":\"Unknown\"}"
    fi
}

# ==================== Get Latency ====================
get_latency() {
    local mode="$1"
    
    if [ "$mode" = "Passwall" ]; then
        # Get Passwall node IP
        SOCKS_NODE=$(uci get passwall.@global[0].socks_node 2>/dev/null)
        TCP_NODE=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
        
        if [ -n "$SOCKS_NODE" ] && [ "$SOCKS_NODE" != "nil" ]; then
            PROXY_IP=$(uci get passwall.$SOCKS_NODE.address 2>/dev/null)
        elif [ -n "$TCP_NODE" ] && [ "$TCP_NODE" != "nil" ] && [ "$TCP_NODE" != "tcp" ]; then
            PROXY_IP=$(uci get passwall.$TCP_NODE.address 2>/dev/null)
        fi
        
        if [ -n "$PROXY_IP" ]; then
            # Get only the average ping time (4th field after splitting by '/')
            PING_RESULT=$(ping -c 3 -W 2 "$PROXY_IP" 2>/dev/null | grep 'avg' | awk -F'[/=]' '{print $6}')
            # Remove any existing 'ms' and whitespace
            PING_RESULT=$(echo "$PING_RESULT" | sed 's/[[:space:]]*ms[[:space:]]*//g' | tr -d ' ')
            
            if [ -n "$PING_RESULT" ]; then
                echo "${PING_RESULT} ms"
                return
            fi
        fi
    elif [ "$mode" = "OpenVPN" ]; then
        # Ping through VPN tunnel
        PING_RESULT=$(ping -c 3 -W 2 8.8.8.8 2>/dev/null | grep 'avg' | awk -F'[/=]' '{print $6}')
        PING_RESULT=$(echo "$PING_RESULT" | sed 's/[[:space:]]*ms[[:space:]]*//g' | tr -d ' ')
        
        if [ -n "$PING_RESULT" ]; then
            echo "${PING_RESULT} ms"
            return
        fi
    fi
    
    echo "N/A"
}

# ==================== Check VPN Status ====================
check_vpn_status() {
    local mode="$1"
    
    if [ "$mode" = "Passwall" ] || [ "$mode" = "OpenVPN" ]; then
        echo "active"
    else
        echo "inactive"
    fi
}

# ==================== Collect Data ====================
MODE=$(detect_vpn_mode)
STATUS=$(check_vpn_status "$MODE")
IP=$(get_public_ip)
LOCATION_JSON=$(get_location "$IP")
LATENCY=$(get_latency "$MODE")

# Parse location JSON
CITY=$(echo "$LOCATION_JSON" | grep -o '"city":"[^"]*' | cut -d'"' -f4)
REGION=$(echo "$LOCATION_JSON" | grep -o '"regionName":"[^"]*' | cut -d'"' -f4)
COUNTRY=$(echo "$LOCATION_JSON" | grep -o '"country":"[^"]*' | cut -d'"' -f4)

# Fallback if parsing failed
[ -z "$CITY" ] && CITY="Unknown"
[ -z "$REGION" ] && REGION="Unknown"
[ -z "$COUNTRY" ] && COUNTRY="Unknown"

# ==================== Smart History Logging ====================
# Only log IP changes with mode information
HISTORY_FILE="/tmp/vpn-connection-history.log"
STATE_FILE="/tmp/vpn-last-state"
MAX_ENTRIES=25
TIMESTAMP=$(date '+%H:%M:%S')

# Read previous state
if [ -f "$STATE_FILE" ]; then
    PREV_MODE=$(grep "^MODE=" "$STATE_FILE" | cut -d'=' -f2)
    PREV_IP=$(grep "^IP=" "$STATE_FILE" | cut -d'=' -f2)
else
    PREV_MODE=""
    PREV_IP=""
fi

# Save current state FIRST
cat > "$STATE_FILE" << EOF
MODE=$MODE
IP=$IP
EOF

# ONLY LOG if:
# 1. IP is valid (not N/A)
# 2. Mode is valid (not Unknown)
# 3. IP changed OR first valid connection
SHOULD_LOG=0

if [ "$IP" != "N/A" ] && [ "$MODE" != "Unknown" ]; then
    # Check if IP changed
    if [ "$IP" != "$PREV_IP" ]; then
        SHOULD_LOG=1
    fi
    
    # OR if this is first valid connection (no previous IP)
    if [ -z "$PREV_IP" ] || [ "$PREV_IP" = "N/A" ]; then
        SHOULD_LOG=1
    fi
fi

# Log ONLY valid events
if [ $SHOULD_LOG -eq 1 ]; then
    # Format: timestamp|latency|mode|location|ip
    LOCATION_SAFE="${CITY}, ${COUNTRY}"
    LOCATION_SAFE=$(echo "$LOCATION_SAFE" | tr '|' ' ')
    echo "$TIMESTAMP|$LATENCY|$MODE|$LOCATION_SAFE|$IP" >> "$HISTORY_FILE"
    
    # Keep only last MAX_ENTRIES
    if [ -f "$HISTORY_FILE" ]; then
        tail -n $MAX_ENTRIES "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
        mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
fi

# ==================== Output JSON ====================
cat << EOF
{
  "status": "ok",
  "data": {
    "vpn_mode": "$MODE",
    "vpn_status": "$STATUS",
    "public_ip": "$IP",
    "location": {
      "city": "$CITY",
      "region": "$REGION",
      "country": "$COUNTRY"
    },
    "latency": "$LATENCY"
  }
}
EOF
