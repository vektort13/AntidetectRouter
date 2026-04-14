#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="status"

PORT="$(get_param port)"

is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_luci_port() {
    is_valid_port "$1" || return 1
    [ "$1" -le 65172 ]
}

extract_password_from_post() {
    pass=""

    if command -v jq >/dev/null 2>&1; then
        pass="$(printf '%s' "$POST_DATA" | jq -r '.password // empty' 2>/dev/null)"
    fi

    if [ -z "$pass" ]; then
        pass="$(printf '%s' "$POST_DATA" | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    fi

    printf '%s' "$pass"
}

get_status() {
    SSH_PORT=$(uci get dropbear.@dropbear[0].Port 2>/dev/null || echo 22)
    LUCI_PORT=$(uci get uhttpd.main.listen_http 2>/dev/null | grep -o "[0-9]*" || echo 80)
    SSH_ENABLED=$(pgrep dropbear >/dev/null && echo "true" || echo "false")
    
    cat << EOF
{
  "status": "ok",
  "ssh_port": "$SSH_PORT",
  "luci_port": "$LUCI_PORT",
  "ssh_enabled": $SSH_ENABLED
}
EOF
}

set_ssh_port() {
    if ! is_valid_port "$PORT"; then
        echo '{"status":"error","message":"Invalid port (1-65535 required)"}'
        return
    fi
    
    uci set dropbear.@dropbear[0].Port="$PORT"
    uci commit dropbear
    /etc/init.d/dropbear restart
    
    echo "{\"status\":\"ok\",\"message\":\"SSH port changed to $PORT\"}"
}

set_luci_port() {
    if ! is_valid_luci_port "$PORT"; then
        echo '{"status":"error","message":"Invalid LuCI HTTP port (1-65172 required)"}'
        return
    fi

    HTTPS_PORT=$((PORT + 363))
    
    uci set uhttpd.main.listen_http="0.0.0.0:$PORT"
    uci set uhttpd.main.listen_https="0.0.0.0:$HTTPS_PORT"
    uci commit uhttpd
    /etc/init.d/uhttpd restart
    
    echo "{\"status\":\"ok\",\"message\":\"LuCI port changed to $PORT\"}"
}

set_password() {
    NEW_PASS="$(extract_password_from_post)"
    
    if [ -z "$NEW_PASS" ]; then
        echo '{"status":"error","message":"Password required"}'
        return
    fi
    
    printf '%s\n%s\n' "$NEW_PASS" "$NEW_PASS" | passwd root >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo '{"status":"ok","message":"Password changed"}'
    else
        echo '{"status":"error","message":"Failed to change password"}'
    fi
}

case "$ACTION" in
    status) get_status ;;
    set_ssh_port) set_ssh_port ;;
    set_luci_port) set_luci_port ;;
    set_password) set_password ;;
    *) echo '{"status":"error","message":"Invalid action"}' ;;
esac
