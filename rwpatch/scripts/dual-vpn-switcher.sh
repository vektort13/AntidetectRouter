#!/bin/sh
# Dual VPN Switcher v0.1 - UCI Enabled Check
# Manages: fw4, nftables, routing, monitors, DNS
# Usage: /root/dual-vpn-switcher.sh &

LOG="/tmp/dual-vpn-switcher.log"
CHECK_INTERVAL=5
CURRENT_MODE="none"
PASSWALL_FIRST_RUN=1
LOOP_COUNT=0
RW_DOWN_COUNTER=0  # Track how long RW has been down

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
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
    log "=========================================="
    log "CONFIGURING PASSWALL MODE"
    log "=========================================="
    log ""
    
    # 1. Stop OpenVPN upstream (if running)
    local VPN_NAME=$(get_openvpn_name)
    if [ -n "$VPN_NAME" ]; then
        log "[1/7] Stopping OpenVPN: $VPN_NAME"
        /etc/init.d/openvpn stop $VPN_NAME 2>/dev/null
        sleep 2
        log "  ✓ OpenVPN stopped"
    else
        log "[1/7] No OpenVPN upstream running"
    fi
    
    # 2. CRITICAL: STOP + DISABLE fw4
    log "[2/7] Disabling fw4 firewall..."
    
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
    log "[3/7] Cleaning rwfix nftables..."
    if nft list table inet rwfix >/dev/null 2>&1; then
        nft delete table inet rwfix 2>/dev/null
        log "  ✓ rwfix removed"
    fi
    
    # 4. Flush vpnout table
    log "[4/7] Flushing vpnout table..."
    if ip route show table vpnout 2>/dev/null | grep -q .; then
        ip route flush table vpnout 2>/dev/null
        log "  ✓ vpnout flushed"
    fi
    
    # 5. Remove IP rules
    log "[5/7] Cleaning IP rules..."
    while ip rule del iif tun0 lookup vpnout 2>/dev/null; do :; done
    log "  ✓ IP rules cleaned"
    
    # 6. Stop vpn-dns-monitor
    log "[6/7] Stopping vpn-dns-monitor..."
    if pgrep -f vpn-dns-monitor.sh >/dev/null; then
        killall vpn-dns-monitor.sh 2>/dev/null
        log "  ✓ vpn-dns-monitor stopped"
    fi
    
    # 7. Restart Passwall (let it configure itself)
    log "[7/7] Restarting Passwall..."
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
    
    # Wait for Passwall to stabilize
    log "  Waiting for Passwall to stabilize..."
    sleep 5
    
    # 8. Verify Passwall is working WITH RETRY
    local RETRY=0
    local MAX_RETRIES=2
    
    while [ $RETRY -le $MAX_RETRIES ]; do
        if is_passwall_ready; then
            log ""
            log "✅ PASSWALL MODE ACTIVE!"
            log "  ✓ fw4 disabled"
            
            # Check if Passwall created nftables (TCP/UDP mode) or not (SOCKS5-only mode)
            if nft list table inet passwall >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
                log "  ✓ Passwall nftables created (TCP/UDP mode)"
            else
                log "  ⚠️  Passwall running in SOCKS5-only mode (no nftables)"
            fi
            
            log "  ✓ RW clients (tun0) → Passwall"
            log ""
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
            sleep 10
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
        /root/vpn-dns-monitor.sh "$VPN_NAME" &
        sleep 2
        log "  ✓ vpn-dns-monitor started for $VPN_NAME"
    else
        log "  ⚠️ vpn-dns-monitor.sh not found!"
    fi
    
    # 7. Done
    log ""
    log "✅ OPENVPN MODE ACTIVE!"
    log "  ✓ fw4 enabled"
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
log "Dual VPN Switcher v11.10 - UCI Check"
log "=========================================="
log "Monitoring: Passwall + OpenVPN"
log "Check interval: ${CHECK_INTERVAL}s"
log ""
log "Function: Auto-switch between modes"
log "  - Passwall ready → PASSWALL MODE (fw4 OFF)"
log "  - OpenVPN ready → OPENVPN MODE (fw4 ON + DNS)"
log "  - RW (tun0) down > 10s → Auto-restart RW"
log ""

# Wait for system to stabilize
log "Waiting for system to stabilize..."
sleep 10

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

log "✓ Initial cleanup complete"
log ""

# Wait a bit more
sleep 5

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
    
    sleep $CHECK_INTERVAL
done
