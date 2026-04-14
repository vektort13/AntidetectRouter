#!/bin/sh
# Passwall Settings Management with DNS Sync and Stop

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="get"

enabled="$(get_param enabled)"
socks_enabled="$(get_param socks_enabled)"
tcp_node="$(get_param tcp_node)"
udp_node="$(get_param udp_node)"
socks_node="$(get_param socks_node)"
dns_mode="$(get_param dns_mode)"
dns_shunt="$(get_param dns_shunt)"
remote_dns="$(get_param remote_dns)"
filter_ipv6="$(get_param filter_ipv6)"
dns_redirect="$(get_param dns_redirect)"
force_https="$(get_param force_https)"

is_valid_uci_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    return 0
}

is_valid_simple_token() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# ==================== DNS Sync Function ====================
sync_dns_to_dnsmasq() {
    local remote_dns="$1"
    
    # Validate DNS
    if [ -z "$remote_dns" ]; then
        remote_dns="1.1.1.1"
    fi
    
    echo "[DNS SYNC] Syncing Passwall DNS ($remote_dns) to dnsmasq..." >> /tmp/passwall-dns-sync.log
    
    # Update dnsmasq
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server="$remote_dns"
    uci add_list dhcp.@dnsmasq[0].server="8.8.8.8"
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    
    echo "[DNS SYNC] dnsmasq updated successfully" >> /tmp/passwall-dns-sync.log
}

# ==================== Get Settings ====================
if [ "$ACTION" = "get" ]; then
    ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null || echo "0")
    SOCKS_ENABLED=$(uci get passwall.@global[0].socks_enabled 2>/dev/null || echo "0")
    TCP_NODE=$(uci get passwall.@global[0].tcp_node 2>/dev/null || echo "nil")
    UDP_NODE=$(uci get passwall.@global[0].udp_node 2>/dev/null || echo "nil")
    SOCKS_NODE=$(uci get passwall.@global[0].socks_node 2>/dev/null || echo "nil")
    DNS_MODE=$(uci get passwall.@global[0].dns_mode 2>/dev/null || echo "tcp")
    DNS_SHUNT=$(uci get passwall.@global[0].dns_shunt 2>/dev/null || echo "chinadns-ng")
    REMOTE_DNS=$(uci get passwall.@global[0].remote_dns 2>/dev/null || echo "1.1.1.1")
    FILTER_IPV6=$(uci get passwall.@global[0].filter_proxy_ipv6 2>/dev/null || echo "0")
    DNS_REDIRECT=$(uci get passwall.@global[0].dns_53 2>/dev/null || echo "0")
    FORCE_HTTPS=$(uci get passwall.@global[0].dns_soa 2>/dev/null || echo "0")
    
    cat << EOF
{
  "status": "ok",
  "data": {
    "enabled": "$ENABLED",
    "socks_enabled": "$SOCKS_ENABLED",
    "tcp_node": "$TCP_NODE",
    "udp_node": "$UDP_NODE",
    "socks_node": "$SOCKS_NODE",
    "dns_mode": "$DNS_MODE",
    "dns_shunt": "$DNS_SHUNT",
    "remote_dns": "$REMOTE_DNS",
        "filter_proxy_ipv6": "$FILTER_IPV6",
    "filter_ipv6": "$FILTER_IPV6",
    "dns_redirect": "$DNS_REDIRECT",
    "force_https": "$FORCE_HTTPS"
  }
}
EOF
    exit 0
fi

