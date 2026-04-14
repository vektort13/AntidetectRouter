#!/bin/sh
# VEKTORT13 FULL UPDATE SCRIPT

set -e

echo "=========================================="
echo "VEKTORT13 FULL UPDATE"
echo "=========================================="
echo ""

WEB_DIR="/www/vektort13-admin"
CGI_DIR="/www/cgi-bin/vektort13"

mkdir -p "$WEB_DIR"
mkdir -p "$CGI_DIR"

echo "[1/4] Backing up current frontend files..."
for f in app.js network.js advanced.js node-form-dynamic.js style.css index.html; do
	if [ -f "$WEB_DIR/$f" ]; then
		cp "$WEB_DIR/$f" "$WEB_DIR/$f.backup" 2>/dev/null || true
	fi
done
echo "  OK"

echo ""
echo "[2/4] Updating frontend files..."
for f in app.js network.js advanced.js node-form-dynamic.js style.css index.html; do
	if [ -f "$f" ]; then
		cp "$f" "$WEB_DIR/$f"
		echo "  + $f"
	else
		echo "  - Missing file: $f"
	fi
done

echo ""
echo "[3/4] Updating CGI files..."
CGI_FILES="cgi-common.sh status.sh logs.sh connection-history.sh connection-info.sh vpn-control.sh openvpn-control.sh openvpn-upload.sh openvpn-get-content.sh openvpn-save-content.sh passwall-settings.sh passwall-nodes.sh passwall-node-config.sh passwall-logs.sh network-interfaces.sh network-dhcp.sh network-firewall.sh network-diagnostics.sh exec.sh software-manager.sh startup-manager.sh system-control.sh snapshot.sh admin-control.sh"

for f in $CGI_FILES; do
	if [ -f "$f" ]; then
		cp "$f" "$CGI_DIR/$f"
		echo "  + $f"
	else
		echo "  - Missing CGI file: $f"
	fi
done

chmod +x "$CGI_DIR"/*.sh 2>/dev/null || true

echo ""
echo "[4/4] Update complete"
echo "=========================================="
echo "Frontend: $WEB_DIR"
echo "Backend:  $CGI_DIR"
echo "Refresh browser with Ctrl+Shift+R"
echo "=========================================="

exit 0
