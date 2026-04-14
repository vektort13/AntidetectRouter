#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="list"

SERVICE="$(get_param service)"
COMMAND="$(get_param command)"

list_services() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "services": ['
    
    FIRST=1
    for service in /etc/init.d/*; do
        [ -x "$service" ] || continue
        NAME=$(basename "$service")
        
        # Skip certain services
        case "$NAME" in
            boot|done|rcS) continue ;;
        esac
        
        # Check if enabled
        ENABLED="false"
        ls /etc/rc.d/*"$NAME" >/dev/null 2>&1 && ENABLED="true"
        
        # Check if running
        RUNNING="false"
        "$service" running >/dev/null 2>&1 && RUNNING="true"
        
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        echo "    {\"name\": \"$NAME\", \"enabled\": $ENABLED, \"running\": $RUNNING}"
    done
    
    echo '  ]'
    echo '}'
}

control_service() {
    SVC="$SERVICE"
    CMD="$COMMAND"
    
    if [ -z "$SVC" ] || [ -z "$CMD" ]; then
        echo '{"status":"error","message":"Service and command required"}'
        return
    fi
    
    # Validate service name (alphanumeric, hyphen, underscore only)
    case "$SVC" in
        ''|*[!A-Za-z0-9_-]*)
            echo '{"status":"error","message":"Invalid service name"}'
            return
            ;;
    esac
    
    if [ ! -x "/etc/init.d/$SVC" ]; then
        echo '{"status":"error","message":"Service not found"}'
        return
    fi
    
    case "$CMD" in
        enable)
            /etc/init.d/"$SVC" enable
            echo "{\"status\":\"ok\",\"message\":\"$SVC enabled\"}"
            ;;
        disable)
            /etc/init.d/"$SVC" disable
            echo "{\"status\":\"ok\",\"message\":\"$SVC disabled\"}"
            ;;
        start)
            /etc/init.d/"$SVC" start
            echo "{\"status\":\"ok\",\"message\":\"$SVC started\"}"
            ;;
        stop)
            /etc/init.d/"$SVC" stop
            echo "{\"status\":\"ok\",\"message\":\"$SVC stopped\"}"
            ;;
        restart)
            /etc/init.d/"$SVC" restart
            echo "{\"status\":\"ok\",\"message\":\"$SVC restarted\"}"
            ;;
        *)
            echo '{"status":"error","message":"Invalid command"}'
            ;;
    esac
}

case "$ACTION" in
    list) list_services ;;
    control) control_service ;;
    *) echo '{"status":"error","message":"Invalid action"}' ;;
esac
