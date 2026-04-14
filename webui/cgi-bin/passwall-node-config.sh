#!/bin/sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
NODE_ID="$(get_param node)"

[ -z "$ACTION" ] && ACTION="save"

is_valid_uci_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    return 0
}

# Sanitize a value for safe use in UCI set commands.
# Strips newlines, carriage returns, and single quotes that could
# corrupt the UCI config file.
sanitize_uci_value() {
    printf '%s' "$1" | tr -d "'\n\r"
}

# Validate address: IP, hostname, or domain — no shell metacharacters
is_valid_address() {
    case "$1" in
        ''|*[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    return 0
}

# Validate port range
is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] 2>/dev/null
}

# Handle save action - convert to create/update
if [ "$ACTION" = "save" ]; then
    if [ "$NODE_ID" = "new" ] || [ -z "$NODE_ID" ]; then
        ACTION="create"
    else
        ACTION="update"
    fi
fi

set_field_if_present() {
    section="$1"
    field="$2"
    value="$(sanitize_uci_value "$3")"
    [ -n "$value" ] && uci set "passwall.$section.$field=$value"
}

clean_port() {
    printf '%s' "$1" | tr -cd '0-9'
}

collect_fields() {
    REMARKS="$(get_param remarks)"
    TYPE="$(get_param type)"
    PROTOCOL="$(get_param protocol)"
    ADDRESS="$(get_param address)"
    PORT="$(clean_port "$(get_param port)")"
    USERNAME="$(get_param username)"
    PASSWORD="$(get_param password)"
    UUID="$(get_param uuid)"
    ENCRYPTION="$(get_param encryption)"
    TRANSPORT="$(get_param transport)"
    TLS="$(get_param tls)"
}

case "$ACTION" in
    create)
        collect_fields

        if [ -z "$REMARKS" ] || [ -z "$ADDRESS" ] || [ -z "$PORT" ]; then
            echo '{"status":"error","message":"Missing required fields: remarks, address, port"}'
            exit 1
        fi

        if ! is_valid_address "$ADDRESS"; then
            echo '{"status":"error","message":"Invalid address format"}'
            exit 1
        fi

        if ! is_valid_port "$PORT"; then
            echo '{"status":"error","message":"Invalid port number"}'
            exit 1
        fi

        REMARKS="$(sanitize_uci_value "$REMARKS")"

        SECTION="node_$(date +%s)_$$"

        uci set "passwall.$SECTION=nodes"
        uci set "passwall.$SECTION.remarks=$REMARKS"
        uci set "passwall.$SECTION.type=${TYPE:-Xray}"
        uci set "passwall.$SECTION.protocol=${PROTOCOL:-socks}"
        uci set "passwall.$SECTION.address=$ADDRESS"
        uci set "passwall.$SECTION.port=$PORT"

        set_field_if_present "$SECTION" "username" "$USERNAME"
        set_field_if_present "$SECTION" "password" "$PASSWORD"
        set_field_if_present "$SECTION" "uuid" "$UUID"
        set_field_if_present "$SECTION" "encryption" "$ENCRYPTION"
        set_field_if_present "$SECTION" "transport" "$TRANSPORT"
        set_field_if_present "$SECTION" "tls" "$TLS"

        uci commit passwall
        /etc/init.d/passwall restart >/dev/null 2>&1 &

        echo "{\"status\":\"ok\",\"message\":\"Node created\",\"id\":\"$SECTION\"}"
        ;;

    update)
        if [ -z "$NODE_ID" ]; then
            echo '{"status":"error","message":"Node ID required"}'
            exit 1
        fi

        if ! is_valid_uci_name "$NODE_ID"; then
            echo '{"status":"error","message":"Invalid node ID"}'
            exit 1
        fi

        collect_fields

        set_field_if_present "$NODE_ID" "remarks" "$REMARKS"
        set_field_if_present "$NODE_ID" "type" "$TYPE"
        set_field_if_present "$NODE_ID" "protocol" "$PROTOCOL"
        set_field_if_present "$NODE_ID" "address" "$ADDRESS"
        set_field_if_present "$NODE_ID" "port" "$PORT"
        set_field_if_present "$NODE_ID" "username" "$USERNAME"
        set_field_if_present "$NODE_ID" "password" "$PASSWORD"
        set_field_if_present "$NODE_ID" "uuid" "$UUID"
        set_field_if_present "$NODE_ID" "encryption" "$ENCRYPTION"
        set_field_if_present "$NODE_ID" "transport" "$TRANSPORT"
        set_field_if_present "$NODE_ID" "tls" "$TLS"

        uci commit passwall
        /etc/init.d/passwall restart >/dev/null 2>&1 &

        echo '{"status":"ok","message":"Node updated"}'
        ;;

    delete)
        if [ -z "$NODE_ID" ]; then
            echo '{"status":"error","message":"Node ID required"}'
            exit 1
        fi

        if ! is_valid_uci_name "$NODE_ID"; then
            echo '{"status":"error","message":"Invalid node ID"}'
            exit 1
        fi

        uci delete "passwall.$NODE_ID"
        uci commit passwall
        /etc/init.d/passwall restart >/dev/null 2>&1 &

        echo '{"status":"ok","message":"Node deleted"}'
        ;;

    *)
        echo '{"status":"error","message":"Unknown action"}'
        ;;
esac
