#!/bin/sh
# Display Enhanced VPN Status on Login - DYNAMIC PING
# Re-calculates ping metrics on every SSH login

LOG="/tmp/dual-vpn-switcher.log"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  CURRENT VPN STATUS"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check if switcher is running
if ! pgrep -f "dual-vpn-switcher.sh" > /dev/null; then
    printf "\033[1;33m⚠️  VPN Switcher not running!\033[0m\n"
    echo ""
    echo "Start with: /root/dual-vpn-switcher.sh &"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    exit 0
fi

# ==================== DYNAMIC PING FUNCTION ====================

get_ping_target() {
    # Try to get SOCKS proxy IP from Passwall
    local node=$(uci get passwall.@global[0].socks_node 2>/dev/null)
    
    if [ -z "$node" ]; then
        node=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
    fi
    
    if [ -n "$node" ]; then
        local server=$(uci get "passwall.$node.address" 2>/dev/null)
        
        if [ -n "$server" ]; then
            if echo "$server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "$server"
                return
            else
                local resolved=$(nslookup "$server" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
                if [ -n "$resolved" ]; then
                    echo "$resolved"
                    return
                fi
            fi
        fi
    fi
    
    # Fallback to 8.8.8.8
    echo "8.8.8.8"
}

do_live_ping() {
    local target=$(get_ping_target)
    local ping_output=$(ping -c 3 -W 1 "$target" 2>/dev/null)
    
    if [ -z "$ping_output" ]; then
        echo "timeout|0|100"
        return
    fi
    
    local stats=$(echo "$ping_output" | grep "min/avg/max")
    
    if [ -z "$stats" ]; then
        echo "timeout|0|100"
        return
    fi
    
    local values=$(echo "$stats" | cut -d'=' -f2 | tr -d ' ms')
    local min=$(echo "$values" | cut -d'/' -f1)
    local avg=$(echo "$values" | cut -d'/' -f2)
    local max=$(echo "$values" | cut -d'/' -f3)
    local jitter=$(awk "BEGIN {printf \"%.0f\", $max - $min}")
    local loss=$(echo "$ping_output" | grep -o '[0-9]*% packet loss' | grep -o '[0-9]*')
    avg=$(awk "BEGIN {printf \"%.3f\", $avg}")
    
    printf "%s|%s|%s" "$avg" "$jitter" "${loss:-0}"
}

# ==================== EXTRACT INFO FROM LOG ====================

# Extract last CONNECTION STATUS block from log
if [ -f "$LOG" ]; then
    LAST_STATUS=$(grep -A 30 "CONNECTION STATUS" "$LOG" | tail -35)
    
    # Extract IP line
    IP_LINE=$(echo "$LAST_STATUS" | grep "IP:" | tail -1 | sed 's/^[0-9-]* [0-9:]* //')
    if [ -n "$IP_LINE" ]; then
        printf "\033[0;32m%s\033[0m\n" "$IP_LINE"
    fi
    
    # Extract Location
    LOCATION=$(echo "$LAST_STATUS" | grep "Location:" | tail -1 | sed 's/^[0-9-]* [0-9:]* //')
    if [ -n "$LOCATION" ]; then
        echo "$LOCATION"
    fi
    
    # Extract ISP
    ISP_LINE=$(echo "$LAST_STATUS" | grep "ISP:" | tail -1 | sed 's/^[0-9-]* [0-9:]* //')
    if [ -n "$ISP_LINE" ]; then
        echo "$ISP_LINE"
    fi
    
    # Extract ASN
    ASN_LINE=$(echo "$LAST_STATUS" | grep "ASN:" | tail -1 | sed 's/^[0-9-]* [0-9:]* //')
    if [ -n "$ASN_LINE" ]; then
        echo "$ASN_LINE"
    fi
    
    # ==================== DYNAMIC PING (LIVE!) ====================
    
    printf "Latency: "
    
    # Do live ping
    PING_RESULT=$(do_live_ping)
    AVG=$(echo "$PING_RESULT" | cut -d'|' -f1)
    JITTER=$(echo "$PING_RESULT" | cut -d'|' -f2)
    LOSS=$(echo "$PING_RESULT" | cut -d'|' -f3)
    
    if [ "$AVG" = "timeout" ]; then
        printf "\033[0;31mtimeout\033[0m\n"
    else
        # Convert to integer for comparison
        AVG_INT=$(echo "$AVG" | cut -d'.' -f1)
        
        # Determine quality
        if [ "$AVG_INT" -lt 60 ]; then
            QUALITY="Excellent"
            COLOR="\033[0;32m"
        elif [ "$AVG_INT" -lt 100 ]; then
            QUALITY="Good"
            COLOR="\033[0;33m"
        elif [ "$AVG_INT" -lt 150 ]; then
            QUALITY="Fair"
            COLOR="\033[0;33m"
        else
            QUALITY="Poor"
            COLOR="\033[0;31m"
        fi
        
        printf "${COLOR}${AVG} ms ($QUALITY)\033[0m\n"
    fi
    
    # Show packet loss if any
    if [ "$LOSS" != "0" ] && [ -n "$LOSS" ]; then
        printf "\033[0;31mPacket Loss: ${LOSS}%%\033[0m\n"
    else
        printf "\033[0;32mPacket Loss: 0%%\033[0m\n"
    fi
    
    echo ""
    
    # Extract Mode
    MODE=$(echo "$LAST_STATUS" | grep "Mode:" | tail -1 | sed 's/^[0-9-]* [0-9:]* //')
    
    if [ -n "$MODE" ]; then
        printf "\033[0;32m%s\033[0m\n" "$MODE"
    else
        # Fallback: detect from running processes
        MODE_DETECTED=""
        
        if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1; then
            if uci get passwall.@global[0].enabled 2>/dev/null | grep -q '1'; then
                MODE_DETECTED="Passwall"
            fi
        fi
        
        if [ -z "$MODE_DETECTED" ]; then
            if ps | grep openvpn | grep -v grep | grep -v "openvpn(rw)" >/dev/null 2>&1; then
                VPN_NAME=$(ps | grep openvpn | grep -v grep | grep -v "openvpn(rw)" | grep -oE 'openvpn\([a-z0-9]+\)' | sed 's/openvpn(\(.*\))/\1/' | head -1)
                if [ -n "$VPN_NAME" ]; then
                    MODE_DETECTED="OpenVPN ($VPN_NAME)"
                else
                    MODE_DETECTED="OpenVPN"
                fi
            fi
        fi
        
        if [ -z "$MODE_DETECTED" ]; then
            printf "\033[1;33mMode: Unknown\033[0m\n"
            echo ""
            printf "\033[1;33m⚠️  No active VPN connection detected!\033[0m\n"
            echo "  - Passwall: disabled or not running"
            echo "  - OpenVPN: not running"
        else
            printf "\033[0;32mMode: %s\033[0m\n" "$MODE_DETECTED"
        fi
    fi
else
    printf "\033[1;33mMode: Unknown\033[0m\n"
    echo ""
    printf "\033[1;33m⚠️  No log file found\033[0m\n"
    echo "  VPN Switcher may not be running properly"
fi

echo ""
echo "Log: tail -f /tmp/dual-vpn-switcher.log"
echo "═══════════════════════════════════════════════════════════"
echo ""
