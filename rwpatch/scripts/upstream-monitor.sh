#!/bin/sh
# Upstream VPN Monitor - Auto rw-fix when upstream connects
# Monitors tun1 and automatically runs rw-fix when it appears
# Usage: /root/upstream-monitor.sh &

LOG="/tmp/upstream-monitor.log"
CHECK_INTERVAL=5
LAST_STATE="down"

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

# Check if tun1 exists and is UP
is_tun1_up() {
    if ip link show tun1 2>/dev/null | grep -q "state UP"; then
        return 0
    else
        return 1
    fi
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
log "Monitoring: tun1"
log "Check interval: ${CHECK_INTERVAL}s"
log ""
log "Function: Auto-run rw-fix when upstream VPN connects"
log ""

# Initial check
if ! is_rw_running; then
    log "⚠ RW not running! Waiting for RW..."
fi

if is_tun1_up; then
    log "✓ tun1 already UP at startup"
    LAST_STATE="up"
    
    if is_vpnout_configured; then
        log "✓ vpnout already configured (no action needed)"
    else
        log "  vpnout not configured, running rw-fix..."
        run_rwfix
    fi
else
    log "⚠ tun1 DOWN at startup"
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
    
    # Check tun1 state
    if is_tun1_up; then
        # tun1 is UP
        if [ "$LAST_STATE" != "up" ]; then
            # State changed: DOWN → UP
            TUN1_IP=$(ip addr show tun1 2>/dev/null | grep 'inet ' | awk '{print $2}')
            log ""
            log "=== tun1 UP DETECTED ==="
            log "Interface: tun1"
            log "IP: ${TUN1_IP:-unknown}"
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
        # tun1 is DOWN
        if [ "$LAST_STATE" = "up" ]; then
            # State changed: UP → DOWN
            log ""
            log "=== tun1 DOWN DETECTED ==="
            log "Upstream VPN disconnected"
            log ""
            
            # Note: We don't remove vpnout table here
            # It will be reconfigured when tun1 comes back up
            
            LAST_STATE="down"
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
