#!/bin/sh
# Passwall DNS Auto-Fix with dnsmasq Sync
# Add this to dual-vpn-switcher.sh

# Function to sync DNS from Passwall to dnsmasq
sync_dns_from_passwall() {
    # Get Remote DNS from Passwall config
    REMOTE_DNS=$(uci get passwall.@global[0].remote_dns 2>/dev/null)
    
    # Default to CloudFlare if not set
    if [ -z "$REMOTE_DNS" ]; then
        REMOTE_DNS="1.1.1.1"
        uci set passwall.@global[0].remote_dns='1.1.1.1'
        uci commit passwall
    fi
    
    echo "[DNS SYNC] Passwall Remote DNS: $REMOTE_DNS"
    
    # Update dnsmasq to use same DNS
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server="$REMOTE_DNS"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    
    echo "[DNS SYNC] dnsmasq synced: $REMOTE_DNS"
}

# Function to fix DNS when switching from OpenVPN to Passwall
fix_passwall_dns_after_openvpn() {
    echo "[DNS FIX] Switching from OpenVPN to Passwall..."
    
    # Sync DNS from Passwall config to dnsmasq
    sync_dns_from_passwall
    
    # Kill old chinadns-ng
    killall chinadns-ng 2>/dev/null
    sleep 1
    
    # Fix chinadns-ng config (gfw tag)
    if [ -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        sed -i 's/^default-tag chn$/default-tag gfw/' /tmp/etc/passwall/acl/default/chinadns_ng.conf
        echo "[DNS FIX] ChinaDNS-NG config patched (default-tag gfw)"
    fi
    
    # Restart Passwall to regenerate DNS config
    /etc/init.d/passwall restart
    sleep 5
    
    echo "[DNS FIX] Passwall restarted with clean DNS config"
    echo "[DNS FIX] DNS: Passwall → dnsmasq sync complete"
}

# ============================================
# WHERE TO CALL THESE FUNCTIONS:
# ============================================
# 
# 1. When switching from OpenVPN to Passwall:
#    fix_passwall_dns_after_openvpn
#
# 2. When Passwall is already active (periodic check):
#    sync_dns_from_passwall
#
# Example integration:
#
# if [ "$NEW_MODE" = "Passwall" ] && [ "$OLD_MODE" = "OpenVPN" ]; then
#     fix_passwall_dns_after_openvpn
# elif [ "$NEW_MODE" = "Passwall" ]; then
#     sync_dns_from_passwall
# fi

