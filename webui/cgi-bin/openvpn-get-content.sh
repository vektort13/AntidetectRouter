#!/bin/sh
# OpenVPN Get Content - returns plain text content of .ovpn file

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth

CONFIG="$(get_qs_param config)"

if [ -z "$CONFIG" ]; then
    echo "Content-Type: application/json"
    echo ""
    echo '{"status":"error","message":"Config name required"}'
    exit 1
fi

case "$CONFIG" in
    ''|*[!A-Za-z0-9_-]*)
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"error","message":"Invalid config name"}'
        exit 1
        ;;
esac

# Get config file path from UCI
CONFIG_PATH=$(uci get openvpn.${CONFIG}.config 2>/dev/null)

if [ -z "$CONFIG_PATH" ]; then
    echo "Content-Type: application/json"
    echo ""
    echo '{"status":"error","message":"No config file path found. This may be a UCI-only config."}'
    exit 1
fi

if [ ! -f "$CONFIG_PATH" ]; then
    echo "Content-Type: application/json"
    echo ""
    echo "{\"status\":\"error\",\"message\":\"File not found: $CONFIG_PATH\"}"
    exit 1
fi

# Return plain text content
echo "Content-Type: text/plain"
echo ""
cat "$CONFIG_PATH"
