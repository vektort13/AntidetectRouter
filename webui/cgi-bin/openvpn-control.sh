#!/bin/sh
# OpenVPN Control Script

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
CONFIG="$(get_param config)"
COMMAND="$(get_param command)"

OVPN_DIR="/etc/openvpn"

is_valid_config_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba; s/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/\n/\\n/g'
}

case "$ACTION" in
    list)
        # List all configs
        CONFIGS="["
        FIRST=true
        
        for section in $(uci show openvpn 2>/dev/null | grep "=openvpn$" | cut -d'.' -f2 | cut -d'=' -f1); do
            # Skip rw (remote access server)
            if [ "$section" = "rw" ]; then
                continue
            fi
            
            config_file=$(uci get openvpn.$section.config 2>/dev/null)
            enabled=$(uci get openvpn.$section.enabled 2>/dev/null)
            
            if [ -n "$config_file" ] && [ -f "$config_file" ]; then
                if [ "$FIRST" = true ]; then
                    FIRST=false
                else
                    CONFIGS="$CONFIGS,"
                fi
                
                # Check status by PID file
                STATUS="stopped"
                PID_FILE="/var/run/openvpn-$section.pid"
                LOG_FILE="/tmp/openvpn-$section.log"
                
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE" 2>/dev/null)
                    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                        # Process is running, check connection status from logs
                        if [ -f "$LOG_FILE" ]; then
                            RECENT_LOGS=$(tail -50 "$LOG_FILE")
                            
                            if echo "$RECENT_LOGS" | grep -q "Initialization Sequence Completed"; then
                                STATUS="connected"
                            elif echo "$RECENT_LOGS" | grep -q "TCP connection established\|TLS: Initial packet\|SENT_CONTROL"; then
                                STATUS="connecting"
                            else
                                STATUS="starting"
                            fi
                        else
                            STATUS="starting"
                        fi
                    else
                        # PID file exists but process dead - clean up
                        rm -f "$PID_FILE" 2>/dev/null
                        STATUS="stopped"
                    fi
                fi
                
                CONFIGS="$CONFIGS{\"name\":\"$section\",\"file\":\"$(basename \"$config_file\")\",\"enabled\":\"$enabled\",\"status\":\"$STATUS\"}"
            fi
        done
        
        CONFIGS="$CONFIGS]"
        echo "{\"status\":\"ok\",\"configs\":$CONFIGS}"
        ;;
        
    control)
        # Control OpenVPN instance
        if [ -z "$CONFIG" ] || [ -z "$COMMAND" ]; then
            echo '{"status":"error","message":"Config and command required"}'
            exit 1
        fi
        
        if ! is_valid_config_name "$CONFIG"; then
            echo '{"status":"error","message":"Invalid config name"}'
            exit 1
        fi
        
        case "$COMMAND" in
            start)
                # Get config file path
                CONFIG_FILE=$(uci get openvpn.$CONFIG.config 2>/dev/null)
                
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo "{\"status\":\"error\",\"message\":\"Config file not found: $CONFIG_FILE\"}"
                    exit 1
                fi
                
                # Check if already running
                PID_FILE="/var/run/openvpn-$CONFIG.pid"
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE")
                    if kill -0 "$PID" 2>/dev/null; then
                        echo "{\"status\":\"error\",\"message\":\"Already running (PID: $PID)\"}"
                        exit 1
                    else
                        # Stale PID file, remove it
                        rm -f "$PID_FILE"
                    fi
                fi
                
                # Start OpenVPN directly
                LOG_FILE="/tmp/openvpn-$CONFIG.log"
                
                openvpn --config "$CONFIG_FILE" \
                        --daemon \
                        --writepid "$PID_FILE" \
                        --log "$LOG_FILE" \
                        --verb 3 \
                        --script-security 2 \
                        --up "/usr/libexec/openvpn-hotplug up $CONFIG" \
                        --down "/usr/libexec/openvpn-hotplug down $CONFIG" \
                        >/dev/null 2>&1
                
                # Wait briefly for process to start
                sleep 2
                
                # Check if process started
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE" 2>/dev/null)
                    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                        echo "{\"status\":\"ok\",\"message\":\"Started $CONFIG (connecting...)\"}"
                    else
                        # Process died - check log for errors
                        if [ -f "$LOG_FILE" ]; then
                            ERROR=$(grep -i "error\|cannot\|fail" "$LOG_FILE" | tail -1)
                            if [ -n "$ERROR" ]; then
                                ERROR_SAFE="$(json_escape "$ERROR")"
                                echo "{\"status\":\"error\",\"message\":\"Failed: $ERROR_SAFE\"}"
                            else
                                echo "{\"status\":\"error\",\"message\":\"Process died unexpectedly\"}"
                            fi
                        else
                            echo "{\"status\":\"error\",\"message\":\"Failed to start\"}"
                        fi
                    fi
                else
                    echo "{\"status\":\"error\",\"message\":\"Failed to create PID file\"}"
                fi
                ;;
            stop)
                PID_FILE="/var/run/openvpn-$CONFIG.pid"
                
                if [ ! -f "$PID_FILE" ]; then
                    echo "{\"status\":\"ok\",\"message\":\"Already stopped (no PID file)\"}"
                    exit 0
                fi
                
                # Read PID
                PID=$(cat "$PID_FILE" 2>/dev/null)
                
                if [ -z "$PID" ]; then
                    rm -f "$PID_FILE"
                    echo "{\"status\":\"ok\",\"message\":\"Stopped (PID file was empty)\"}"
                    exit 0
                fi
                
                # Kill process
                if kill -0 "$PID" 2>/dev/null; then
                    # Process exists, kill it
                    kill -TERM "$PID" 2>/dev/null
                    sleep 1
                    
                    # Force kill if still alive
                    if kill -0 "$PID" 2>/dev/null; then
                        kill -9 "$PID" 2>/dev/null
                        sleep 0.5
                    fi
                fi
                
                # Remove PID file
                rm -f "$PID_FILE"
                
                # Verify stopped
                if kill -0 "$PID" 2>/dev/null; then
                    echo "{\"status\":\"warning\",\"message\":\"Process may still be running\"}"
                else
                    echo "{\"status\":\"ok\",\"message\":\"Stopped $CONFIG\"}"
                fi
                ;;
            restart)
                # Simply stop and start
                PID_FILE="/var/run/openvpn-$CONFIG.pid"
                
                # Stop first
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE" 2>/dev/null)
                    if [ -n "$PID" ]; then
                        kill -9 "$PID" 2>/dev/null
                    fi
                    rm -f "$PID_FILE"
                    sleep 1
                fi
                
                # Get config file
                CONFIG_FILE=$(uci get openvpn.$CONFIG.config 2>/dev/null)
                
                if [ ! -f "$CONFIG_FILE" ]; then
                    echo "{\"status\":\"error\",\"message\":\"Config file not found\"}"
                    exit 1
                fi
                
                # Start
                LOG_FILE="/tmp/openvpn-$CONFIG.log"
                
                openvpn --config "$CONFIG_FILE" \
                        --daemon \
                        --writepid "$PID_FILE" \
                        --log "$LOG_FILE" \
                        --verb 3 \
                        --script-security 2 \
                        --up "/usr/libexec/openvpn-hotplug up $CONFIG" \
                        --down "/usr/libexec/openvpn-hotplug down $CONFIG" \
                        >/dev/null 2>&1
                
                # Wait briefly for process to start
                sleep 2
                
                # Verify
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE")
                    if kill -0 "$PID" 2>/dev/null; then
                        echo "{\"status\":\"ok\",\"message\":\"Restarted $CONFIG (connecting...)\"}"
                    else
                        echo "{\"status\":\"error\",\"message\":\"Failed to restart\"}"
                    fi
                else
                    echo "{\"status\":\"error\",\"message\":\"Failed to restart\"}"
                fi
                ;;
            enable)
                uci set openvpn.$CONFIG.enabled='1'
                uci commit openvpn
                echo "{\"status\":\"ok\",\"message\":\"Enabled $CONFIG\"}"
                ;;
            disable)
                uci set openvpn.$CONFIG.enabled='0'
                uci commit openvpn
                echo "{\"status\":\"ok\",\"message\":\"Disabled $CONFIG\"}"
                ;;
            *)
                echo "{\"status\":\"error\",\"message\":\"Unknown command: $COMMAND\"}"
                ;;
        esac
        ;;
        
    delete)
        # Delete config
        if [ -z "$CONFIG" ]; then
            echo '{"status":"error","message":"Config required"}'
            exit 1
        fi

        if ! is_valid_config_name "$CONFIG"; then
            echo '{"status":"error","message":"Invalid config name"}'
            exit 1
        fi
        
        # Stop if running (by PID file)
        PID_FILE="/var/run/openvpn-$CONFIG.pid"
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$PID" ]; then
                kill -9 "$PID" 2>/dev/null
            fi
            rm -f "$PID_FILE"
        fi
        
        # Get config file path
        CONFIG_FILE=$(uci get "openvpn.$CONFIG.config" 2>/dev/null)
        
        # Delete files
        if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
            rm -f "$CONFIG_FILE"
        fi
        
        AUTH_FILE="$OVPN_DIR/$CONFIG.auth"
        if [ -f "$AUTH_FILE" ]; then
            rm -f "$AUTH_FILE"
        fi
        
        # Delete log file
        LOG_FILE="/tmp/openvpn-$CONFIG.log"
        if [ -f "$LOG_FILE" ]; then
            rm -f "$LOG_FILE"
        fi
        
        # Delete UCI entry
        if uci get openvpn.$CONFIG >/dev/null 2>&1; then
            uci delete openvpn.$CONFIG
            uci commit openvpn
        fi
        
        echo "{\"status\":\"ok\",\"message\":\"Deleted $CONFIG\"}"
        ;;
        
    get_logs)
        # Get logs for config
        if [ -z "$CONFIG" ]; then
            echo '{"status":"error","message":"Config required"}'
            exit 1
        fi

        if ! is_valid_config_name "$CONFIG"; then
            echo '{"status":"error","message":"Invalid config name"}'
            exit 1
        fi
        
        LOG_FILE="/tmp/openvpn-$CONFIG.log"
        
        if [ ! -f "$LOG_FILE" ]; then
            echo "{\"status\":\"ok\",\"logs\":\"No logs available for $CONFIG\"}"
            exit 0
        fi
        
        # Get last 100 lines with safe JSON escaping
        LOGS_RAW="$(tail -100 "$LOG_FILE")"
        LOGS="$(json_escape "$LOGS_RAW")"
        
        echo "{\"status\":\"ok\",\"logs\":\"$LOGS\"}"
        ;;
        
    *)
        echo '{"status":"error","message":"Unknown action"}'
        ;;
esac

exit 0
