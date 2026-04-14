#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers

# Read POST JSON data
IFS= read -r POST_DATA

# Parse JSON
CONFIG=$(echo "$POST_DATA" | jq -r '.config // empty')
CONTENT_B64=$(echo "$POST_DATA" | jq -r '.content_b64 // empty')

if [ -z "$CONFIG" ] || [ -z "$CONTENT_B64" ]; then
    echo '{"status":"error","message":"Config and content_b64 required"}'
    exit 1
fi

case "$CONFIG" in
    ''|*[!A-Za-z0-9_-]*)
        echo '{"status":"error","message":"Invalid config name"}'
        exit 1
        ;;
esac

# Get config file path
CONFIG_PATH=$(uci get "openvpn.${CONFIG}.config" 2>/dev/null)

if [ -z "$CONFIG_PATH" ]; then
    echo '{"status":"error","message":"Config path not found in UCI"}'
    exit 1
fi

# Decode base64 and write to file
echo "$CONTENT_B64" | base64 -d > "$CONFIG_PATH"

# Restart OpenVPN if enabled
if [ "$(uci get openvpn.${CONFIG}.enabled 2>/dev/null)" = "1" ]; then
    /etc/init.d/openvpn restart
fi

echo '{"status":"ok","message":"Config saved"}'
