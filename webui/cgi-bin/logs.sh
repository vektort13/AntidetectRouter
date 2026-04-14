#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth

echo "Content-Type: text/plain"
echo ""

# Tail last 1000 lines of dual-vpn-switcher log
if [ -f /tmp/dual-vpn-switcher.log ]; then
    tail -1000 /tmp/dual-vpn-switcher.log
else
    echo "No log file found at /tmp/dual-vpn-switcher.log"
    echo ""
    echo "If dual-vpn-switcher is running, logs should appear here automatically."
fi
