#!/bin/sh
# VPN DNS Monitor v2.0 - Fixed for tun1 with auto-patching
# Automatically patches OpenVPN configs to enable logging
# Monitors /tmp/openvpn-client.log for DNS from PUSH_REPLY

LOG="/tmp/vpn-dns-monitor.log"
CHECK_INTERVAL=5
LAST_DNS_CONFIG=""
OVPN_CONFIG=""
OVPN_LOG="/tmp/openvpn-client.log"
OVPN_DIR="/etc/openvpn"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Auto-detect OpenVPN client config
find_ovpn_config() {
    # Method 1: Find from running process
    local running_config=$(ps -w | grep openvpn | grep -v grep | grep -v 'openvpn(rw)' | \
        grep -oE -- '--config [^ ]+' | awk '{print $2}' | head -1)
    
    if [ -n "$running_config" ] && [ -f "$running_config" ]; then
        echo "$running_config"
        return 0
    fi
    
    # Method 2: Find .ovpn files in /etc/openvpn (exclude rw*)
    local found_config=$(find "$OVPN_DIR" -maxdepth 1 -name "*.ovpn" ! -name "*rw*" -type f | head -1)
    
    if [ -n "$found_config" ]; then
        echo "$found_config"
        return 0
    fi
    
    # Method 3: Check /var/etc/ for generated configs (exclude rw)
    found_config=$(find /var/etc -name "openvpn-*.conf" ! -name "*rw*" -type f | head -1)
    
    if [ -n "$found_config" ]; then
        echo "$found_config"
        return 0
    fi
    
    return 1
}

# Auto-patch OpenVPN config to enable logging
autopatch_ovpn() {
    local config="$1"
    
    if [ ! -f "$config" ]; then
        log "⚠ Config not found: $config"
        return 1
    fi
    
    # Check if already patched
    if grep -q "^log /tmp/openvpn-client.log" "$config"; then
        log "✓ Config already patched"
        return 0
    fi
    
    log "Patching OpenVPN config: $config"
    
    # Backup original
    cp "$config" "${config}.backup-$(date +%s)"
    
    # Add logging directives
    cat >> "$config" << 'EOF'

# Auto-added by vpn-dns-monitor for DNS extraction
verb 3
log /tmp/openvpn-client.log
EOF
    
    log "✓ Config patched! Added verb 3 and log directives"
    
    # Restart OpenVPN to apply changes
    local ovpn_pid=$(pgrep -f "openvpn.*$config" | head -1)
    
    if [ -n "$ovpn_pid" ]; then
        log "Restarting OpenVPN (PID: $ovpn_pid)..."
        
        kill "$ovpn_pid" 2>/dev/null
        sleep 2
        
        # Start with new config
        openvpn --config "$config" --daemon
        sleep 3
        
        local new_pid=$(pgrep -f "openvpn.*$config" | head -1)
        if [ -n "$new_pid" ]; then
            log "✓ OpenVPN restarted (new PID: $new_pid)"
        else
            log "⚠ OpenVPN failed to restart"
        fi
    fi
    
    return 0
}

# Extract DNS from OpenVPN PUSH_REPLY in log
get_dns_from_log() {
    if [ ! -f "$OVPN_LOG" ]; then
        return 1
    fi
    
    # Get most recent PUSH_REPLY
    cat "$OVPN_LOG" | grep "PUSH_REPLY" | tail -1 | \
        grep -oE "dhcp-option DNS [0-9.]+" | awk '{print $3}'
}

# Update dnsmasq configuration with DNS servers
update_dnsmasq() {
    local dns_list="$1"
    
    if [ -z "$dns_list" ]; then
        return 1
    fi
    
    log "=== Updating DNS Configuration ==="
    
    # Clear old DNS entries
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done
    
    # Add new DNS servers via tun1
    local count=0
    echo "$dns_list" | while read dns; do
        if [ -n "$dns" ]; then
            log "  → ${dns}@tun1"
            uci add_list dhcp.@dnsmasq[0].server="${dns}@tun1"
            count=$((count + 1))
        fi
    done
    
    # Ensure dnsmasq uses our servers
    uci set dhcp.@dnsmasq[0].noresolv='0'
    
    # Commit changes
    uci commit dhcp
    
    # Reload dnsmasq
    /etc/init.d/dnsmasq reload
    
    log "✓ DNS updated ($(echo "$dns_list" | wc -l) servers)"
    log ""
    
    return 0
}

# Clear DNS configuration
clear_dns_config() {
    log "=== Clearing DNS Configuration ==="
    
    while uci -q delete dhcp.@dnsmasq[0].server; do :; done
    uci commit dhcp
    /etc/init.d/dnsmasq reload
    
    log "✓ DNS cleared"
    log ""
}

# Main monitoring loop
main() {
    : > "$LOG"
    
    log "=========================================="
    log "VPN DNS Monitor v2.0"
    log "=========================================="
    log "Mode: tun1 monitoring (auto-detect .ovpn)"
    log "OpenVPN log: $OVPN_LOG"
    log "Check interval: ${CHECK_INTERVAL}s"
    log ""
    
    # Auto-detect OpenVPN config
    OVPN_CONFIG=$(find_ovpn_config)
    
    if [ -n "$OVPN_CONFIG" ]; then
        log "✓ Found OpenVPN config: $OVPN_CONFIG"
        autopatch_ovpn "$OVPN_CONFIG"
    else
        log "⚠ No OpenVPN config found"
        log "  Searching in: $OVPN_DIR"
        log "  Will auto-detect when available..."
    fi
    
    log ""
    log "Monitoring started..."
    log ""
    
    while true; do
        # Re-detect config if not found initially
        if [ -z "$OVPN_CONFIG" ]; then
            OVPN_CONFIG=$(find_ovpn_config)
            if [ -n "$OVPN_CONFIG" ]; then
                log "✓ Found OpenVPN config: $OVPN_CONFIG"
                autopatch_ovpn "$OVPN_CONFIG"
            fi
        fi
        
        # Check if tun1 exists (VPN connected)
        if ! ip link show tun1 >/dev/null 2>&1; then
            # tun1 is down
            if [ -n "$LAST_DNS_CONFIG" ]; then
                log "tun1 interface down, clearing DNS..."
                clear_dns_config
                LAST_DNS_CONFIG=""
            fi
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Check if OpenVPN log exists
        if [ ! -f "$OVPN_LOG" ]; then
            # Log file missing - re-detect and patch config
            OVPN_CONFIG=$(find_ovpn_config)
            
            if [ -n "$OVPN_CONFIG" ] && ! grep -q "^log /tmp/openvpn-client.log" "$OVPN_CONFIG"; then
                log "OpenVPN log missing, re-patching config..."
                autopatch_ovpn "$OVPN_CONFIG"
            fi
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Get DNS from OpenVPN log
        DNS_LIST=$(get_dns_from_log)
        
        if [ -z "$DNS_LIST" ]; then
            # No DNS found yet - wait for PUSH_REPLY
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Create DNS config signature
        DNS_CONFIG="$(echo "$DNS_LIST" | tr '\n' ',')"
        
        # Check if DNS configuration changed
        if [ "$DNS_CONFIG" != "$LAST_DNS_CONFIG" ]; then
            if update_dnsmasq "$DNS_LIST"; then
                LAST_DNS_CONFIG="$DNS_CONFIG"
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# Run main loop
main
