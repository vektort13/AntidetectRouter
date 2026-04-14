#!/bin/sh

echo "=== VEKTORT13 v13.1 INSTALLATION ==="
echo ""

# Show current directory
echo "Current directory:"
pwd
ls -la *.js *.css *.html 2>/dev/null | head -5

echo ""
echo "Creating directories..."
mkdir -p /www/vektort13-admin
mkdir -p /www/cgi-bin/vektort13

echo ""
echo "Checking directories..."
ls -ld /www/vektort13-admin
ls -ld /www/cgi-bin/vektort13

echo ""
echo "Copying frontend files..."
cp -fv app.js /www/vektort13-admin/
cp -fv network.js /www/vektort13-admin/
cp -fv advanced.js /www/vektort13-admin/
cp -fv node-form-dynamic.js /www/vektort13-admin/
cp -fv style.css /www/vektort13-admin/
cp -fv index.html /www/vektort13-admin/

echo ""
echo "Copying backend files..."
rm -f /www/cgi-bin/vektort13/*.sh 2>/dev/null
CGI_FILES="cgi-common.sh status.sh logs.sh connection-history.sh connection-info.sh vpn-control.sh openvpn-control.sh openvpn-upload.sh openvpn-get-content.sh openvpn-save-content.sh passwall-settings.sh passwall-nodes.sh passwall-node-config.sh passwall-logs.sh network-interfaces.sh network-dhcp.sh network-firewall.sh network-diagnostics.sh exec.sh software-manager.sh startup-manager.sh system-control.sh snapshot.sh admin-control.sh"
for f in $CGI_FILES; do
    if [ -f "$f" ]; then
        cp -fv "$f" /www/cgi-bin/vektort13/
    else
        echo "✗ Missing CGI file: $f"
    fi
done

echo ""
echo "Installing mega-snapshot.sh..."
cp -fv mega-snapshot.sh /root/mega-snapshot.sh
chmod +x /root/mega-snapshot.sh
ls -lh /root/mega-snapshot.sh

echo ""
echo "Installing utility scripts..."
cp -fv show-vpn-status.sh /root/show-vpn-status.sh
cp -fv vpn-dns-monitor.sh /root/vpn-dns-monitor.sh
cp -fv dual-vpn-switcher.sh /root/dual-vpn-switcher.sh
cp -fv dual-vpn-autodetect.sh /root/dual-vpn-autodetect.sh
cp -fv start-all.sh /root/start-all.sh
cp -fv upstream-monitor.sh /root/upstream-monitor.sh
cp -fv universal-client-monitor.sh /root/universal-client-monitor.sh
chmod +x /root/*.sh
echo "✓ show-vpn-status.sh → /root/"
echo "✓ vpn-dns-monitor.sh → /root/"
echo "✓ dual-vpn-switcher.sh → /root/"
echo "✓ dual-vpn-autodetect.sh → /root/"
echo "✓ start-all.sh → /root/"
echo "✓ upstream-monitor.sh → /root/"
echo "✓ universal-client-monitor.sh → /root/"

echo ""
echo "Setting permissions..."
chmod +x /www/cgi-bin/vektort13/*.sh

echo ""
echo "Installing OpenVPN DNS autopatch..."
HOTPLUG_FILE="/usr/libexec/openvpn-hotplug"
BACKUP_FILE="/usr/libexec/openvpn-hotplug.backup"

# Backup original hotplug if exists and not backed up yet
if [ -f "$HOTPLUG_FILE" ] && [ ! -f "$BACKUP_FILE" ]; then
    cp "$HOTPLUG_FILE" "$BACKUP_FILE"
    chmod +x "$BACKUP_FILE"
    echo "✓ Original hotplug backed up: $BACKUP_FILE"
fi

# Install our patched hotplug
cp -fv openvpn-hotplug "$HOTPLUG_FILE"
chmod +x "$HOTPLUG_FILE"
echo "✓ OpenVPN DNS autopatch installed"
echo "✓ DNS will be auto-configured from VPN server push"

echo ""
echo "Cleaning up old history logs..."
rm -f /tmp/vpn-connection-history.log
rm -f /tmp/vpn-last-state
echo "✓ Old logs cleared"

echo ""
echo "Cleaning up old VEKTORT13 modifications..."
# Remove all old VEKTORT13 entries from rc.local
if [ -f /etc/rc.local ]; then
    sed -i '/# VEKTORT13:/d' /etc/rc.local
    sed -i '/uci set passwall.@global\[0\]/d' /etc/rc.local
    sed -i '/uci commit passwall/d' /etc/rc.local
    sed -i '/\/etc\/init\.d\/passwall/d' /etc/rc.local
    echo "✓ Removed old Passwall modifications from rc.local"
fi
echo "✓ Passwall will use standard OpenWrt behavior"

echo ""
echo "Configuring Passwall compatibility..."
# CRITICAL: Disable fw4 firewall (conflicts with Passwall nftables)
PASSWALL_ENABLED="0"
if [ -f /etc/init.d/passwall ]; then
    PASSWALL_ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null || echo "0")
fi

if [ -f /etc/init.d/firewall ] && [ -f /etc/init.d/passwall ] && [ "$PASSWALL_ENABLED" = "1" ]; then
    echo "⚠️  Disabling fw4 firewall (conflicts with Passwall)..."
    /etc/init.d/firewall stop 2>/dev/null
    /etc/init.d/firewall disable 2>/dev/null
    
    # Remove firewall symlinks
    rm -f /etc/rc.d/S*firewall* 2>/dev/null
    rm -f /etc/rc.d/K*firewall* 2>/dev/null
    
    # Kill fw4 process
    killall fw4 2>/dev/null
    
    # Delete fw4 nftables if exists
    if command -v nft >/dev/null 2>&1; then
        if nft list table inet fw4 >/dev/null 2>&1; then
            nft delete table inet fw4 2>/dev/null
        fi
    fi
    
    echo "✓ fw4 disabled (Passwall will manage firewall)"
else
    echo "⚠️  Skipping fw4 disable (Passwall not installed or not enabled)"
fi

# Restart Passwall to create its nftables
if [ -f /etc/init.d/passwall ] && [ "$PASSWALL_ENABLED" = "1" ]; then
    echo "Restarting Passwall to create firewall rules..."
    /etc/init.d/passwall restart 2>/dev/null
    sleep 3
    echo "✓ Passwall restarted"
else
    echo "⚠️  Passwall not enabled, skipping restart"
fi

if [ -x ./install-redirect.sh ]; then
    echo ""
    echo "Installing web redirect helper..."
    ./install-redirect.sh >/dev/null 2>&1 || echo "⚠ install-redirect.sh failed"
fi

echo ""
echo "=== VERIFICATION ==="
echo "Frontend files:"
ls -lh /www/vektort13-admin/
echo ""
echo "Backend exec.sh:"
ls -lh /www/cgi-bin/vektort13/exec.sh

echo ""
echo "✓ INSTALLATION COMPLETE"
echo "Refresh browser: Ctrl+Shift+R"
