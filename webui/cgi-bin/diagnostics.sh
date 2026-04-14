#!/bin/sh
# VEKTORT13 Diagnostic Tool
# Проверяет VPN, DNS, routing, firewall

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

echo "=============================================="
echo "VEKTORT13 DIAGNOSTIC TOOL"
echo "=============================================="
echo ""

# 1. OpenVPN Status
echo "=== OpenVPN Configs ==="
uci show openvpn | grep "=openvpn$" | while read line; do
    CONFIG=$(echo "$line" | cut -d'.' -f2 | cut -d'=' -f1)
    ENABLED=$(uci get openvpn.${CONFIG}.enabled 2>/dev/null || echo "0")
    
    echo -n "  $CONFIG: "
    if ps | grep -v grep | grep "openvpn" | grep -q "${CONFIG}"; then
        echo "✓ RUNNING (enabled=$ENABLED)"
    else
        echo "✗ STOPPED (enabled=$ENABLED)"
    fi
done
echo ""

# 2. Passwall Status
echo "=== Passwall ==="
PASSWALL_ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null || echo "0")
echo "  Enabled: $PASSWALL_ENABLED"
if ps | grep -v grep | grep -q "lua.*passwall"; then
    echo "  Status: ✓ RUNNING"
else
    echo "  Status: ✗ STOPPED"
fi
echo ""

# 3. Network Interfaces
echo "=== Network Interfaces ==="
ip link show | grep -E "^[0-9]+: (tun|tap)" | awk '{print "  " $2}' | sed 's/:$//'
echo ""

# 4. DNS Configuration
echo "=== DNS Configuration ==="
echo "  dnsmasq noresolv:"
uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo "  (not set)"

echo "  dnsmasq servers:"
uci show dhcp | grep "\.server=" | cut -d"'" -f2 | while read srv; do
    echo "    - $srv"
done
echo ""

# 5. Routing
echo "=== Routing ==="
echo "  Default gateway:"
ip route show default | head -1
echo ""

# 6. Firewall
echo "=== Firewall ==="
if /etc/init.d/firewall enabled >/dev/null 2>&1; then
    echo "  fw4: ✓ ENABLED"
else
    echo "  fw4: ✗ DISABLED"
fi

if ps | grep -v grep | grep -q "fw4"; then
    echo "  Status: ✓ RUNNING"
else
    echo "  Status: ✗ STOPPED"
fi
echo ""

# 7. VPN Switcher
echo "=== VPN Switcher ==="
if ps | grep -v grep | grep -q "dual-vpn-switcher"; then
    echo "  Status: ✓ RUNNING"
    if [ -f /tmp/dual-vpn-switcher.log ]; then
        echo "  Last log:"
        tail -3 /tmp/dual-vpn-switcher.log | sed 's/^/    /'
    fi
else
    echo "  Status: ✗ NOT RUNNING"
fi
echo ""

# 8. Connection Test
echo "=== Connection Test ==="
echo -n "  Testing DNS... "
if nslookup google.com >/dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
fi

echo -n "  Testing connectivity... "
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ OK"
else
    echo "✗ FAILED"
fi

echo -n "  Testing HTTPS... "
if wget -q --spider --timeout=3 https://google.com 2>/dev/null; then
    echo "✓ OK"
else
    echo "✗ FAILED"
fi
echo ""

# 9. Public IP
echo "=== Public IP ==="
echo -n "  Fetching... "
PUBLIC_IP=$(wget -qO- --timeout=5 https://ipinfo.io/ip 2>/dev/null || echo "timeout")
if [ "$PUBLIC_IP" = "timeout" ]; then
    echo "✗ TIMEOUT"
else
    echo "✓ $PUBLIC_IP"
fi
echo ""

echo "=============================================="
echo "Diagnostic complete!"
echo ""
echo "Logs:"
echo "  VPN Switcher: tail -f /tmp/dual-vpn-switcher.log"
echo "  OpenVPN:      logread | grep openvpn"
echo "  DNS:          logread | grep dnsmasq"
echo "=============================================="
