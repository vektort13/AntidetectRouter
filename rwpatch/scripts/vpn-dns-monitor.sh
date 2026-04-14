#!/bin/sh
# VPN DNS Monitor v0.7 - Universal OpenVPN DNS Monitor
# Automatically extracts DNS from PUSH_REPLY and configures dnsmasq
# Works with ANY OpenVPN client (vpn1, vpn2, auth, det, mol, etc)
#
# Usage: /root/vpn-dns-monitor.sh [upstream_name]
# Example: /root/vpn-dns-monitor.sh vpn1
# Auto-detect: /root/vpn-dns-monitor.sh auto

LOG="/tmp/vpn-dns-monitor.log"
CHECK_INTERVAL=5
LAST_DNS_CONFIG=""
UPSTREAM_NAME="${1:-auto}"
LAST_OPENVPN_PID=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Auto-detect running OpenVPN upstream (non-RW)
auto_detect_vpn() {
    # Find first OpenVPN process that is NOT 'rw'
    ps | grep openvpn | grep -v grep | grep -v 'openvpn(rw)' | \
        grep -oE 'openvpn\([a-z0-9]+\)' | sed 's/openvpn(\(.*\))/\1/' | head -1
}

# Get DNS servers from PUSH_REPLY in logread
get_dns_from_push_reply() {
    local vpn_name="$1"
    
    # Search for most recent PUSH_REPLY in logread
    local push_reply=$(logread | grep "openvpn($vpn_name)" | grep "PUSH_REPLY" | tail -1)
    
    if [ -n "$push_reply" ]; then
        # Extract all DNS servers: dhcp-option DNS x.x.x.x
        echo "$push_reply" | grep -oE "dhcp-option DNS [0-9.]+" | awk '{print $3}'
    fi
}

# Get tunnel interface for this VPN
get_tun_interface() {
    # Find first non-tun0 interface (tun0 is RW server)
    ip link show | grep -oE 'tun[1-9][0-9]*' | head -1
}

# Check if OpenVPN is running
is_openvpn_running() {
    local vpn_name="$1"
    pgrep -f "openvpn.*$vpn_name" >/dev/null
}

# Get OpenVPN process PID
get_openvpn_pid() {
    local vpn_name="$1"
    pgrep -f "openvpn.*$vpn_name" | head -1
}

# Update dnsmasq configuration
update_dnsmasq() {
    local dns_list="$1"
    local tun_if="$2"
    local vpn_name="$3"
    
    if [ -z "$dns_list" ]; then
        log "⚠ No DNS servers to configure"
        return 1
    fi
    
    if [ -z "$tun_if" ]; then
        log "⚠ No tunnel interface available"
        return 1
    fi
    
    log ""
    log "=== Updating DNS Configuration ==="
    log "VPN: $vpn_name"
    log "Interface: $tun_if"
    log "DNS servers:"
    
    # Clear old DNS entries
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done
    
    # Add new DNS servers
    echo "$dns_list" | while read dns; do
        if [ -n "$dns" ]; then
            log "  → ${dns}@${tun_if}"
            uci add_list dhcp.@dnsmasq[0].server="${dns}@${tun_if}"
            
            # Add route to DNS through VPN
            if ip route add ${dns}/32 dev ${tun_if} 2>/dev/null; then
                log "    ✓ Route added: ${dns}/32 → ${tun_if}"
            else
                # Route might already exist
                if ip route get ${dns} 2>/dev/null | grep -q "${tun_if}"; then
                    log "    ✓ Route exists: ${dns}/32 → ${tun_if}"
                fi
            fi
        fi
    done
    
    # Leak-safe mode: only use VPN-provided DNS while tunnel is active
    uci set dhcp.@dnsmasq[0].noresolv='1'
    
    # Commit changes
    uci commit dhcp
    
    # Reload dnsmasq
    if /etc/init.d/dnsmasq reload 2>&1 | grep -q "OK\|started"; then
        log "✓ dnsmasq reloaded successfully"
    else
        log "✓ dnsmasq reload triggered"
    fi
    
    # Wait for reload
    sleep 1
    
    # Verify dnsmasq is running
    if ! pgrep dnsmasq >/dev/null; then
        log "⚠ dnsmasq not running after reload, restarting..."
        /etc/init.d/dnsmasq restart
    fi
    
    log "✓ DNS configuration updated"
    log ""
    
    return 0
}

