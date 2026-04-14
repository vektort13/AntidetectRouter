#!/bin/sh
# Passwall Diagnostic Script
# Checks why there's no internet through Passwall

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/cgi-common.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/cgi-common.sh"
    require_auth
fi

if [ -n "$GATEWAY_INTERFACE" ]; then
    echo "Content-type: text/plain"
    echo "Access-Control-Allow-Origin: *"
    echo ""
fi

echo "=================================================="
echo "PASSWALL DIAGNOSTIC REPORT"
echo "=================================================="
echo ""

# 1. PASSWALL STATUS
echo "=== 1. PASSWALL STATUS ==="
ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null)
echo "Enabled: $ENABLED"

if [ "$ENABLED" = "1" ]; then
    echo "✓ Passwall is ENABLED"
else
    echo "✗ Passwall is DISABLED"
fi

# Check processes
echo ""
echo "Processes:"
if pgrep xray >/dev/null; then
    echo "✓ xray running (PID: $(pgrep xray))"
else
    echo "✗ xray NOT running"
fi

if pgrep v2ray >/dev/null; then
    echo "✓ v2ray running (PID: $(pgrep v2ray))"
else
    echo "✗ v2ray NOT running"
fi

echo ""
echo "=== 2. SELECTED NODES ==="
TCP_NODE=$(uci get passwall.@global[0].tcp_node 2>/dev/null)
UDP_NODE=$(uci get passwall.@global[0].udp_node 2>/dev/null)
SOCKS_NODE=$(uci get passwall.@global[0].socks_node 2>/dev/null)

echo "TCP Node: $TCP_NODE"
echo "UDP Node: $UDP_NODE"
echo "SOCKS Node: $SOCKS_NODE"

if [ "$TCP_NODE" = "nil" ] || [ -z "$TCP_NODE" ]; then
    echo "⚠️  WARNING: No TCP node selected!"
fi

# Node details
if [ -n "$TCP_NODE" ] && [ "$TCP_NODE" != "nil" ]; then
    echo ""
    echo "TCP Node Details:"
    NODE_TYPE=$(uci get passwall.$TCP_NODE.type 2>/dev/null)
    NODE_ADDRESS=$(uci get passwall.$TCP_NODE.address 2>/dev/null)
    NODE_PORT=$(uci get passwall.$TCP_NODE.port 2>/dev/null)
    echo "  Type: $NODE_TYPE"
    echo "  Address: $NODE_ADDRESS"
    echo "  Port: $NODE_PORT"
fi

echo ""
echo "=== 3. GFW / ROUTING MODE ==="
TCP_PROXY_MODE=$(uci get passwall.@global[0].tcp_proxy_mode 2>/dev/null)
UDP_PROXY_MODE=$(uci get passwall.@global[0].udp_proxy_mode 2>/dev/null)

echo "TCP Proxy Mode: $TCP_PROXY_MODE"
echo "UDP Proxy Mode: $UDP_PROXY_MODE"

if [ "$TCP_PROXY_MODE" = "gfwlist" ]; then
    echo "⚠️  GFW LIST MODE - Only Chinese sites blocked go through proxy"
    echo "   Most sites will go DIRECT (no proxy)!"
fi

if [ "$TCP_PROXY_MODE" = "global" ]; then
    echo "✓ GLOBAL MODE - All traffic through proxy"
fi

if [ "$TCP_PROXY_MODE" = "disable" ]; then
    echo "✗ TCP PROXY DISABLED!"
fi

echo ""
echo "=== 4. DNS SETTINGS ==="
DNS_MODE=$(uci get passwall.@global[0].dns_mode 2>/dev/null)
REMOTE_DNS=$(uci get passwall.@global[0].remote_dns 2>/dev/null)
DIRECT_DNS=$(uci get passwall.@global[0].direct_dns 2>/dev/null)

echo "DNS Mode: $DNS_MODE"
echo "Remote DNS: $REMOTE_DNS"
echo "Direct DNS: $DIRECT_DNS"

# Check dnsmasq
echo ""
echo "Dnsmasq servers:"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | head -5

echo ""
echo "=== 5. FIREWALL / ROUTING ==="
# Check if passwall rules exist
if iptables -t nat -L PREROUTING 2>/dev/null | grep -q passwall; then
    echo "✓ Passwall firewall rules exist"
else
    echo "✗ Passwall firewall rules NOT found"
fi

if iptables -t mangle -L PREROUTING 2>/dev/null | grep -q passwall; then
    echo "✓ Passwall mangle rules exist"
else
    echo "✗ Passwall mangle rules NOT found"
fi

# Check routing
echo ""
echo "Policy routing tables:"
ip rule show | grep passwall

echo ""
echo "=== 6. CONNECTIVITY TESTS ==="
echo "Testing from router itself..."

# Test direct connection (should fail if firewall blocks)
echo -n "Direct to 8.8.8.8: "
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
fi

# Test DNS
echo -n "DNS resolution (google.com): "
if nslookup google.com >/dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
fi

# Test through proxy (if SOCKS enabled)
SOCKS_PORT=$(uci get passwall.@global[0].socks_port 2>/dev/null)
if [ -n "$SOCKS_PORT" ]; then
    echo -n "SOCKS proxy (127.0.0.1:$SOCKS_PORT): "
    if netstat -ln | grep -q ":$SOCKS_PORT"; then
        echo "✓ Listening"
    else
        echo "✗ NOT listening"
    fi
fi

echo ""
echo "=== 7. LOGS / ERRORS ==="
echo "Recent Passwall logs:"
logread | grep passwall | tail -10

echo ""
echo "Recent xray/v2ray logs:"
logread | grep -E "xray|v2ray" | tail -10

echo ""
echo "=== 8. QUICK FIXES ==="
echo ""
echo "If NO INTERNET through Passwall:"
echo ""
echo "FIX 1: Change to GLOBAL mode (all traffic through proxy)"
echo "  uci set passwall.@global[0].tcp_proxy_mode='global'"
echo "  uci commit passwall"
echo "  /etc/init.d/passwall restart"
echo ""
echo "FIX 2: Check node is selected"
echo "  Current TCP node: $TCP_NODE"
echo "  If 'nil' - select a node in UI!"
echo ""
echo "FIX 3: Restart Passwall"
echo "  /etc/init.d/passwall restart"
echo ""
echo "FIX 4: Check firewall"
echo "  /etc/init.d/firewall restart"
echo ""
echo "=================================================="
echo "DIAGNOSTIC COMPLETE"
echo "=================================================="
