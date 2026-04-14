#!/bin/sh
# Shared helpers for VEKTORT13 CGI scripts

json_headers() {
    echo "Content-type: application/json"
    echo "Access-Control-Allow-Origin: *"
    echo ""
}

json_error() {
    code="$1"
    message="$2"
    [ -z "$code" ] && code="error"
    [ -z "$message" ] && message="Request failed"
    echo "{\"status\":\"$code\",\"message\":\"$message\"}"
}

get_cookie_value() {
    cookie_key="$1"
    printf '%s' "$HTTP_COOKIE" \
        | tr ';' '\n' \
        | sed -n "s/^[[:space:]]*${cookie_key}=\([^;[:space:]]*\).*$/\1/p" \
        | head -n1
}

is_valid_luci_session() {
    sid="$1"
    [ -n "$sid" ] || return 1

    case "$sid" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac

    if command -v ubus >/dev/null 2>&1; then
        if ubus call session access "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"luci\",\"object\":\"*\",\"function\":\"*\"}" 2>/dev/null | grep -q '"access":[[:space:]]*true'; then
            return 0
        fi
    fi

    [ -f "/tmp/luci-sessions/$sid" ]
}

require_auth() {
    # Allow CLI execution for debugging and local cron/hooks.
    [ -z "$GATEWAY_INTERFACE" ] && return 0

    # Loopback calls are trusted.
    case "$REMOTE_ADDR" in
        127.0.0.1|::1)
            return 0
            ;;
    esac

    session_id="$(get_cookie_value sysauth)"
    [ -z "$session_id" ] && session_id="$(get_cookie_value sysauth_http)"

    if is_valid_luci_session "$session_id"; then
        return 0
    fi

    echo "Status: 403 Forbidden"
    json_headers
    json_error "error" "Authentication required"
    exit 0
}

url_decode() {
    printf '%s' "$1" \
        | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' \
        | xargs -0 printf "%b" 2>/dev/null
}

get_qs_param() {
    key="$1"
    raw="$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n1)"
    [ -n "$raw" ] && url_decode "$raw"
}

POST_DATA=""
read_post_data() {
    if [ "$REQUEST_METHOD" = "POST" ] && [ -n "$CONTENT_LENGTH" ]; then
        POST_DATA="$(dd bs="$CONTENT_LENGTH" count=1 2>/dev/null)"
    elif [ "$REQUEST_METHOD" = "POST" ]; then
        IFS= read -r POST_DATA
    fi
}

get_post_param() {
    key="$1"
    raw="$(printf '%s' "$POST_DATA" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n1)"
    [ -n "$raw" ] && url_decode "$raw"
}

get_param() {
    key="$1"
    val="$(get_post_param "$key")"
    [ -n "$val" ] && {
        printf '%s' "$val"
        return
    }
    get_qs_param "$key"
}
