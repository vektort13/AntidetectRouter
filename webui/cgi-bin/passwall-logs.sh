#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth

echo "Content-Type: text/plain"
echo ""

print_logs() {
    if [ -f /tmp/passwall.log ]; then
        tail -n 300 /tmp/passwall.log
    fi

    if [ -f /tmp/log/passwall.log ]; then
        tail -n 300 /tmp/log/passwall.log
    fi

    if command -v logread >/dev/null 2>&1; then
        logread 2>/dev/null | grep -Ei 'passwall|xray|v2ray|sing-box|chinadns|dnsmasq' | tail -n 300
    fi
}

OUT="$(print_logs)"
if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
else
    echo "No Passwall logs found yet."
fi
