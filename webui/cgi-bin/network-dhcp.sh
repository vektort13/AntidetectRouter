#!/bin/sh
# DHCP & DNS Management

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="status"

is_valid_ipv4() {
    local old_ifs octet
    old_ifs="$IFS"
    IFS=.
    set -- $1
    IFS="$old_ifs"

    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        case "$octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

# Get DHCP leases
get_leases() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "leases": ['
    
    FIRST=1
    if [ -f /tmp/dhcp.leases ]; then
        while read -r EXPIRE MAC IP HOSTNAME _; do
            [ "$FIRST" = "1" ] && FIRST=0 || echo ","
            
            # Calculate remaining time
            NOW=$(date +%s)
            REMAINING=$((EXPIRE - NOW))
            [ $REMAINING -lt 0 ] && REMAINING=0
            
            HOURS=$((REMAINING / 3600))
            MINS=$(((REMAINING % 3600) / 60))
            TIME_LEFT="${HOURS}h ${MINS}m"
            
            cat << EOF
    {
      "mac": "$MAC",
      "ip": "$IP",
      "hostname": "$HOSTNAME",
      "expires": "$TIME_LEFT"
    }
EOF
        done < /tmp/dhcp.leases
    fi
    
    echo '  ]'
    echo '}'
}

# Get DNS settings
get_dns() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "dns_servers": ['
    
    FIRST=1
    # Get from UCI
    for dns in $(uci get dhcp.@dnsmasq[0].server 2>/dev/null); do
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        echo "    \"$dns\""
    done
    
    # Fallback to resolv.conf
    if [ "$FIRST" = "1" ] && [ -f /etc/resolv.conf ]; then
        while read -r line; do
            if echo "$line" | grep -q "^nameserver"; then
                DNS=$(echo "$line" | awk '{print $2}')
                [ "$FIRST" = "1" ] && FIRST=0 || echo ","
                echo "    \"$DNS\""
            fi
        done < /etc/resolv.conf
    fi
    
    echo '  ]'
    echo '}'
}

# Get static leases
get_static() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "static_leases": ['
    
    FIRST=1
    uci show dhcp | grep "dhcp.@host" | while read line; do
        case "$line" in
            *".mac="*)
                MAC=$(echo "$line" | cut -d"'" -f2)
                ;;
            *".ip="*)
                IP=$(echo "$line" | cut -d"'" -f2)
                ;;
            *".name="*)
                NAME=$(echo "$line" | cut -d"'" -f2)
                
                [ "$FIRST" = "1" ] && FIRST=0 || echo ","
                cat << EOF
    {
      "mac": "$MAC",
      "ip": "$IP",
      "name": "$NAME"
    }
EOF
                ;;
        esac
    done
    
    echo '  ]'
    echo '}'
}

# Add static lease
add_static() {
    # This would need MAC, IP, NAME from POST data
    echo '{"status":"ok","message":"Static lease added (not implemented yet)"}'
}

# Main logic
case "$ACTION" in
    status)
        # Return everything
        echo '{'
        echo '  "status": "ok",'
        echo '  "leases": [],'
        echo '  "dns_servers": [],'
        echo '  "static_leases": []'
        echo '}'
        ;;
    leases)
        get_leases
        ;;
    dns)
        get_dns
        ;;
    static)
        get_static
        ;;
    add_static)
        add_static
        ;;
    reset_dns)
        uci delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
        uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        echo '{"status":"ok","message":"DNS reset"}'
        ;;
    set_dns)
        VALID_DNS=""

        # Support both POST JSON and GET parameter
        DNS_PARAM="$(get_param dns)"

        if [ -n "$DNS_PARAM" ]; then
            # GET parameter: dns=8.8.8.8,1.1.1.1
            DNS_LIST="$DNS_PARAM"
        else
            # POST JSON: {"dns":["8.8.8.8","1.1.1.1"]}
            DNS_LIST=$(echo "$POST_DATA" | grep -o '"dns":\[.*\]' | sed 's/"dns":\[//; s/\]//; s/"//g')
        fi

        DNS_LIST="$(printf '%s' "$DNS_LIST" | tr -d '[:space:]')"
        
        if [ -n "$DNS_LIST" ]; then
            for dns_server in $(echo "$DNS_LIST" | tr ',' ' '); do
                if ! is_valid_ipv4 "$dns_server"; then
                    echo "{\"status\":\"error\",\"message\":\"Invalid DNS: $dns_server\"}"
                    exit 1
                fi
                VALID_DNS="${VALID_DNS}${VALID_DNS:+ }$dns_server"
            done

            uci delete dhcp.@dnsmasq[0].server 2>/dev/null
            for dns_server in $VALID_DNS; do
                uci add_list dhcp.@dnsmasq[0].server="$dns_server"
            done
            uci commit dhcp
            /etc/init.d/dnsmasq restart
            echo '{"status":"ok","message":"DNS updated"}'
        else
            echo '{"status":"error","message":"No DNS provided"}'
        fi
        ;;
    *)
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
