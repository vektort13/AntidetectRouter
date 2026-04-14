#!/bin/sh
# VPN Control - Based on dual-vpn-switcher.sh logic
# Manages VPN switching with proper fw4/nftables handling

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

# Parse query
ACTION="$(get_param action)"
MODE="$(get_param mode)"
VPN_TYPE="$(get_param vpn)"

LOG="/tmp/vpn-control.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Check if Passwall is ready (xray running + port listening)
is_passwall_ready() {
    # Check xray process
    if ! pgrep xray >/dev/null 2>&1; then
        return 1
    fi
    
    # Check SOCKS port (usually 1070)
    local socks_port=$(uci get passwall.@global[0].socks_port 2>/dev/null || echo "1070")
    if ! netstat -ln 2>/dev/null | grep -q ":$socks_port"; then
        return 1
    fi
    
    return 0
}

# CRITICAL: Fix dnsmasq DNS leak
fix_dnsmasq_dns_leak() {
    log_msg ""
    log_msg "Fixing dnsmasq DNS leak..."
    
    # Remove all DNS servers from dnsmasq
    local removed=0
    while uci -q delete dhcp.@dnsmasq[0].server; do
        removed=$((removed + 1))
    done
    
    if [ $removed -gt 0 ]; then
        log_msg "  ✓ Removed $removed DNS server(s) from dnsmasq"
    else
        log_msg "  ✓ No DNS servers in dnsmasq (already clean)"
    fi
    
    # Set noresolv=1 (don't read system resolv.conf)
    uci set dhcp.@dnsmasq[0].noresolv='1'
    log_msg "  ✓ Set noresolv=1 (dnsmasq won't read system DNS)"
    
    # Add failsafe DNS so dnsmasq is never without upstream
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    log_msg "  ✓ Added failsafe DNS 1.1.1.1/8.8.8.8"
    
    # Commit
    uci commit dhcp
    log_msg "  ✓ Changes committed"
    
    # Reload dnsmasq
    /etc/init.d/dnsmasq reload 2>/dev/null
    sleep 1
    
    if pgrep dnsmasq >/dev/null; then
        log_msg "  ✓ dnsmasq reloaded"
    else
        log_msg "  ⚠ dnsmasq not running, restarting..."
        /etc/init.d/dnsmasq restart 2>/dev/null
    fi
    
    log_msg ""
}

