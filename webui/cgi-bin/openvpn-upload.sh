#!/bin/sh
# OpenVPN Upload Handler
# Handles multipart/form-data file uploads with optional auth

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cgi-common.sh"

require_auth

# Set content type
echo "Content-Type: application/json"
echo ""

# Temp file for parsing
TMPFILE="/tmp/ovpn-upload-$$"
OVPN_DIR="/etc/openvpn"

# Ensure temp files are cleaned up on exit
trap 'rm -f "$TMPFILE" "$OVPN_DIR"/*.ovpn.tmp' EXIT

# Read POST data
cat > "$TMPFILE"

# Parse multipart data
BOUNDARY=$(head -n 1 "$TMPFILE" | tr -d '\r\n')

# Extract fields
get_field() {
    local field="$1"
    awk -v boundary="$BOUNDARY" -v field="$field" '
        BEGIN { in_field=0; content="" }
        $0 ~ boundary { in_field=0 }
        in_field { 
            if (NR > start_line + 1) {
                if (content != "") content = content "\n"
                content = content $0
            }
        }
        /Content-Disposition.*name="'$field'"/ { 
            in_field=1
            start_line=NR
        }
        END { 
            sub(/\r*$/, "", content)
            print content
        }
    ' "$TMPFILE"
}

# Get instance name
INSTANCE=$(get_field "instance_name" | head -1)

if [ -z "$INSTANCE" ]; then
    echo '{"status":"error","message":"Instance name required"}'
    rm -f "$TMPFILE"
    exit 1
fi

# Sanitize instance name
INSTANCE=$(echo "$INSTANCE" | sed 's/[^a-zA-Z0-9_-]//g')

if [ -z "$INSTANCE" ]; then
    echo '{"status":"error","message":"Invalid instance name"}'
    rm -f "$TMPFILE"
    exit 1
fi

# Create openvpn directory if not exists
mkdir -p "$OVPN_DIR"

# Extract .ovpn file content
OVPN_FILE="$OVPN_DIR/$INSTANCE.ovpn"

# Find where ovpn_file content starts and ends
awk -v boundary="$BOUNDARY" '
    BEGIN { in_file=0; found=0 }
    $0 ~ boundary { 
        if (in_file) exit
        in_file=0
    }
    /Content-Disposition.*name="ovpn_file"/ { 
        in_file=1
        found=1
        getline
        if ($0 ~ /^Content-Type:/) getline
        if ($0 ~ /^$/) getline
        next
    }
    in_file && found { print }
' "$TMPFILE" > "$OVPN_FILE.tmp"

# Remove trailing boundary and cleanup
sed -i "/$BOUNDARY/d" "$OVPN_FILE.tmp"
# Remove last empty lines
sed -i -e :a -e '/^\s*$/d;N;ba' "$OVPN_FILE.tmp"

# Check if file has content
if [ ! -s "$OVPN_FILE.tmp" ]; then
    echo '{"status":"error","message":"Invalid or empty .ovpn file"}'
    rm -f "$TMPFILE" "$OVPN_FILE.tmp"
    exit 1
fi

# Move to final location
mv "$OVPN_FILE.tmp" "$OVPN_FILE"
chmod 600 "$OVPN_FILE"

# Get username and password
USERNAME=$(get_field "username" | head -1)
PASSWORD=$(get_field "password" | head -1)

# If username and password provided, create .auth file
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
    AUTH_FILE="$OVPN_DIR/$INSTANCE.auth"
    
    printf '%s\n%s\n' "$USERNAME" "$PASSWORD" > "$AUTH_FILE"
    
    chmod 600 "$AUTH_FILE"
    
    # Check if .ovpn already has auth-user-pass
    if grep -q "^auth-user-pass" "$OVPN_FILE"; then
        # Replace existing line
        sed -i "s|^auth-user-pass.*|auth-user-pass $AUTH_FILE|" "$OVPN_FILE"
    else
        # Add new line
        echo "auth-user-pass $AUTH_FILE" >> "$OVPN_FILE"
    fi
fi

# Create UCI entry
if ! uci get openvpn.$INSTANCE >/dev/null 2>&1; then
    uci set openvpn.$INSTANCE=openvpn
fi

uci set openvpn.$INSTANCE.config="$OVPN_FILE"
uci set openvpn.$INSTANCE.enabled='0'
uci commit openvpn

# Cleanup
rm -f "$TMPFILE"

# Return success
echo '{"status":"ok","message":"Config uploaded successfully","instance":"'$INSTANCE'"}'

exit 0
