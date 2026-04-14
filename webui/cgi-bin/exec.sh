#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
PORT="$(get_param port)"
PACKAGE="$(get_param package)"

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

is_valid_package_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.+-]*) return 1 ;;
    esac
    return 0
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

case "$ACTION" in
    ssh_port)
        if ! is_valid_port "$PORT"; then
            echo '{"status":"error","message":"Invalid port (1-65535 required)"}'
            exit 1
        fi
        uci set dropbear.@dropbear[0].Port="$PORT"
        uci commit dropbear
        /etc/init.d/dropbear restart >/dev/null 2>&1
        echo "{\"status\":\"ok\",\"message\":\"SSH port changed to $PORT\"}"
        ;;
        
    luci_port)
        if ! is_valid_luci_port "$PORT"; then
            echo '{"status":"error","message":"Invalid LuCI HTTP port (1-65172 required)"}'
            exit 1
        fi
        HTTPS_PORT=$((PORT + 363))
        uci set uhttpd.main.listen_http="0.0.0.0:$PORT"
        uci set uhttpd.main.listen_https="0.0.0.0:$HTTPS_PORT"
        uci commit uhttpd
        /etc/init.d/uhttpd restart >/dev/null 2>&1
        echo "{\"status\":\"ok\",\"message\":\"LuCI port changed to $PORT\"}"
        ;;
        
    password)
        PASS="$(extract_password_from_post)"
        if [ -z "$PASS" ]; then
            echo '{"status":"error","message":"Password required"}'
            exit 1
        fi
        printf '%s\n%s\n' "$PASS" "$PASS" | passwd root >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo '{"status":"ok","message":"Password changed"}'
        else
            echo '{"status":"error","message":"Failed"}'
        fi
        ;;
        
    update_lists)
        opkg update >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo '{"status":"ok","message":"Package lists updated"}'
        else
            echo '{"status":"error","message":"Update failed"}'
        fi
        ;;
        
    install)
        PKG="$PACKAGE"
        if ! is_valid_package_name "$PKG"; then
            echo '{"status":"error","message":"Invalid package name"}'
            exit 1
        fi
        opkg install "$PKG" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "{\"status\":\"ok\",\"message\":\"$PKG installed\"}"
        else
            echo "{\"status\":\"error\",\"message\":\"Failed to install $PKG\"}"
        fi
        ;;
        
    reboot)
        echo '{"status":"ok","message":"Rebooting..."}'
        sleep 1
        reboot &
        ;;
        
    uptime)
        UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*load.*//' | sed 's/,.*//' | xargs)
        UPTIME=$(printf '%s' "$UPTIME" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "{\"status\":\"ok\",\"uptime\":\"$UPTIME\"}"
        ;;
        
    get_ports)
        SSH=$(uci get dropbear.@dropbear[0].Port 2>/dev/null || echo "22")
        HTTP=$(uci get uhttpd.main.listen_http 2>/dev/null | grep -o "[0-9]*$" || echo "80")
        echo "{\"status\":\"ok\",\"ssh_port\":\"$SSH\",\"luci_port\":\"$HTTP\"}"
        ;;
        
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
