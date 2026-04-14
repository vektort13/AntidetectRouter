#!/bin/sh
# System Status Script with VPN Status

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers

# Get CPU usage (OpenWrt style)
CPU_LINE=$(top -bn1 | grep "CPU:" | head -1)
if [ -n "$CPU_LINE" ]; then
    # Parse "CPU:  5% usr  2% sys  0% nic 91% idle  0% io  0% irq  1% sirq"
    CPU_IDLE=$(echo "$CPU_LINE" | awk '{for(i=1;i<=NF;i++) if($i~/idle/) print $(i-1)}' | sed 's/%//')
    if [ -n "$CPU_IDLE" ]; then
        CPU=$((100 - CPU_IDLE))
    else
        CPU="0"
    fi
else
    CPU="0"
fi

# Get RAM usage
MEM_TOTAL=$(free | grep "Mem:" | awk '{print $2}')
MEM_USED=$(free | grep "Mem:" | awk '{print $3}')
if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ]; then
    RAM=$((MEM_USED * 100 / MEM_TOTAL))
else
    RAM="0"
fi

# Get uptime
UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*load.*//' | sed 's/,.*//' | xargs)
if [ -z "$UPTIME" ]; then
    UPTIME="unknown"
fi

# ==================== VPN STATUS ====================

# Get current public IP
get_public_ip() {
    local ip=""
    
    # Attempt 1: icanhazip.com over HTTPS
    ip=$(curl -4s --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    [ -n "$ip" ] && echo "$ip" && return
    
    # Attempt 2: IPv4-only API endpoint
    ip=$(curl -4s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    [ -n "$ip" ] && echo "$ip" && return
    
    # Attempt 3: ifconfig.me IPv4 endpoint
    ip=$(curl -4s --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    [ -n "$ip" ] && echo "$ip" && return

    # Attempt 4: ipecho fallback
    ip=$(curl -4s --max-time 5 https://ipecho.net/plain 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    [ -n "$ip" ] && echo "$ip" && return
    
    echo "N/A"
}

# Get geolocation info
get_geo_info() {
    local ip="$1"
    local geo_json

    geo_json=$(curl -4s --max-time 5 "https://ipinfo.io/${ip}/json" 2>/dev/null)

    if [ -n "$geo_json" ] && echo "$geo_json" | grep -q '"ip"'; then
        # Parse JSON (simple grep + cut)
        local city=$(echo "$geo_json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        local region=$(echo "$geo_json" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
        local country=$(echo "$geo_json" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        
        # Format location
        local location=""
        [ -n "$city" ] && location="$city"
        [ -n "$region" ] && location="${location:+$location, }$region"
        [ -n "$country" ] && location="${location:+$location, }$country"
        
        [ -z "$location" ] && location="Unknown"
        echo "$location"
    else
        echo "Unknown, Unknown, Unknown"
    fi
}

# Detect active VPN mode
detect_vpn_mode() {
    # Check Passwall
    if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1; then
        if uci get passwall.@global[0].enabled 2>/dev/null | grep -q '1'; then
            echo "Passwall"
            return
        fi
    fi
    
    # Check OpenVPN (look for running configs with PID files)
    for pid_file in /var/run/openvpn-*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                local config_name=$(basename "$pid_file" .pid | sed 's/openvpn-//')
                echo "OpenVPN"
                return
            fi
        fi
    done
    
    echo "None"
}

# Get ping to target
get_latency() {
    local target=""
    local mode=$(detect_vpn_mode)
    
    # Determine target based on active VPN mode
    if [ "$mode" = "OpenVPN" ]; then
        # OpenVPN active - ping 8.8.8.8
        target="8.8.8.8"
    elif [ "$mode" = "Passwall" ]; then
        # Passwall active - ping proxy server
        local node=$(uci get passwall.@global[0].socks_node 2>/dev/null)
        [ -z "$node" ] && node=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
        
        if [ -n "$node" ]; then
            local server=$(uci get "passwall.$node.address" 2>/dev/null)
            if [ -n "$server" ]; then
                # Check if IP or hostname
                if echo "$server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    target="$server"
                else
                    # Resolve hostname to IP
                    target=$(nslookup "$server" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
                fi
            fi
        fi
        
        # Fallback to 8.8.8.8 if can't get proxy IP
        [ -z "$target" ] && target="8.8.8.8"
    else
        # No VPN active
        echo "N/A"
        return
    fi
    
    # Ping
    local ping_output=$(ping -c 3 -W 1 "$target" 2>/dev/null)
    
    if [ -z "$ping_output" ]; then
        echo "N/A"
        return
    fi
    
    local stats=$(echo "$ping_output" | grep "min/avg/max")
    
    if [ -z "$stats" ]; then
        echo "N/A"
        return
    fi
    
    local values=$(echo "$stats" | cut -d'=' -f2 | tr -d ' ms')
    local avg=$(echo "$values" | cut -d'/' -f2)
    
    # Format to 3 decimals
    avg=$(awk "BEGIN {printf \"%.3f\", $avg}" 2>/dev/null)
    
    echo "${avg} ms"
}

# Determine status
VPN_STATUS="Inactive"
VPN_MODE=$(detect_vpn_mode)

if [ "$VPN_MODE" != "None" ]; then
    VPN_STATUS="Active"
fi

# Get IP and location
PUBLIC_IP=$(get_public_ip)
LOCATION=$(get_geo_info "$PUBLIC_IP")
LATENCY=$(get_latency)

# JSON escape function
json_escape() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Build JSON response
cat << EOF
{
    "status": "ok",
    "data": {
        "cpu": "$CPU",
        "ram": "$RAM",
        "uptime": "$UPTIME"
    },
    "vpn": {
        "status": "$(json_escape "$VPN_STATUS")",
        "mode": "$(json_escape "$VPN_MODE")",
        "publicIp": "$(json_escape "$PUBLIC_IP")",
        "location": "$(json_escape "$LOCATION")",
        "latency": "$(json_escape "$LATENCY")"
    }
}
EOF

exit 0