# CRITICAL: Patch Passwall DNS configuration
patch_passwall_dns() {
    log_msg ""
    log_msg "Checking Passwall DNS configuration..."
    
    # Wait for Passwall to create config
    sleep 2
    
    # Check if chinadns-ng config exists
    if [ ! -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        log_msg "  ⚠ chinadns-ng config not found yet - waiting..."
        sleep 3
    fi
    
    if [ -f /tmp/etc/passwall/acl/default/chinadns_ng.conf ]; then
        # Check if already patched
        if grep -q "^default-tag gfw" /tmp/etc/passwall/acl/default/chinadns_ng.conf; then
            log_msg "  ✓ DNS already configured: default-tag gfw"
            log_msg ""
            return 0
        fi
        
        # Need to patch
        log_msg "  Patching DNS: default-tag chn → gfw"
        
        # Kill chinadns-ng
        killall chinadns-ng 2>/dev/null
        sleep 1
        
        # Patch config: change default-tag from 'chn' to 'gfw'
        sed -i 's/^default-tag chn$/default-tag gfw/' /tmp/etc/passwall/acl/default/chinadns_ng.conf
        
        # Verify patch
        if grep -q "^default-tag gfw" /tmp/etc/passwall/acl/default/chinadns_ng.conf; then
            log_msg "  ✓ Patch applied successfully"
        else
            log_msg "  ✗ Patch failed!"
        fi
        
        # Restart chinadns-ng with patched config
        /tmp/etc/passwall/bin/chinadns-ng -C /tmp/etc/passwall/acl/default/chinadns_ng.conf >/dev/null 2>&1 &
        sleep 2
        
        if pgrep chinadns-ng >/dev/null; then
            log_msg "  ✓ chinadns-ng restarted"
        else
            log_msg "  ✗ chinadns-ng failed to start!"
        fi
    else
        log_msg "  ✗ chinadns-ng config not found!"
    fi
    
    log_msg ""
}

# Switch to Passwall mode
switch_to_passwall() {
    log_msg "=== SWITCHING TO PASSWALL ==="
    
    # 1. Stop OpenVPN if running
    log_msg "[1/8] Stopping OpenVPN..."
    for pid_file in /var/run/openvpn-*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                rm -f "$pid_file"
            fi
        fi
    done
    sleep 1
    log_msg "  ✓ OpenVPN stopped"
    
    # 2. CRITICAL: DISABLE fw4 firewall
    log_msg "[2/8] Disabling fw4 firewall..."
    /etc/init.d/firewall stop 2>/dev/null
    /etc/init.d/firewall disable 2>/dev/null
    
    # Remove firewall symlinks
    rm -f /etc/rc.d/S*firewall* 2>/dev/null
    rm -f /etc/rc.d/K*firewall* 2>/dev/null
    
    # Kill fw4 process
    killall fw4 2>/dev/null
    
    # Delete fw4 nftables
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet fw4 >/dev/null 2>&1; then
            nft delete table inet fw4 2>/dev/null
        fi
    fi
    log_msg "  ✓ fw4 disabled"
    
    # 3. Clean rwfix nftables (OpenVPN stuff)
    log_msg "[3/8] Cleaning rwfix nftables..."
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet rwfix >/dev/null 2>&1; then
            nft delete table inet rwfix 2>/dev/null
            log_msg "  ✓ rwfix removed"
        fi
    fi
    
    # 4. Flush vpnout routing table
    log_msg "[4/8] Flushing vpnout table..."
    if ip route show table vpnout 2>/dev/null | grep -q .; then
        ip route flush table vpnout 2>/dev/null
        log_msg "  ✓ vpnout flushed"
    fi
    
    # 5. Clean IP rules
    log_msg "[5/8] Cleaning IP rules..."
    while ip rule del iif tun0 lookup vpnout 2>/dev/null; do :; done
    log_msg "  ✓ IP rules cleaned"
    
    # 6. Stop vpn-dns-monitor if running
    log_msg "[6/8] Stopping vpn-dns-monitor..."
    if pgrep -f vpn-dns-monitor.sh >/dev/null; then
        killall vpn-dns-monitor.sh 2>/dev/null
        log_msg "  ✓ vpn-dns-monitor stopped"
    fi
    
    # 7. Restart Passwall
    log_msg "[7/8] Restarting Passwall..."
    /etc/init.d/passwall stop 2>/dev/null
    sleep 2
    /etc/init.d/passwall start 2>/dev/null
    sleep 5
    
    # 8. Verify Passwall started
    log_msg "[8/8] Verifying Passwall..."
    local retry=0
    while [ $retry -lt 3 ]; do
        if is_passwall_ready; then
            log_msg "  ✓ Passwall ready!"
            
            # Check nftables
            if nft list table inet passwall >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
                log_msg "  ✓ Passwall nftables created"
            else
                log_msg "  ⚠ SOCKS5-only mode (no nftables)"
            fi
            
            # CRITICAL: Fix DNS leaks and patch configuration
            log_msg ""
            log_msg "Applying DNS fixes..."
            fix_dnsmasq_dns_leak
            patch_passwall_dns
            
            log_msg "=== PASSWALL MODE ACTIVE ==="
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt 3 ]; then
            log_msg "  Retry $retry/3..."
            /etc/init.d/passwall restart 2>/dev/null
            sleep 5
        fi
    done
    
    log_msg "  ✗ Passwall failed to start"
    return 1
}

# Switch to OpenVPN mode
switch_to_openvpn() {
    log_msg "=== SWITCHING TO OPENVPN ==="
    
    # 1. Stop Passwall
    log_msg "[1/7] Stopping Passwall..."
    if pgrep xray >/dev/null 2>&1 || pgrep v2ray >/dev/null 2>&1; then
        /etc/init.d/passwall stop 2>/dev/null
        sleep 2
        log_msg "  ✓ Passwall stopped"
    fi
    
    # 2. Remove Passwall nftables
    log_msg "[2/7] Cleaning Passwall nftables..."
    if command -v nft >/dev/null 2>&1; then
        for table in passwall passwall2 passwall_server; do
            if nft list table inet $table >/dev/null 2>&1; then
                nft delete table inet $table 2>/dev/null
                log_msg "  ✓ Removed: inet $table"
            fi
        done
    fi
    
    # 3. CRITICAL: ENABLE fw4 firewall
    log_msg "[3/7] Enabling fw4 firewall..."
    /etc/init.d/firewall enable 2>/dev/null
    /etc/init.d/firewall start 2>/dev/null
    sleep 2
    
    if nft list table inet fw4 >/dev/null 2>&1; then
        log_msg "  ✓ fw4 enabled and started"
    else
        log_msg "  ⚠ fw4 may not have started"
    fi
    
    log_msg "=== OPENVPN MODE READY ==="
    log_msg "  ℹ Start OpenVPN manually via OpenVPN tab"
    return 0
}