# ==================== Set Settings ====================
if [ "$ACTION" = "set" ]; then
    # Validate boolean-like fields
    case "$enabled" in ''|0|1) ;; *) enabled="" ;; esac
    case "$socks_enabled" in ''|0|1) ;; *) socks_enabled="" ;; esac
    case "$filter_ipv6" in ''|0|1) ;; *) filter_ipv6="" ;; esac
    case "$dns_redirect" in ''|0|1) ;; *) dns_redirect="" ;; esac
    case "$force_https" in ''|0|1) ;; *) force_https="" ;; esac

    for node_ref in tcp_node udp_node socks_node; do
        eval "node_value=\${$node_ref}"
        case "$node_value" in
            ''|nil) ;;
            *)
                if ! is_valid_uci_name "$node_value"; then
                    echo '{"status":"error","message":"Invalid node reference"}'
                    exit 0
                fi
                ;;
        esac
    done

    if [ -n "$dns_mode" ] && ! is_valid_simple_token "$dns_mode"; then
        echo '{"status":"error","message":"Invalid dns_mode value"}'
        exit 0
    fi

    if [ -n "$dns_shunt" ] && ! is_valid_simple_token "$dns_shunt"; then
        echo '{"status":"error","message":"Invalid dns_shunt value"}'
        exit 0
    fi
    
    # Validate remote_dns if provided (IP or hostname)
    if [ -n "$remote_dns" ]; then
        case "$remote_dns" in
            *[!A-Za-z0-9._:-]*)
                echo '{"status":"error","message":"Invalid remote_dns value"}'
                exit 0
                ;;
        esac
    fi
    
    # Save to UCI
    [ -n "$enabled" ] && uci set passwall.@global[0].enabled="$enabled"
    [ -n "$socks_enabled" ] && uci set passwall.@global[0].socks_enabled="$socks_enabled"
    [ -n "$tcp_node" ] && uci set passwall.@global[0].tcp_node="$tcp_node"
    [ -n "$udp_node" ] && uci set passwall.@global[0].udp_node="$udp_node"
    [ -n "$socks_node" ] && uci set passwall.@global[0].socks_node="$socks_node"
    [ -n "$dns_mode" ] && uci set passwall.@global[0].dns_mode="$dns_mode"
    [ -n "$dns_shunt" ] && uci set passwall.@global[0].dns_shunt="$dns_shunt"
    [ -n "$remote_dns" ] && uci set passwall.@global[0].remote_dns="$remote_dns"
    [ -n "$filter_ipv6" ] && uci set passwall.@global[0].filter_proxy_ipv6="$filter_ipv6"
    [ -n "$dns_redirect" ] && uci set passwall.@global[0].dns_53="$dns_redirect"
    [ -n "$force_https" ] && uci set passwall.@global[0].dns_soa="$force_https"
    
    uci commit passwall
    
    # Sync DNS to dnsmasq
    if [ -n "$remote_dns" ]; then
        sync_dns_to_dnsmasq "$remote_dns"
    fi
    
    echo '{"status":"ok","message":"Settings saved and DNS synced to dnsmasq"}'
    exit 0
fi

# ==================== Apply Settings (Restart) ====================
if [ "$ACTION" = "apply" ]; then
    # Get current Remote DNS before restart
    REMOTE_DNS=$(uci get passwall.@global[0].remote_dns 2>/dev/null || echo "1.1.1.1")
    
    # Sync DNS before restart
    sync_dns_to_dnsmasq "$REMOTE_DNS"
    
    # Restart Passwall
    /etc/init.d/passwall restart >/dev/null 2>&1 &
    
    echo '{"status":"ok","message":"Passwall restarting with synced DNS..."}'
    exit 0
fi

# ==================== Stop Passwall ====================
if [ "$ACTION" = "stop" ]; then
    # Check if Passwall is running
    if ! pgrep xray >/dev/null 2>&1 && ! pgrep v2ray >/dev/null 2>&1 && ! pgrep sing-box >/dev/null 2>&1; then
        echo '{"status":"ok","message":"Passwall already stopped"}'
        exit 0
    fi
    
    # Disable in UCI first (so UI reflects correct state)
    uci set passwall.@global[0].enabled='0'
    uci set passwall.@global[0].socks_enabled='0'
    uci commit passwall
    
    # Stop Passwall service
    /etc/init.d/passwall stop >/dev/null 2>&1
    
    # Wait a bit for graceful shutdown
    sleep 1
    
    # Force kill if still running
    if pgrep xray >/dev/null 2>&1; then
        killall xray 2>/dev/null
    fi
    if pgrep v2ray >/dev/null 2>&1; then
        killall v2ray 2>/dev/null
    fi
    if pgrep sing-box >/dev/null 2>&1; then
        killall sing-box 2>/dev/null
    fi
    if pgrep chinadns-ng >/dev/null 2>&1; then
        killall chinadns-ng 2>/dev/null
    fi
    
    echo '{"status":"ok","message":"Passwall stopped successfully"}'
    exit 0
fi

# ==================== Default ====================
echo '{"status":"error","message":"Invalid action"}'
