#!/bin/sh
# Dual VPN Switcher v NASTOIASHAYA JABA - DNS Leak Protection Edition
# Manages: fw4, nftables, routing, monitors, DNS
# Usage: /root/dual-vpn-switcher.sh &

LOG="/tmp/dual-vpn-switcher.log"
CHECK_INTERVAL=2  # 
CURRENT_MODE="none"
PASSWALL_FIRST_RUN=1
LOOP_COUNT=0
RW_DOWN_COUNTER=0  # Track how long RW has been down

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# ==================== KILL SWITCH ====================
# Block RW client traffic when no VPN is active

KILL_SWITCH_ENABLED=1  # Set to 0 to disable
RW_IF="$(uci -q get openvpn.rw.dev 2>/dev/null || echo tun0)"

# Apply kill switch rules
# Apply kill switch rules (no fw4 dependency)
apply_kill_switch() {
    [ "$KILL_SWITCH_ENABLED" = "1" ] || return 0

    # Refresh RW_IF each time (in case UCI changes)
    RW_IF="$(uci -q get openvpn.rw.dev 2>/dev/null || echo tun0)"

    # If interface doesn't exist yet - skip
    if ! ip link show "$RW_IF" >/dev/null 2>&1; then
        log "⚠️  Kill Switch: $RW_IF not found, skipping"
        return 0
    fi

    log "⛔ Kill Switch: Blocking RW traffic on $RW_IF (no VPN active)"

    # Dedicated table that Passwall/fw4 won't delete
    nft delete table inet rwks 2>/dev/null || true

    nft -f - <<EOF
add table inet rwks
add chain inet rwks forward { type filter hook forward priority -150; policy accept; }
add rule inet rwks forward iifname "$RW_IF" ip daddr 192.168.0.0/16 accept
add rule inet rwks forward iifname "$RW_IF" ip daddr 10.0.0.0/8 accept
add rule inet rwks forward iifname "$RW_IF" ip daddr 172.16.0.0/12 accept
add rule inet rwks forward iifname "$RW_IF" drop
EOF

    log "✓ Kill Switch: RW blocked from internet (local nets allowed)"
}

# Remove kill switch rules
remove_kill_switch() {
    [ "$KILL_SWITCH_ENABLED" = "1" ] || return 0

    nft delete table inet rwks 2>/dev/null || true
    log "✓ Kill Switch: RW unblocked"
}

# ==================== ENHANCED CONNECTION STATUS DISPLAY ====================