# Get current VPN status
get_status() {
    local status="none"
    local details=""
    
    # Check OpenVPN
    for pid_file in /var/run/openvpn-*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                local config_name=$(basename "$pid_file" .pid | sed 's/openvpn-//')
                status="openvpn"
                details="$config_name"
                break
            fi
        fi
    done
    
    # Check Passwall
    if [ "$status" = "none" ] && is_passwall_ready; then
        status="passwall"
        local node=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
        if [ -n "$node" ] && [ "$node" != "nil" ]; then
            local remarks=$(uci get "passwall.$node.remarks" 2>/dev/null || echo "$node")
            details="$remarks"
        fi
    fi
    
    echo "{\"status\":\"ok\",\"mode\":\"$status\",\"details\":\"$details\"}"
}

is_openvpn_running() {
    for pid_file in /var/run/openvpn-*.pid; do
        [ -f "$pid_file" ] || continue
        pid="$(cat "$pid_file" 2>/dev/null)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

legacy_status() {
    case "$1" in
        passwall)
            if is_passwall_ready; then
                echo '{"status":"ok","vpn":"passwall","action":"status","result":"success","data":{"running":true}}'
            else
                echo '{"status":"ok","vpn":"passwall","action":"status","result":"success","data":{"running":false}}'
            fi
            ;;
        openvpn)
            if is_openvpn_running; then
                echo '{"status":"ok","vpn":"openvpn","action":"status","result":"success","data":{"running":true}}'
            else
                echo '{"status":"ok","vpn":"openvpn","action":"status","result":"success","data":{"running":false}}'
            fi
            ;;
        *)
            echo '{"status":"error","result":"failed","message":"Invalid vpn type"}'
            ;;
    esac
}

legacy_control() {
    vpn="$1"
    cmd="$2"

    case "$vpn:$cmd" in
        passwall:start)
            if switch_to_passwall; then
                echo '{"status":"ok","result":"success","message":"Passwall started"}'
            else
                echo '{"status":"ok","result":"failed","message":"Passwall failed to start"}'
            fi
            ;;
        passwall:stop)
            /etc/init.d/passwall stop >/dev/null 2>&1
            sleep 1
            if is_passwall_ready; then
                echo '{"status":"ok","result":"failed","message":"Passwall failed to stop"}'
            else
                echo '{"status":"ok","result":"success","message":"Passwall stopped"}'
            fi
            ;;
        passwall:restart)
            /etc/init.d/passwall restart >/dev/null 2>&1
            sleep 2
            if is_passwall_ready; then
                echo '{"status":"ok","result":"success","message":"Passwall restarted"}'
            else
                echo '{"status":"ok","result":"failed","message":"Passwall failed to restart"}'
            fi
            ;;
        openvpn:start)
            switch_to_openvpn >/dev/null 2>&1
            /etc/init.d/openvpn start >/dev/null 2>&1
            sleep 2
            if is_openvpn_running; then
                echo '{"status":"ok","result":"success","message":"OpenVPN started"}'
            else
                echo '{"status":"ok","result":"failed","message":"OpenVPN failed to start"}'
            fi
            ;;
        openvpn:stop)
            /etc/init.d/openvpn stop >/dev/null 2>&1
            sleep 1
            if is_openvpn_running; then
                echo '{"status":"ok","result":"failed","message":"OpenVPN failed to stop"}'
            else
                echo '{"status":"ok","result":"success","message":"OpenVPN stopped"}'
            fi
            ;;
        openvpn:restart)
            /etc/init.d/openvpn restart >/dev/null 2>&1
            sleep 2
            if is_openvpn_running; then
                echo '{"status":"ok","result":"success","message":"OpenVPN restarted"}'
            else
                echo '{"status":"ok","result":"failed","message":"OpenVPN failed to restart"}'
            fi
            ;;
        *)
            echo '{"status":"error","result":"failed","message":"Invalid legacy action"}'
            ;;
    esac
}

# Main action handler
if [ -n "$VPN_TYPE" ]; then
    if [ "$ACTION" = "status" ]; then
        legacy_status "$VPN_TYPE"
    else
        legacy_control "$VPN_TYPE" "$ACTION"
    fi
    exit 0
fi

case "$ACTION" in
    switch)
        case "$MODE" in
            passwall)
                if switch_to_passwall; then
                    echo '{"status":"ok","message":"Switched to Passwall mode"}'
                else
                    echo '{"status":"error","message":"Failed to switch to Passwall"}'
                fi
                ;;
            openvpn)
                if switch_to_openvpn; then
                    echo '{"status":"ok","message":"Switched to OpenVPN mode (start OpenVPN manually)"}'
                else
                    echo '{"status":"error","message":"Failed to switch to OpenVPN"}'
                fi
                ;;
            *)
                echo '{"status":"error","message":"Invalid mode"}'
                ;;
        esac
        ;;
    status)
        get_status
        ;;
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
