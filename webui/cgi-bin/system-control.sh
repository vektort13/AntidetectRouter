#!/bin/sh
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth

ACTION="$(get_qs_param action)"
[ -z "$ACTION" ] && ACTION="status"

if [ "$ACTION" != "restore" ]; then
    read_post_data
fi

if [ "$ACTION" != "download" ]; then
    json_headers
fi

get_status() {
    UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*load.*//' | sed 's/,.*//' | xargs)
    
    cat << EOF
{
  "status": "ok",
  "uptime": "$UPTIME"
}
EOF
}

do_reboot() {
    echo '{"status":"ok","message":"Rebooting..."}'
    sleep 1
    reboot &
}

backup_config() {
    BACKUP_FILE="/tmp/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    sysupgrade -b "$BACKUP_FILE" >/dev/null 2>&1
    
    if [ -f "$BACKUP_FILE" ]; then
        BACKUP_NAME="$(basename "$BACKUP_FILE")"
        DOWNLOAD_URL="/cgi-bin/vektort13/system-control.sh?action=download&file=$BACKUP_NAME"
        echo "{\"status\":\"ok\",\"file\":\"$DOWNLOAD_URL\",\"path\":\"$BACKUP_FILE\"}"
    else
        echo '{"status":"error","message":"Backup failed"}'
    fi
}

download_backup() {
    FILE="$(get_qs_param file)"
    FILE="$(basename "$FILE")"

    case "$FILE" in
        backup-*.tar.gz) ;;
        *) FILE="" ;;
    esac

    FILE_PATH="/tmp/$FILE"

    if [ -z "$FILE" ] || [ ! -f "$FILE_PATH" ]; then
        json_headers
        echo '{"status":"error","message":"Backup file not found"}'
        return
    fi

    echo "Content-Type: application/gzip"
    echo "Content-Disposition: attachment; filename=\"$FILE\""
    echo "Access-Control-Allow-Origin: *"
    echo ""
    cat "$FILE_PATH"
    rm -f "$FILE_PATH"
}

restore_config() {
    if [ "$REQUEST_METHOD" != "POST" ]; then
        echo '{"status":"error","message":"Use POST with backup_file upload"}'
        return
    fi

    RAW_FILE="/tmp/restore-raw-$$"
    RESTORE_FILE="/tmp/restore-config-$$.tar.gz"

    cat > "$RAW_FILE"
    BOUNDARY="$(head -n 1 "$RAW_FILE" | tr -d '\r\n')"

    if [ -z "$BOUNDARY" ]; then
        rm -f "$RAW_FILE" "$RESTORE_FILE"
        echo '{"status":"error","message":"Invalid upload payload"}'
        return
    fi

    awk -v boundary="$BOUNDARY" '
        BEGIN { in_file=0; found=0 }
        $0 ~ boundary {
            if (in_file) exit
            in_file=0
        }
        /Content-Disposition.*name="backup_file"/ {
            in_file=1
            found=1
            getline
            if ($0 ~ /^Content-Type:/) getline
            if ($0 ~ /^$/) getline
            next
        }
        in_file && found { print }
    ' "$RAW_FILE" > "$RESTORE_FILE"

    sed -i "/$BOUNDARY/d" "$RESTORE_FILE"

    if [ ! -s "$RESTORE_FILE" ]; then
        rm -f "$RAW_FILE" "$RESTORE_FILE"
        echo '{"status":"error","message":"Uploaded backup is empty or invalid"}'
        return
    fi

    if sysupgrade -r "$RESTORE_FILE" >/tmp/restore-config.log 2>&1; then
        rm -f "$RAW_FILE" "$RESTORE_FILE"
        echo '{"status":"ok","message":"Restore started. Device will reboot."}'
    else
        ERR_MSG="$(tail -n 5 /tmp/restore-config.log | tr '\n' ' ' | sed 's/"/\\"/g')"
        rm -f "$RAW_FILE" "$RESTORE_FILE"
        echo "{\"status\":\"error\",\"message\":\"Restore failed: $ERR_MSG\"}"
    fi
}

case "$ACTION" in
    status) get_status ;;
    reboot) do_reboot ;;
    backup) backup_config ;;
    download) download_backup ;;
    restore) restore_config ;;
    *) echo '{"status":"error","message":"Invalid action"}' ;;
esac
