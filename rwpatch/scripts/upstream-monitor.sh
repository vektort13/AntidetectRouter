#!/bin/sh
# Upstream VPN Monitor - Auto rw-fix when upstream connects
# Monitors upstream tun[1..N] and automatically runs rw-fix when it appears
# Usage: /root/upstream-monitor.sh &

LOG="/tmp/upstream-monitor.log"
CHECK_INTERVAL=2  
LAST_STATE="down"
CURRENT_UPSTREAM_TUN=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Check if Passwall is active (should disable upstream-monitor)
is_passwall_active() {
    # Check for xray/v2ray/sing-box processes
    if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1 || pgrep sing-box >/dev/null 2>&1; then
        return 0
    fi
    
    # Check Passwall nftables
    if nft list table inet passwall >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Detect active upstream tun interface (exclude tun0/RW)
detect_upstream_tun() {
    local dev

    for dev in $(ip -o link show | awk -F': ' '/: tun[1-9][0-9]*/ {print $2}' | sort -V); do
        # Check for UP flag, not "state UP" (can be state UNKNOWN but still usable)
        if ip link show "$dev" 2>/dev/null | grep -q "UP,LOWER_UP"; then
            echo "$dev"
            return 0
        fi
    done

    return 1
}

is_upstream_tun_up() {
    CURRENT_UPSTREAM_TUN="$(detect_upstream_tun || true)"
    [ -n "$CURRENT_UPSTREAM_TUN" ]
}

# Check if RW is running
is_rw_running() {
    if pgrep -f "openvpn.*rw" >/dev/null && ip link show tun0 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check if vpnout table is configured
is_vpnout_configured() {
    if ip route show table vpnout 2>/dev/null | grep -q "default"; then
        if ip rule show | grep -q "lookup vpnout"; then
            return 0
        fi
    fi
    return 1
}

# Run rw-fix
run_rwfix() {
    log "Running rw-fix..."
    
    if /usr/sbin/rw-fix >> "$LOG" 2>&1; then
        log "✓ rw-fix completed"
        
        # Verify configuration
        if is_vpnout_configured; then
            DEFAULT=$(ip route show table vpnout | grep default)
            log "✓ vpnout configured: $DEFAULT"
            
            RULE=$(ip rule show | grep vpnout | head -1)
            log "✓ IP rule: $RULE"
            
            return 0
        else
            log "⚠ vpnout not properly configured"
            return 1
        fi
    else
        log "✗ rw-fix failed!"
        return 1
    fi
}

# ==================== MAIN ====================

: > "$LOG"

log "=========================================="
log "Upstream VPN Monitor Started"
log "=========================================="
log "Monitoring: upstream tun[1..N]"
log "Check interval: ${CHECK_INTERVAL}s"
log ""
log "Function: Auto-run rw-fix when upstream VPN connects"
log ""

# Initial check
if ! is_rw_running; then
    log "⚠ RW not running! Waiting for RW..."
fi

if is_upstream_tun_up; then
    log "✓ ${CURRENT_UPSTREAM_TUN} already UP at startup"
    LAST_STATE="up"
    
    if is_vpnout_configured; then
        log "✓ vpnout already configured (no action needed)"
    else
        log "  vpnout not configured, running rw-fix..."
        run_rwfix
    fi
else
    log "⚠ upstream tun DOWN at startup"
    LAST_STATE="down"
fi

log ""
log "Monitoring started..."
log ""

# Main monitoring loop
while true; do
    # Check if Passwall is active - if yes, skip monitoring
    if is_passwall_active; then
        if [ "$LAST_STATE" != "passwall" ]; then
            log ""
            log "=== PASSWALL DETECTED ==="
            log "Passwall is active, pausing upstream monitoring"
            log "upstream-monitor will resume when Passwall stops"
            log ""
            LAST_STATE="passwall"
        fi
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # Passwall is not active, resume normal monitoring
    if [ "$LAST_STATE" = "passwall" ]; then
        log ""
        log "=== PASSWALL STOPPED ==="
        log "Resuming upstream VPN monitoring"
        log ""
        LAST_STATE="down"
    fi
    
    # Check RW is running
    if ! is_rw_running; then
        if [ "$LAST_STATE" != "no_rw" ]; then
            log "⚠ RW not running! Waiting for RW..."
            LAST_STATE="no_rw"
        fi
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # Check upstream tun state
    if is_upstream_tun_up; then
        # upstream tun is UP
        if [ "$LAST_STATE" != "up" ]; then
            # State changed: DOWN → UP
            UPSTREAM_IP=$(ip addr show "$CURRENT_UPSTREAM_TUN" 2>/dev/null | grep 'inet ' | awk '{print $2}')
            log ""
            log "=== ${CURRENT_UPSTREAM_TUN} UP DETECTED ==="
            log "Interface: ${CURRENT_UPSTREAM_TUN}"
            log "IP: ${UPSTREAM_IP:-unknown}"
            log ""
            
            # Check if already configured
            if is_vpnout_configured; then
                log "✓ vpnout already configured (skipping rw-fix)"
            else
                # Need to configure
                run_rwfix
            fi
            
            LAST_STATE="up"
            log ""
        fi
    else
        # upstream tun is DOWN
        if [ "$LAST_STATE" = "up" ]; then
            # State changed: UP → DOWN
            log ""
            log "=== upstream tun DOWN DETECTED ==="
            log "Upstream VPN disconnected"
            log ""
            
            # Note: We don't remove vpnout table here
            # It will be reconfigured when upstream tun comes back up
            
            LAST_STATE="down"
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
