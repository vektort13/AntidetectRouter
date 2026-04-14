#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
json_headers
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="list"

PACKAGE="$(get_param package)"

list_packages() {
    echo '{'
    echo '  "status": "ok",'
    echo '  "packages": ['
    
    FIRST=1
    opkg list-installed | while read pkg version rest; do
        [ "$FIRST" = "1" ] && FIRST=0 || echo ","
        echo "    {\"name\": \"$pkg\", \"version\": \"$version\"}"
    done
    
    echo '  ]'
    echo '}'
}

update_lists() {
    opkg update >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo '{"status":"ok","message":"Package lists updated"}'
    else
        echo '{"status":"error","message":"Update failed"}'
    fi
}

install_package() {
    PKG="$PACKAGE"
    if [ -z "$PKG" ]; then
        echo '{"status":"error","message":"Package name required"}'
        return
    fi
    
    case "$PKG" in
        *[!A-Za-z0-9_.+-]*)
            echo '{"status":"error","message":"Invalid package name"}'
            return
            ;;
    esac
    
    opkg install "$PKG" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "{\"status\":\"ok\",\"message\":\"$PKG installed\"}"
    else
        echo "{\"status\":\"error\",\"message\":\"Failed to install $PKG\"}"
    fi
}

remove_package() {
    PKG="$PACKAGE"
    if [ -z "$PKG" ]; then
        echo '{"status":"error","message":"Package name required"}'
        return
    fi
    
    case "$PKG" in
        *[!A-Za-z0-9_.+-]*)
            echo '{"status":"error","message":"Invalid package name"}'
            return
            ;;
    esac
    
    opkg remove "$PKG" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "{\"status\":\"ok\",\"message\":\"$PKG removed\"}"
    else
        echo "{\"status\":\"error\",\"message\":\"Failed to remove $PKG\"}"
    fi
}

case "$ACTION" in
    list) list_packages ;;
    update) update_lists ;;
    install) install_package ;;
    remove) remove_package ;;
    *) echo '{"status":"error","message":"Invalid action"}' ;;
esac