# Get SOCKS proxy IP from Passwall config
get_socks_ip() {
    local node=$(uci get passwall.@global[0].socks_node 2>/dev/null)
    
    if [ -z "$node" ]; then
        node=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
    fi
    
    if [ -n "$node" ]; then
        local server=$(uci get "passwall.$node.address" 2>/dev/null)
        
        if [ -n "$server" ]; then
            if echo "$server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "$server"
            else
                local resolved=$(nslookup "$server" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
                if [ -n "$resolved" ]; then
                    echo "$resolved"
                else
                    echo "$server"
                fi
            fi
        fi
    fi
}

# Get external IP with geolocation
get_ip_with_geo() {
    local response=$(curl -s --max-time 2 "https://ipinfo.io/json" 2>/dev/null)
    
    if [ -n "$response" ]; then
        local ip=$(echo "$response" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
        local city=$(echo "$response" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
        local region=$(echo "$response" | grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
        local org=$(echo "$response" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$city" ] && [ -n "$region" ]; then
            printf "%s (%s, %s) - %s" "$ip" "$city" "$region" "$org"
        elif [ -n "$ip" ]; then
            echo "$ip"
        else
            echo "Unknown"
        fi
    else
        echo "Unknown"
    fi
}

# Advanced ping metrics with auto SOCKS detection
get_ping_metrics() {
    local target=$(get_socks_ip)
    
    if [ -z "$target" ]; then
        target="8.8.8.8"
    fi
    
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
    avg=$(awk "BEGIN {printf \"%.0f\", $avg}")
    
    printf "%s|%s|%s" "$avg" "$jitter" "${loss:-0}"
}

# Create progress bar
create_bar() {
    local value=$1
    local max=$2
    local width=10
    local color=$3
    
    local filled=$(( value * width / max ))
    if [ $filled -gt $width ]; then
        filled=$width
    fi
    
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    while [ $i -lt $width ]; do
        bar="${bar}░"
        i=$((i + 1))
    done
    
    printf "\033[%sm[%s]\033[0m" "$color" "$bar"
}

# Get latency color
get_latency_color() {
    local latency=$1
    
    if [ "$latency" = "timeout" ] || [ "$latency" -gt 200 ]; then
        echo "0;31"
    elif [ "$latency" -gt 100 ]; then
        echo "1;33"
    else
        echo "0;32"
    fi
}

# Get quality label
get_quality_label() {
    local latency=$1
    
    if [ "$latency" = "timeout" ]; then
        echo "No Connection"
    elif [ "$latency" -lt 30 ]; then
        echo "Excellent"
    elif [ "$latency" -lt 60 ]; then
        echo "Good"
    elif [ "$latency" -lt 100 ]; then
        echo "Fair"
    elif [ "$latency" -lt 200 ]; then
        echo "Poor"
    else
        echo "Very Poor"
    fi
}

# Main enhanced connection status display
show_connection_status() {
    local mode="${1:-Unknown}"
    
    log ""
    log "=========================================="
    log "CONNECTION STATUS"
    log "=========================================="
    log ""
    
    # Получить IP через несколько источников (fallback)
    CURRENT_IP=""
    
    # Попытка 1: icanhazip.com
    CURRENT_IP=$(curl -s --max-time 3 icanhazip.com 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    
    # Попытка 2: ifconfig.me
    if [ -z "$CURRENT_IP" ]; then
        CURRENT_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    fi
    
    # Попытка 3: api.ipify.org
    if [ -z "$CURRENT_IP" ]; then
        CURRENT_IP=$(curl -s --max-time 3 api.ipify.org 2>/dev/null | tr -d '\n\r ' | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
    fi
    
    if [ -z "$CURRENT_IP" ]; then
        log "IP: Unknown (failed to fetch)"
    else
        log "IP: $CURRENT_IP"
        
        # Получить геолокацию через ip-api.com
        GEO_JSON=$(curl -s --max-time 4 "http://ip-api.com/json/$CURRENT_IP?fields=status,country,regionName,city,isp,as" 2>/dev/null)
        
        if [ -n "$GEO_JSON" ] && echo "$GEO_JSON" | grep -q '"status":"success"'; then
            # ПРАВИЛЬНЫЙ парсинг JSON (grep + cut)
            CITY=$(echo "$GEO_JSON" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
            REGION=$(echo "$GEO_JSON" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
            COUNTRY=$(echo "$GEO_JSON" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
            ISP=$(echo "$GEO_JSON" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
            ASN=$(echo "$GEO_JSON" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
            
            # Формируем строку локации
            LOCATION=""
            [ -n "$CITY" ] && LOCATION="$CITY"
            [ -n "$REGION" ] && LOCATION="${LOCATION:+$LOCATION, }$REGION"
            [ -n "$COUNTRY" ] && LOCATION="${LOCATION:+$LOCATION, }$COUNTRY"
            
            [ -n "$LOCATION" ] && log "Location: $LOCATION"
            [ -n "$ISP" ] && log "ISP: $ISP"
            [ -n "$ASN" ] && log "ASN: $ASN"
        fi
    fi
    
    # Получаем IP активного прокси из Passwall (НЕ ХАРДКОД!)
    PROXY_IP=""
    
    # Приоритет: SOCKS > TCP > UDP
    local socks_node=$(uci get passwall.@global[0].socks_node 2>/dev/null)
    if [ -n "$socks_node" ] && [ "$socks_node" != "nil" ]; then
        PROXY_IP=$(uci get passwall.$socks_node.address 2>/dev/null)
    fi
    
    if [ -z "$PROXY_IP" ]; then
        local tcp_node=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
        if [ -n "$tcp_node" ] && [ "$tcp_node" != "nil" ]; then
            PROXY_IP=$(uci get passwall.$tcp_node.address 2>/dev/null)
        fi
    fi
    
    if [ -z "$PROXY_IP" ]; then
        local udp_node=$(uci get passwall.@global[0].udp_node 2>/dev/null)
        if [ -n "$udp_node" ] && [ "$udp_node" != "nil" ]; then
            PROXY_IP=$(uci get passwall.$udp_node.address 2>/dev/null)
        fi
    fi
    
    # Fallback на Google DNS если не нашли прокси
    if [ -z "$PROXY_IP" ]; then
        PROXY_IP="8.8.8.8"
        log "⚠️  Warning: Could not find proxy IP, using Google DNS for ping"
    fi
    
    # Ping test к ПРОКСИ (не к Google!)
    PING_RESULT=$(ping -c 3 -W 2 "$PROXY_IP" 2>/dev/null)
    
    if [ -n "$PING_RESULT" ]; then
        # Извлекаем среднюю латентность
        LATENCY=$(echo "$PING_RESULT" | grep 'avg' | awk -F'/' '{print $5}')
        
        # Извлекаем packet loss
        PACKETLOSS=$(echo "$PING_RESULT" | grep 'packet loss' | grep -o '[0-9]*%' | head -1)
        
        if [ -n "$LATENCY" ]; then
            # Оценка качества
            LATENCY_INT=$(echo "$LATENCY" | cut -d. -f1)
            
            if [ "$LATENCY_INT" -lt 50 ]; then
                QUALITY="Excellent"
            elif [ "$LATENCY_INT" -lt 100 ]; then
                QUALITY="Good"
            elif [ "$LATENCY_INT" -lt 150 ]; then
                QUALITY="Fair"
            else
                QUALITY="Poor"
            fi
            
            log "Latency: ${LATENCY} ($QUALITY)"
        fi
        
        [ -n "$PACKETLOSS" ] && log "Packet Loss: $PACKETLOSS"
        
        # Jitter (опционально)
        if [ "$mode" = "Passwall" ] || [ "$mode" = "OpenVPN" ]; then
            PING_JITTER=$(ping -c 10 -W 2 8.8.8.8 2>/dev/null | grep 'avg' | awk -F'/' '{print $7}')
            [ -n "$PING_JITTER" ] && log "Jitter: ${PING_JITTER}ms"
        fi
    fi
    
    log "Mode: $mode"
    log ""
    log "=========================================="
    log ""
}



# ==================== PERMANENT PASSWALL DNS FIX ====================

apply_permanent_passwall_dns_fix() {
    local LUA_FILE="/usr/share/passwall/helper_chinadns_add.lua"
    local MARKER="FORCE_DEFAULT_TAG_GFW_FINAL"
    
    # Check if already patched (v2)
    if grep -q "$MARKER" "$LUA_FILE" 2>/dev/null; then
        log "✓ Passwall DNS patch already applied (v2)"
        return 0
    fi
    
    log ""
    log "=========================================="
    log "APPLYING PERMANENT PASSWALL DNS FIX (v2)"
    log "=========================================="
    log ""
    log "This ONE-TIME patch forces default-tag=gfw"
    log "(All DNS queries will use proxy DNS)"
    log ""
    
    # Check file exists
    if [ ! -f "$LUA_FILE" ]; then
        log "✗ Passwall LUA file not found: $LUA_FILE"
        return 1
    fi
    
    # Backup
    cp "$LUA_FILE" "${LUA_FILE}.backup.v2" 2>/dev/null
    log "✓ Backup created: ${LUA_FILE}.backup.v2"
    
    # Find line with table.insert default-tag
    local LINE_NUM=$(grep -n 'table.insert(config_lines, "default-tag' "$LUA_FILE" | cut -d: -f1)
    
    if [ -z "$LINE_NUM" ]; then
        log "✗ Cannot find 'default-tag' line in LUA file"
        return 1
    fi
    
    log "✓ Found patch location at line $LINE_NUM"
    
    # Apply patch BEFORE table.insert line
    sed -i "${LINE_NUM}i\\
-- $MARKER\\
DEFAULT_TAG = \"gfw\"" "$LUA_FILE"
    
    # Verify
    if grep -q "$MARKER" "$LUA_FILE"; then
        log "✓ Passwall DNS patch applied successfully!"
        log "  File: $LUA_FILE"
        log "  Effect: default-tag will ALWAYS be 'gfw'"
        log "  Result: All domains use proxy DNS (no leaks!)"
        log ""
        log "✓ PERMANENT FIX APPLIED!"
        return 0
    else
        log "✗ Failed to apply patch"
        return 1
    fi
}

# Fix dnsmasq DNS leak
fix_dnsmasq_dns_leak() {
    log ""
    log "=========================================="
    log "FIXING DNSMASQ DNS LEAK"
    log "=========================================="
    log ""
    
    # Remove all DNS servers from dnsmasq
    local removed=0
    while uci -q delete dhcp.@dnsmasq[0].server; do
        removed=$((removed + 1))
    done
    
    if [ $removed -gt 0 ]; then
        log "✓ Removed $removed DNS server(s) from dnsmasq"
    else
        log "✓ No DNS servers in dnsmasq (already clean)"
    fi
    
    # Set noresolv=1 (don't read system resolv.conf)
    uci set dhcp.@dnsmasq[0].noresolv='1'
    log "✓ Set noresolv=1 (dnsmasq won't read system DNS)"
    
    # Commit
    uci commit dhcp
    log "✓ Changes committed"
    
    # Reload dnsmasq
    /etc/init.d/dnsmasq reload 2>/dev/null
    sleep 1
    
    if pgrep dnsmasq >/dev/null; then
        log "✓ dnsmasq reloaded successfully"
    else
        log "⚠️  dnsmasq not running, restarting..."
        /etc/init.d/dnsmasq restart 2>/dev/null
    fi
    
    log ""
    log "✓ DNS LEAK FIX COMPLETED"
}

# ==================== AUTO-SHOW VPN STATUS ON LOGIN ====================

setup_auto_show_vpn_status() {
    local SHINIT_FILE="/etc/shinit"
    local SHOW_SCRIPT="/root/show-vpn-status.sh"
    local MARKER="show-vpn-status.sh"
    
    # Check if already configured
    if grep -q "$MARKER" "$SHINIT_FILE" 2>/dev/null; then
        return 0  # Already configured, skip
    fi
    
    log ""
    log "=========================================="
    log "SETTING UP AUTO-SHOW VPN STATUS"
    log "=========================================="
    log ""
    log "This is a ONE-TIME setup that adds auto-display"
    log "of VPN status when opening SSH/console"
    log ""
    
    # Check if show-vpn-status.sh exists
    if [ ! -f "$SHOW_SCRIPT" ]; then
        log "⚠️  $SHOW_SCRIPT not found - creating it now..."
        
        # Create show-vpn-status.sh with ENHANCED display
        cat > "$SHOW_SCRIPT" << 'EOFSCRIPT'
#!/bin/sh
# Display Enhanced VPN Status on Login

show_vpn_status() {
    local LOG="/tmp/dual-vpn-switcher.log"
    
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
        return
    fi
    
    # Show last status from log with colors
    if [ -f "$LOG" ]; then
        # Extract IP (full geolocation line)
        local ip=$(tail -100 "$LOG" | grep "IP:" | grep -v "Ping target" | tail -1 | sed 's/.*IP: //')
        if [ -n "$ip" ]; then
            printf "\033[0;32mIP: %s\033[0m\n" "$ip"
        fi
        
        # Extract Latency
        local latency=$(tail -100 "$LOG" | grep "Latency:" | tail -1 | sed 's/.*Latency: //')
        if [ -n "$latency" ]; then
            if echo "$latency" | grep -q "Excellent\|Good"; then
                printf "\033[0;32mLatency: %s\033[0m\n" "$latency"
            elif echo "$latency" | grep -q "Fair"; then
                printf "\033[1;33mLatency: %s\033[0m\n" "$latency"
            else
                printf "\033[0;31mLatency: %s\033[0m\n" "$latency"
            fi
        fi
        
        # Extract Jitter
        local jitter=$(tail -100 "$LOG" | grep "Jitter:" | tail -1 | sed 's/.*Jitter: //')
        if [ -n "$jitter" ]; then
            printf "Jitter: %s\n" "$jitter"
        fi
        
        # Extract Packet Loss
        local loss=$(tail -100 "$LOG" | grep "Packet Loss:" | tail -1 | sed 's/.*Packet Loss: //')
        if [ -n "$loss" ]; then
            if echo "$loss" | grep -q "0%"; then
                printf "\033[0;32mPacket Loss: %s\033[0m\n" "$loss"
            else
                printf "\033[0;31mPacket Loss: %s\033[0m\n" "$loss"
            fi
        fi
        
        echo ""
        
        # Extract Mode
        local mode=$(tail -100 "$LOG" | grep "Mode:" | tail -1 | sed 's/.*Mode: //')
        if [ -n "$mode" ]; then
            printf "\033[0;32mMode: %s\033[0m\n" "$mode"
        fi
    else
        echo "No log file found."
    fi
    
    echo ""
    echo "Log: tail -f /tmp/dual-vpn-switcher.log"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

# Run on login
show_vpn_status
EOFSCRIPT
        
        chmod +x "$SHOW_SCRIPT"
        log "✓ Created: $SHOW_SCRIPT"
    fi
    
    # Backup /etc/shinit
    if [ -f "$SHINIT_FILE" ]; then
        cp "$SHINIT_FILE" "${SHINIT_FILE}.backup" 2>/dev/null
        log "✓ Backup created: ${SHINIT_FILE}.backup"
    fi
    
    # Add to /etc/shinit
    cat >> "$SHINIT_FILE" << 'EOF'

# Auto-show VPN status
[ -f /root/show-vpn-status.sh ] && /root/show-vpn-status.sh
EOF
    
    # Verify
    if grep -q "$MARKER" "$SHINIT_FILE"; then
        log "✓ Auto-show configured in $SHINIT_FILE"
        log "  Now VPN status will display on every console login"
        log ""
        log "✓ SETUP COMPLETE - This will survive reboots!"
        return 0
    else
        log "✗ Failed to configure auto-show"
        return 1
    fi
}


# ==================== DNS PATCH FUNCTION (Legacy - kept for compatibility) ====================

patch_passwall_dns() {
    log ""
    log "Checking Passwall DNS configuration..."
    
    # Wait for Passwall to fully start and create config (optimized: was 5)
    sleep 2
    
    # Check if chinadns-ng config exists
    if [ ! -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        log "  ⚠️  chinadns-ng config not found yet - waiting..."
        sleep 3
    fi
    
    if [ -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        # Check if already patched
        if grep -q "^default-tag gfw" /tmp/etc/passwall/acl/default/chinadns_ng.conf; then
            log "  ✓ DNS already configured: default-tag gfw"
            log ""
            return 0
        fi
        
        # Need to patch
        log "  Patching DNS: default-tag chn → gfw"
        
        # Kill chinadns-ng
        killall chinadns-ng 2>/dev/null
        sleep 1
        
        # Patch config: change default-tag from 'chn' to 'gfw'
        sed -i 's/^default-tag chn$/default-tag gfw/' /tmp/etc/passwall/acl/default/chinadns_ng.conf
        
        # Verify patch
        if grep -q "^default-tag gfw" /tmp/etc/passwall/acl/default/chinadns_ng.conf; then
            log "  ✓ Patch applied successfully"
        else
            log "  ⚠️  Patch failed!"
        fi
        
        # Restart chinadns-ng with patched config
        /tmp/etc/passwall/bin/chinadns-ng -C /tmp/etc/passwall/acl/default/chinadns_ng.conf >/dev/null 2>&1 &
        sleep 2
        
        if pgrep chinadns-ng >/dev/null; then
            log "  ✓ chinadns-ng restarted"
        else
            log "  ✗ chinadns-ng failed to start!"
        fi
    else
        log "  ✗ chinadns-ng config not found!"
    fi
    
    log ""
}

# ==================== DETECTION FUNCTIONS ====================

# Check if Passwall is ready (process + UCI check!)
is_passwall_ready() {
    # CRITICAL: Check if Main switch is enabled
    # If disabled in UCI, Passwall is NOT ready (even if process exists!)
    if ! uci get passwall.@global[0].enabled 2>/dev/null | grep -q '1'; then
        return 1  # Main switch OFF → not ready
    fi
    
    # Check for xray/v2ray/sing-box processes
    # NOTE: Process alone is enough - nftables may not exist for SOCKS5-only config!
    if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1 || pgrep sing-box >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Check if OpenVPN is ready - FIXED for state UNKNOWN
is_openvpn_ready() {
    # Check if ANY tun interface (except tun0/RW) is UP
    # This handles cases where OpenVPN gets tun1, tun2, etc.
    # NOTE: Check for UP flag, not "state UP" - interfaces can be "state UNKNOWN" but still UP!
    local UPSTREAM_TUN=$(ip link show | grep -oE 'tun[1-9][0-9]*' | head -1)
    
    if [ -n "$UPSTREAM_TUN" ]; then
        # Found a tun interface other than tun0
        # Check if it has UP flag (not "state UP" - could be "state UNKNOWN")
        if ip link show "$UPSTREAM_TUN" 2>/dev/null | grep -q "UP,LOWER_UP"; then
            return 0
        fi
    fi
    
    return 1
}

# Get OpenVPN name (det/mol/vpv/etc)
get_openvpn_name() {
    ps | grep openvpn | grep -v rw | grep -oE 'openvpn\([a-z0-9]+\)' | sed 's/openvpn(\(.*\))/\1/' | head -1
}

# Check if RW is running
is_rw_running() {
    if pgrep -f "openvpn.*rw" >/dev/null && ip link show tun0 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ==================== PASSWALL MODE ====================

configure_passwall() {
    log ""
    # Kill switch: unblock when Passwall activates
    remove_kill_switch
    
    log "=========================================="
    log "CONFIGURING PASSWALL MODE"
    log "=========================================="
    log ""
    
    # 1. Stop OpenVPN upstream (if running)
    local VPN_NAME=$(get_openvpn_name)
    if [ -n "$VPN_NAME" ]; then
        log "[1/8] Stopping OpenVPN: $VPN_NAME"
        /etc/init.d/openvpn stop $VPN_NAME 2>/dev/null
        sleep 1  # Optimized: was 2
        log "  ✓ OpenVPN stopped"
    else
        log "[1/8] No OpenVPN upstream running"
    fi
    
    # 2. CRITICAL: STOP + DISABLE fw4
    log "[2/8] Disabling fw4 firewall..."
    
    /etc/init.d/firewall stop 2>/dev/null
    /etc/init.d/firewall disable 2>/dev/null
    
    # Remove ALL firewall symlinks
    rm -f /etc/rc.d/S*firewall* 2>/dev/null
    rm -f /etc/rc.d/K*firewall* 2>/dev/null
    
    # Kill fw4 process
    killall fw4 2>/dev/null
    
    # Delete fw4 nftables
    if nft list table inet fw4 >/dev/null 2>&1; then
        nft delete table inet fw4 2>/dev/null
    fi
    
    log "  ✓ fw4 stopped and disabled"
    
    # 3. Remove rwfix nftables (OpenVPN stuff)
    log "[3/8] Cleaning rwfix nftables..."
    if nft list table inet rwfix >/dev/null 2>&1; then
        nft delete table inet rwfix 2>/dev/null
        log "  ✓ rwfix removed"
    fi
    
    # 4. Flush vpnout table
    log "[4/8] Flushing vpnout table..."
    if ip route show table vpnout 2>/dev/null | grep -q .; then
        ip route flush table vpnout 2>/dev/null
        log "  ✓ vpnout flushed"
    fi
    
    # 5. Remove IP rules
    log "[5/8] Cleaning IP rules..."
    while ip rule del iif tun0 lookup vpnout 2>/dev/null; do :; done
    # CRITICAL: Also remove fwmark rules left by OpenVPN
    while ip rule del fwmark 0x1 lookup vpnout 2>/dev/null; do :; done
    log "  ✓ IP rules cleaned (iif tun0 + fwmark)"
    
    # 6. Stop vpn-dns-monitor
    log "[6/8] Stopping vpn-dns-monitor..."
    if pgrep -f vpn-dns-monitor.sh >/dev/null; then
        killall vpn-dns-monitor.sh 2>/dev/null
        log "  ✓ vpn-dns-monitor stopped"
    fi
    
    # 7. Restart Passwall (let it configure itself)
    log "[7/8] Restarting Passwall..."
    log ""
    
    # On first run, do extra restart for clean state
    if [ $PASSWALL_FIRST_RUN -eq 1 ]; then
        log "  First Passwall activation - thorough restart..."
        /etc/init.d/passwall stop 2>/dev/null
        sleep 3
        /etc/init.d/passwall start 2>&1 | tee -a "$LOG"
        PASSWALL_FIRST_RUN=0
    else
        /etc/init.d/passwall restart 2>&1 | tee -a "$LOG"
    fi
    
    # Wait for Passwall to stabilize (optimized)
    log "  Waiting for Passwall to stabilize..."
    sleep 3  # Reduced from 5s for faster startup
    
    # 8. Verify Passwall is working WITH RETRY
    local RETRY=0
    local MAX_RETRIES=2
    
    while [ $RETRY -le $MAX_RETRIES ]; do
        if is_passwall_ready; then
            log ""
            log "✅ PASSWALL MODE ACTIVE!"
            log "  ✓ fw4 disabled"
            
            # OPTIMIZED: Quick nftables check + fast restart
            log "  ⏳ Quick nftables check..."
            sleep 3  # Short wait for nftables to be created
            
            # Check if nftables created
            if nft list table inet passwall >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
                log "  ✓ Passwall nftables created (TCP/UDP transparent proxy mode)"
            else
                # nftables not created - force restart immediately (no waiting)
                log "  ⚠️  nftables not created - forcing quick restart..."
                /etc/init.d/passwall stop 2>/dev/null
                sleep 2
                /etc/init.d/passwall start 2>/dev/null
                sleep 3  # Shorter wait
                
                # Final check
                if nft list table inet passwall >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
                    log "  ✓ nftables created after restart!"
                else
                    log "  ❌ nftables STILL not created - running in SOCKS5-only mode"
                    log "  ⚠️  Clients may not have internet! Check Passwall config."
                fi
            fi
            
            log "  ✓ RW clients (tun0) → Passwall"
            
            # CRITICAL: Patch DNS configuration
            log ""
            log "[8/8] Applying DNS patch..."
            patch_passwall_dns
            
            log "✅ PASSWALL CONFIGURATION COMPLETE!"
            log ""
            show_connection_status "Passwall"
            return 0
        fi
        
        # Not ready yet
        RETRY=$((RETRY + 1))
        
        if [ $RETRY -le $MAX_RETRIES ]; then
            log ""
            log "⚠️  Passwall not ready yet, retry $RETRY/$MAX_RETRIES..."
            log "  (xray process not detected or SOCKS port not listening)"
            log ""
            
            # Restart Passwall
            /etc/init.d/passwall restart 2>&1 | tee -a "$LOG"
            sleep 5  # Reduced from 10s for faster retry
        fi
    done
    
    # Still not ready after retries
    log ""
    log "❌ PASSWALL FAILED TO START"
    log "  Passwall is enabled in config but xray did not start"
    log ""
    log "  Diagnostics:"
    log "  - Check: ps | grep xray"
    log "  - Check: netstat -nlp | grep 1070"
    log "  - Check: logread | grep -E 'passwall|xray'"
    log "  - Verify node config in LuCI → Services → Passwall"
    log ""
    return 1
}

# ==================== OPENVPN MODE ====================

configure_openvpn() {
    local VPN_NAME="$1"
    # Kill switch: unblock when OpenVPN activates
    remove_kill_switch
    
    
    log ""
    log "=========================================="
    log "CONFIGURING OPENVPN MODE: $VPN_NAME"
    log "=========================================="
    log ""
    
    # 1. Stop Passwall (if running)
    log "[1/7] Stopping Passwall..."
    if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1 || pgrep sing-box >/dev/null 2>&1; then
        /etc/init.d/passwall stop 2>/dev/null
        sleep 2
        log "  ✓ Passwall stopped"
    else
        log "  ✓ Passwall not running"
    fi
    
    # 2. Remove Passwall nftables
    log "[2/7] Cleaning Passwall nftables..."
    for table in passwall passwall2 passwall_server; do
        if nft list table inet $table >/dev/null 2>&1; then
            nft delete table inet $table 2>/dev/null
            log "  ✓ Removed: inet $table"
        fi
    done
    
    # 3. CRITICAL: ENABLE + START fw4
    log "[3/7] Enabling fw4 firewall..."
    
    /etc/init.d/firewall enable 2>/dev/null
    /etc/init.d/firewall start 2>/dev/null
    
    sleep 2
    
    if nft list table inet fw4 >/dev/null 2>&1; then
        log "  ✓ fw4 started and enabled"
    else
        log "  ⚠️  fw4 may not have started properly"
    fi
    
    # 4. Flush vpnout table (will be reconfigured by rw-fix)
    log "[4/7] Preparing vpnout table..."
    if ip route show table vpnout 2>/dev/null | grep -q .; then
        ip route flush table vpnout 2>/dev/null
        log "  ✓ vpnout flushed"
    fi
    
    # 5. Run rw-fix
    log "[5/7] Running rw-fix..."
    log ""
    
    if /usr/sbin/rw-fix >> "$LOG" 2>&1; then
        log "  ✓ rw-fix completed"
        
        # Verify configuration
        if ip route show table vpnout | grep -q "default"; then
            DEFAULT=$(ip route show table vpnout | grep default)
            log "  ✓ vpnout: $DEFAULT"
        else
            log "  ⚠️  vpnout empty!"
        fi
        
        if ip rule show | grep -q "lookup vpnout"; then
            RULE=$(ip rule show | grep vpnout | head -1)
            log "  ✓ IP rule: $RULE"
        else
            log "  ⚠️  IP rule missing!"
        fi
        
        if nft list table inet rwfix >/dev/null 2>&1; then
            log "  ✓ rwfix nftables created"
        else
            log "  ⚠️  rwfix nftables missing!"
        fi
    else
        log "  ✗ rw-fix failed!"
        return 1
    fi
    
    # 6. CRITICAL: Start vpn-dns-monitor for DNS!
    log ""
    log "[6/7] Starting vpn-dns-monitor..."
    
    killall vpn-dns-monitor.sh 2>/dev/null
    sleep 1
    
    if [ -f /root/vpn-dns-monitor.sh ]; then
        /root/vpn-dns-monitor.sh auto &
        sleep 1  # Optimized: was 2
        log "  ✓ vpn-dns-monitor started in AUTO mode"
    else
        log "  ⚠️ vpn-dns-monitor.sh not found!"
    fi
    
    # 7. Done
    log ""
    log "✅ OPENVPN MODE ACTIVE!"
    log "  ✓ fw4 enabled"
    # Wait for routes to be fully applied before checking IP
    log ""
    log "[7/7] Waiting for routes to stabilize..."
    sleep 3
    
    # Verify that routing through tun1 is working
    ROUTE_CHECK=0
    for i in 1 2 3; do
        if ip route get 8.8.8.8 2>/dev/null | grep -q tun1; then
            ROUTE_CHECK=1
            log "  ✓ Routes stabilized (attempt $i/3)"
            break
        fi
        sleep 2
    done
    
    if [ $ROUTE_CHECK -eq 0 ]; then
        log "  ⚠️  Routes may not be fully applied"
    fi
    
    show_connection_status "OpenVPN"
    log "  ✓ rwfix nftables created"
    log "  ✓ vpnout table configured"
    log "  ✓ vpn-dns-monitor running"
    log "  ✓ RW clients (tun0) → $VPN_NAME (tun1)"
    log ""
    
    return 0
}

# ==================== MAIN ====================

: > "$LOG"

log "=========================================="
log "Dual VPN Switcher v0.7 - OPTIMIZED Edition"
log "=========================================="
log "Monitoring: Passwall + OpenVPN"
log "Check interval: ${CHECK_INTERVAL}s (optimized: was 5s)"
log ""
log "Function: Auto-switch between modes"
log "  - Passwall ready → PASSWALL MODE (fw4 OFF + DNS patch)"
log "  - OpenVPN ready → OPENVPN MODE (fw4 ON + DNS)"
log "  - RW (tun0) down > 10s → Auto-restart RW"
log ""

# Wait for system to stabilize (optimized: was 10)
log "Waiting for system to stabilize..."
sleep 5

# Initial cleanup
log "Performing initial cleanup..."

# Remove orphaned nftables (except current active mode)
for table in rwfix; do
    if nft list table inet $table >/dev/null 2>&1; then
        nft delete table inet $table 2>/dev/null
        log "  Removed orphaned: inet $table"
    fi
done

# Clean vpnout table
if ip route show table vpnout 2>/dev/null | grep -q .; then
    ip route flush table vpnout 2>/dev/null
    log "  Flushed vpnout table"
fi

# Remove IP rules
while ip rule del iif tun0 lookup vpnout 2>/dev/null; do :; done
while ip rule del fwmark 0x1 lookup vpnout 2>/dev/null; do :; done

log "✓ Initial cleanup complete"
log ""

# Apply permanent Passwall DNS fix (one-time, idempotent)
apply_permanent_passwall_dns_fix

# Fix dnsmasq DNS leak (one-time, idempotent)
fix_dnsmasq_dns_leak

# Setup auto-show VPN status on login (one-time, idempotent)
setup_auto_show_vpn_status

# Wait a bit more (optimized: was 5)
sleep 2

log "Starting monitoring..."
log ""

# Main monitoring loop
while true; do
    # Check RW is running (required for both modes)
    if ! is_rw_running; then
        RW_DOWN_COUNTER=$((RW_DOWN_COUNTER + CHECK_INTERVAL))
        
        if [ "$CURRENT_MODE" != "no_rw" ]; then
            log "⚠️  RW (tun0) not running! Waiting..."
            CURRENT_MODE="no_rw"
        fi
        
        # Auto-restart RW if down for more than 10 seconds
        if [ $RW_DOWN_COUNTER -ge 10 ]; then
            log ""
            log "🔄 RW down for ${RW_DOWN_COUNTER}s - attempting auto-restart..."
            log ""
            
            # CRITICAL: Ensure RW is enabled in UCI (required for OpenVPN to start!)
            if ! uci get openvpn.rw.enabled >/dev/null 2>&1 || [ "$(uci get openvpn.rw.enabled 2>/dev/null)" != "1" ]; then
                log "  Setting openvpn.rw.enabled=1 in UCI..."
                uci set openvpn.rw.enabled='1'
                uci commit openvpn
            fi
            
            # Use 'start' instead of 'restart' - RW is already down!
            /etc/init.d/openvpn start rw 2>&1 | tee -a "$LOG"
            sleep 5  # Give RW time to create tun0
            
            # Check if restart succeeded
            if is_rw_running; then
                log ""
                log "✅ RW auto-restart successful!"
                log "   tun0 is back online"
                log ""
                RW_DOWN_COUNTER=0
                CURRENT_MODE="none"  # Force reconfiguration
            else
                log ""
                log "❌ RW auto-restart failed - will retry in ${CHECK_INTERVAL}s"
                log ""
                # Reset counter to retry every 15 seconds (10s wait + 5s interval)
                RW_DOWN_COUNTER=0
            fi
        fi
        
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # RW is running - reset counter
    RW_DOWN_COUNTER=0
    
    # Detect what's ready
    PASSWALL_READY=0
    OPENVPN_READY=0
    
    if is_passwall_ready; then
        PASSWALL_READY=1
    fi
    
    if is_openvpn_ready; then
        OPENVPN_READY=1
        VPN_NAME=$(get_openvpn_name)
    fi
    
    # DEBUG: Log detection results every 30 seconds
    LOOP_COUNT=$((LOOP_COUNT + 1))
    if [ $((LOOP_COUNT % 6)) -eq 0 ]; then
        log "[DEBUG] Detection: Passwall=$PASSWALL_READY, OpenVPN=$OPENVPN_READY, VPN_NAME=$VPN_NAME"
    fi
    
    # Determine desired mode
    DESIRED_MODE="none"
    
    if [ $PASSWALL_READY -eq 1 ] && [ $OPENVPN_READY -eq 0 ]; then
        # Only Passwall ready
        DESIRED_MODE="passwall"
    elif [ $OPENVPN_READY -eq 1 ] && [ $PASSWALL_READY -eq 0 ]; then
        # Only OpenVPN ready
        DESIRED_MODE="openvpn:$VPN_NAME"
    elif [ $PASSWALL_READY -eq 1 ] && [ $OPENVPN_READY -eq 1 ]; then
        # CONFLICT: Both ready!
        log ""
        log "⚠️  CONFLICT: Both Passwall and OpenVPN ready!"
        log "  Preferring OpenVPN: $VPN_NAME"
        log "  (Stopping Passwall...)"
        log ""
        /etc/init.d/passwall stop 2>/dev/null
        DESIRED_MODE="openvpn:$VPN_NAME"
    fi
    
    # Check if mode changed
    if [ "$DESIRED_MODE" != "$CURRENT_MODE" ]; then
        log ""
        log "=== MODE CHANGE DETECTED ==="
        log "Current: $CURRENT_MODE"
        log "Desired: $DESIRED_MODE"
        log ""
        
        case "$DESIRED_MODE" in
            passwall)
                if configure_passwall; then
                    CURRENT_MODE="passwall"
                fi
                ;;
            openvpn:*)
                VPN=$(echo "$DESIRED_MODE" | cut -d: -f2)
                if configure_openvpn "$VPN"; then
                    CURRENT_MODE="$DESIRED_MODE"
                fi
                ;;
            none)
                if [ "$CURRENT_MODE" != "none" ]; then
                    log "=== NO UPSTREAM AVAILABLE ==="
                    log "Neither Passwall nor OpenVPN is ready"
                    log "RW (tun0) has no upstream"
                    log ""
                    CURRENT_MODE="none"
                fi
                ;;
        esac
    fi
    
    # CONTINUOUS DNS PATCH: Auto-fix chinadns-ng if config reverts
    # This runs every loop when Passwall is active
    if [ "$CURRENT_MODE" = "passwall" ] && [ -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        # Check if config needs patching (silently, every 30s)
        if [ $((LOOP_COUNT % 6)) -eq 0 ]; then
            if grep -q "^default-tag chn$" /tmp/etc/passwall/acl/default/chinadns_ng.conf 2>/dev/null; then
                # Config reverted - re-patch silently
                killall chinadns-ng 2>/dev/null
                sleep 1
                sed -i 's/^default-tag chn$/default-tag gfw/' /tmp/etc/passwall/acl/default/chinadns_ng.conf
                /tmp/etc/passwall/bin/chinadns-ng -C /tmp/etc/passwall/acl/default/chinadns_ng.conf >/dev/null 2>&1 &
                log "[AUTO-PATCH] DNS config reverted - re-patched to gfw"
            fi
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
