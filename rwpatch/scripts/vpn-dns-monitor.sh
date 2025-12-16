#!/bin/sh
# VPN DNS Monitor v0.1 - SIMPLIFIED
# Monitors upstream VPN DNS and configures dnsmasq
# NO RW push manipulation - DNS is hardcoded in UCI!
#
# Usage: /root/vpn-dns-monitor.sh [upstream_name]
# Example: /root/vpn-dns-monitor.sh det

LOG="/tmp/vpn-dns-monitor.log"
CHECK_INTERVAL=10
LAST_DNS=""
UPSTREAM_NAME="${1:-det}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Get DNS from upstream VPN logs
get_upstream_dns() {
    local UPSTREAM="$1"
    
    # Method 1: From logread (most reliable)
    local DNS=$(logread | grep "openvpn($UPSTREAM)" | grep "dhcp-option DNS" | tail -1 | sed -n 's/.*dhcp-option DNS \([0-9.]*\).*/\1/p')
    
    # Method 2: From /tmp/openvpn.log if exists
    if [ -z "$DNS" ] && [ -f /tmp/openvpn.log ]; then
        DNS=$(grep "dhcp-option DNS" /tmp/openvpn.log | tail -1 | sed -n 's/.*dhcp-option DNS \([0-9.]*\).*/\1/p')
    fi
    
    # Validate IP format
    if echo "$DNS" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "$DNS"
    fi
}

# Check if upstream VPN is running
is_upstream_running() {
    pgrep -f "openvpn.*$1" >/dev/null
}

# Get upstream tunnel interface (tun1, tun2, etc)
get_upstream_interface() {
    # Find first tun interface that is NOT tun0 (RW server)
    ip link show | grep -oE 'tun[1-9][0-9]*' | head -1
}

# Add route for DNS through upstream VPN
add_dns_route() {
    local DNS="$1"
    local UPSTREAM_IF="$2"
    
    if [ -z "$UPSTREAM_IF" ]; then
        log "⚠ No upstream interface, cannot add DNS route"
        return 1
    fi
    
    # Get gateway from upstream interface
    local UPSTREAM_GW=$(ip route show dev "$UPSTREAM_IF" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    
    if [ -z "$UPSTREAM_GW" ]; then
        log "⚠ Cannot determine upstream gateway"
        return 1
    fi
    
    # Delete old route if exists
    ip route del "$DNS" 2>/dev/null || true
    ip route del "$DNS/32" 2>/dev/null || true
    
    # Add new route
    if ip route add "$DNS/32" via "$UPSTREAM_GW" dev "$UPSTREAM_IF" 2>/dev/null; then
        log "✓ DNS route: $DNS/32 via $UPSTREAM_GW dev $UPSTREAM_IF"
        return 0
    else
        # Check if route already exists
        if ip route get "$DNS" 2>/dev/null | grep -q "$UPSTREAM_IF"; then
            log "✓ DNS route already exists via $UPSTREAM_IF"
            return 0
        else
            log "✗ Failed to add DNS route"
            return 1
        fi
    fi
}

# Configure dnsmasq with upstream DNS
configure_dnsmasq() {
    local DNS="$1"
    local UPSTREAM_IF="$2"
    
    log "Configuring dnsmasq..."
    
    # Remove old server entries
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done
    
    # Add new DNS server pinned to interface
    if [ -n "$UPSTREAM_IF" ]; then
        # Pin to interface (dnsmasq handles routing automatically!)
        uci add_list dhcp.@dnsmasq[0].server="$DNS@$UPSTREAM_IF"
        log "  → DNS: $DNS@$UPSTREAM_IF"
    else
        # No interface, just add DNS
        uci add_list dhcp.@dnsmasq[0].server="$DNS"
        log "  → DNS: $DNS"
    fi
    
    # Ensure noresolv is correct
    uci set dhcp.@dnsmasq[0].noresolv='0'
    
    # Commit changes
    uci commit dhcp
    
    # Reload dnsmasq
    if /etc/init.d/dnsmasq reload 2>/dev/null; then
        log "✓ dnsmasq reloaded"
        
        # Verify dnsmasq is running
        sleep 1
        if ! pgrep dnsmasq >/dev/null; then
            log "⚠ dnsmasq not running after reload, restarting..."
            /etc/init.d/dnsmasq restart 2>/dev/null
        fi
        
        return 0
    else
        log "✗ Failed to reload dnsmasq"
        return 1
    fi
}

# ==================== MAIN ====================

: > "$LOG"

log "=========================================="
log "VPN DNS Monitor v3.3 - SIMPLIFIED"
log "=========================================="
log "Upstream VPN: $UPSTREAM_NAME"
log "Check interval: ${CHECK_INTERVAL}s"
log ""
log "NOTE: RW push options are hardcoded in UCI"
log "      Clients always get DNS: 10.99.0.1"
log "      This monitor only updates dnsmasq forwarding"
log ""

# Check dnsmasq is running
if ! pgrep dnsmasq >/dev/null; then
    log "✗ dnsmasq is not running!"
    log "  Starting dnsmasq..."
    /etc/init.d/dnsmasq start 2>/dev/null
    sleep 2
fi

if pgrep dnsmasq >/dev/null; then
    log "✓ dnsmasq running"
else
    log "✗ ERROR: Cannot start dnsmasq"
    exit 1
fi

log ""
log "Monitoring upstream VPN: $UPSTREAM_NAME"
log ""

# Main monitoring loop
while true; do
    # 1. Check if upstream is running
    if ! is_upstream_running "$UPSTREAM_NAME"; then
        # Upstream not running - wait
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # 2. Get DNS from upstream
    CURRENT_DNS=$(get_upstream_dns "$UPSTREAM_NAME")
    
    if [ -z "$CURRENT_DNS" ]; then
        # No DNS yet - wait
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # 3. Check if DNS changed
    if [ "$CURRENT_DNS" != "$LAST_DNS" ]; then
        log ""
        log "=== DNS Change Detected ==="
        log "Old DNS: ${LAST_DNS:-none}"
        log "New DNS: $CURRENT_DNS"
        log ""
        
        # 4. Get upstream interface
        UPSTREAM_IF=$(get_upstream_interface)
        
        if [ -n "$UPSTREAM_IF" ]; then
            log "Upstream interface: $UPSTREAM_IF"
        else
            log "⚠ Cannot detect upstream interface"
        fi
        
        # 5. Add DNS route through upstream
        add_dns_route "$CURRENT_DNS" "$UPSTREAM_IF"
        
        # 6. Configure dnsmasq to forward to upstream DNS
        configure_dnsmasq "$CURRENT_DNS" "$UPSTREAM_IF"
        
        # 7. Save current DNS
        LAST_DNS="$CURRENT_DNS"
        
        log ""
        log "=== Configuration Complete ==="
        log "Router DNS: 10.99.0.1 (hardcoded in RW push)"
        log "dnsmasq forwards to: $CURRENT_DNS via $UPSTREAM_IF"
        log "RW clients will use: 10.99.0.1 → $CURRENT_DNS"
        log ""
        log "✓ No RW restart needed!"
        log "✓ Clients stay connected!"
        log ""
    fi
    
    sleep $CHECK_INTERVAL
done