# Clear DNS configuration
clear_dns_config() {
    log ""
    log "=== Clearing DNS Configuration ==="
    
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done
    # Restore system resolver behavior when VPN DNS is removed
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    
    log "✓ DNS cleared"
    log ""
}

# Main monitoring loop
main() {
    : > "$LOG"
    
    log "=========================================="
    log "VPN DNS Monitor v0.7"
    log "=========================================="
    
    if [ "$UPSTREAM_NAME" = "auto" ]; then
        log "Mode: AUTO-DETECT"
    else
        log "Mode: MANUAL ($UPSTREAM_NAME)"
    fi
    
    log "Check interval: ${CHECK_INTERVAL}s"
    log ""
    
    # Check dnsmasq is running
    if ! pgrep dnsmasq >/dev/null; then
        log "⚠ dnsmasq not running, starting..."
        /etc/init.d/dnsmasq start
        sleep 2
    fi
    
    if pgrep dnsmasq >/dev/null; then
        log "✓ dnsmasq is running"
    else
        log "✗ ERROR: Cannot start dnsmasq"
        exit 1
    fi
    
    log ""
    log "Monitoring started..."
    log ""
    
    while true; do
        # Auto-detect VPN if in auto mode
        if [ "$UPSTREAM_NAME" = "auto" ]; then
            CURRENT_VPN=$(auto_detect_vpn)
            
            if [ -z "$CURRENT_VPN" ]; then
                # No VPN running - clear DNS and wait
                if [ -n "$LAST_DNS_CONFIG" ]; then
                    log "No upstream VPN detected, clearing DNS..."
                    clear_dns_config
                    LAST_DNS_CONFIG=""
                    LAST_OPENVPN_PID=""
                fi
                sleep $CHECK_INTERVAL
                continue
            fi
        else
            CURRENT_VPN="$UPSTREAM_NAME"
        fi
        
        # Check if VPN is running
        if ! is_openvpn_running "$CURRENT_VPN"; then
            # VPN not running
            if [ -n "$LAST_DNS_CONFIG" ]; then
                log "$CURRENT_VPN stopped, clearing DNS..."
                clear_dns_config
                LAST_DNS_CONFIG=""
                LAST_OPENVPN_PID=""
            fi
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Get current OpenVPN PID
        CURRENT_PID=$(get_openvpn_pid "$CURRENT_VPN")
        
        # Check if OpenVPN restarted (new PID)
        if [ "$CURRENT_PID" != "$LAST_OPENVPN_PID" ]; then
            log "Detected $CURRENT_VPN (PID: $CURRENT_PID)"
            LAST_OPENVPN_PID="$CURRENT_PID"
            
            # Wait a bit for PUSH_REPLY to arrive
            log "Waiting for PUSH_REPLY..."
            sleep 3
        fi
        
        # Get DNS from PUSH_REPLY
        DNS_LIST=$(get_dns_from_push_reply "$CURRENT_VPN")
        
        if [ -z "$DNS_LIST" ]; then
            # No DNS in logs yet - might be too early
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Create unique DNS config string for comparison
        DNS_CONFIG="$CURRENT_VPN:$(echo "$DNS_LIST" | tr '\n' ',')"
        
        # Check if DNS configuration changed
        if [ "$DNS_CONFIG" != "$LAST_DNS_CONFIG" ]; then
            # Get tunnel interface
            TUN_IF=$(get_tun_interface)
            
            if [ -n "$TUN_IF" ]; then
                # Update DNS
                if update_dnsmasq "$DNS_LIST" "$TUN_IF" "$CURRENT_VPN"; then
                    LAST_DNS_CONFIG="$DNS_CONFIG"
                fi
            else
                log "⚠ No tunnel interface found for $CURRENT_VPN"
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# Run main loop
main
