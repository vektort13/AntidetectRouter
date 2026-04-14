#!/bin/sh
# Snapshot Generator - запускает /root/mega-snapshot.sh и возвращает архив

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth
read_post_data

ACTION="$(get_param action)"
[ -z "$ACTION" ] && ACTION="create"

case "$ACTION" in
    create)
        json_headers

        # Generate unique snapshot name
        TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
        SNAPSHOT_NAME="snapshot-$TIMESTAMP"
        
        # Run mega-snapshot.sh
        if [ ! -f /root/mega-snapshot.sh ]; then
            echo '{"status":"error","message":"mega-snapshot.sh not found at /root/mega-snapshot.sh"}'
            exit 1
        fi
        
        chmod +x /root/mega-snapshot.sh
        
        # Execute snapshot (redirect output to log)
        /root/mega-snapshot.sh "$SNAPSHOT_NAME" > /tmp/snapshot-creation.log 2>&1
        
        SNAPSHOT_DIR="/root/snapshots/$SNAPSHOT_NAME"
        
        if [ ! -d "$SNAPSHOT_DIR" ]; then
            echo '{"status":"error","message":"Snapshot creation failed"}'
            exit 1
        fi
        
        # Create tar.gz archive
        ARCHIVE_PATH="/tmp/${SNAPSHOT_NAME}.tar.gz"
        cd /root/snapshots
        tar -czf "$ARCHIVE_PATH" "$SNAPSHOT_NAME/" 2>/dev/null
        
        if [ ! -f "$ARCHIVE_PATH" ]; then
            echo '{"status":"error","message":"Archive creation failed"}'
            exit 1
        fi
        
        # Return download URL
        cat << EOF
{
  "status": "ok",
  "message": "Snapshot created successfully",
  "snapshot_name": "$SNAPSHOT_NAME",
  "archive_path": "$ARCHIVE_PATH",
  "download_url": "/cgi-bin/vektort13/snapshot.sh?action=download&file=${SNAPSHOT_NAME}.tar.gz"
}
EOF
        ;;
        
    download)
        # Download the archive
        FILE="$(get_param file)"
        FILE="$(basename "$FILE")"

        case "$FILE" in
            snapshot-*.tar.gz) ;;
            *) FILE="" ;;
        esac

        FILE_PATH="/tmp/$FILE"
        
        if [ -z "$FILE" ] || [ ! -f "$FILE_PATH" ]; then
            json_headers
            echo '{"status":"error","message":"File not found"}'
            exit 1
        fi
        
        # Send file for download
        echo "Content-Type: application/gzip"
        echo "Content-Disposition: attachment; filename=\"$FILE\""
        echo "Access-Control-Allow-Origin: *"
        echo ""
        cat "$FILE_PATH"
        
        # Clean up after download
        rm -f "$FILE_PATH"
        ;;
        
    *)
        json_headers
        echo '{"status":"error","message":"Invalid action"}'
        ;;
esac
