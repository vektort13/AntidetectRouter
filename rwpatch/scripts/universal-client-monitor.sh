#!/bin/sh
# universal-client-monitor.sh v0.1 - AUTO-DETECT PORTS
# Automatically adds /32 routes for ANY client connecting to SSH/LuCI/OpenVPN
# Ports are auto-detected from UCI configuration

LOG="/tmp/universal-client-monitor.log"
SEEN_CLIENTS_FILE="/tmp/universal-seen-clients.txt"

# Interface and gateway
WAN_IF="br-lan"
GATEWAY="134.122.0.1"

# AUTO-DETECT ports from UCI
SSH_PORT=$(uci get dropbear.@dropbear[0].Port 2>/dev/null || echo "22")
OPENVPN_PORT=$(uci get openvpn.rw.port 2>/dev/null || echo "1194")

# LuCI HTTP/HTTPS ports
HTTP_PORT=""
HTTPS_PORT=""

# Parse uhttpd listen addresses
for listen in $(uci get uhttpd.main.listen_http 2>/dev/null); do
    # Extract port from format "0.0.0.0:80" or "[::]:80"
    port=$(echo "$listen" | grep -oE '[0-9]+$')
    [ -n "$port" ] && HTTP_PORT="$port" && break
done
[ -z "$HTTP_PORT" ] && HTTP_PORT="80"

for listen in $(uci get uhttpd.main.listen_https 2>/dev/null); do
    port=$(echo "$listen" | grep -oE '[0-9]+$')
    [ -n "$port" ] && HTTPS_PORT="$port" && break
done
[ -z "$HTTPS_PORT" ] && HTTPS_PORT="443"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Create seen clients file
touch "$SEEN_CLIENTS_FILE"

: > "$LOG"
log "=== Universal Client Monitor Started ==="
log "Monitoring ports: $SSH_PORT (SSH), $HTTP_PORT (HTTP), $HTTPS_PORT (HTTPS), $OPENVPN_PORT (OpenVPN)"
log "Gateway: $GATEWAY"
log ""

# Function to add priority route for client
add_client_route() {
    local CLIENT_IP="$1"
    local PORT="$2"
    
    # Check if already seen
    if grep -q "^$CLIENT_IP$" "$SEEN_CLIENTS_FILE" 2>/dev/null; then
        # Already processed, skip silently
        return 0
    fi
    
    log ">>> New client detected: $CLIENT_IP (port $PORT)"
    
    # Validate IP
    if ! echo "$CLIENT_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        log "✗ Invalid IP format: $CLIENT_IP"
        return 1
    fi
    
    # Skip local/private IPs
    if echo "$CLIENT_IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)'; then
        log "  Skipping private/local IP: $CLIENT_IP"
        return 0
    fi
    
    # Try to add route
    if ip route add "$CLIENT_IP/32" via "$GATEWAY" dev "$WAN_IF" metric 10 2>/dev/null; then
        log "✓ Added route: $CLIENT_IP/32 via $GATEWAY (metric 10)"
        echo "$CLIENT_IP" >> "$SEEN_CLIENTS_FILE"
        
        # Verify route
        ROUTE_CHECK=$(ip route get "$CLIENT_IP" 2>/dev/null | head -1)
        if echo "$ROUTE_CHECK" | grep -q "$WAN_IF"; then
            log "✓ Route verified: $CLIENT_IP → $WAN_IF"
        else
            log "⚠ Route may not work: $ROUTE_CHECK"
        fi
    else
        # Route already exists or error
        EXISTING_ROUTE=$(ip route get "$CLIENT_IP" 2>/dev/null | head -1)
        if echo "$EXISTING_ROUTE" | grep -q "$WAN_IF"; then
            log "  Route already exists through $WAN_IF (OK)"
            echo "$CLIENT_IP" >> "$SEEN_CLIENTS_FILE"
        else
            log "✗ Failed to add route, current: $EXISTING_ROUTE"
        fi
    fi
}

# Monitor using tcpdump on multiple ports
log "Starting tcpdump monitor..."
log "Listening for TCP/UDP packets on ports: $SSH_PORT, $HTTP_PORT, $HTTPS_PORT, $OPENVPN_PORT"
log ""

# Start tcpdump for all monitored ports
tcpdump -i "$WAN_IF" -n -l \
    "(tcp dst port $SSH_PORT or tcp dst port $HTTP_PORT or tcp dst port $HTTPS_PORT or udp dst port $OPENVPN_PORT) and dst host $(ip addr show $WAN_IF | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)" \
    2>/dev/null | while read -r line; do
    
    # Extract source IP from tcpdump output
    # Format: "IP 1.2.3.4.12345 > 5.6.7.8.80: ..."
    CLIENT_IP=$(echo "$line" | grep -oE 'IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ >' | awk '{print $2}' | cut -d. -f1-4)
    
    if [ -n "$CLIENT_IP" ]; then
        # Extract destination port
        DST_PORT=$(echo "$line" | grep -oE '\.[0-9]+: ' | head -1 | tr -d '.: ')
        
        # Add route for this client
        add_client_route "$CLIENT_IP" "$DST_PORT"
    fi
done &

TCPDUMP_PID=$!
log "tcpdump started (PID: $TCPDUMP_PID)"
log ""
log "Monitor is now active!"
log "All clients connecting to SSH/LuCI/OpenVPN will automatically get /32 routes"
log ""
log "To stop: kill $TCPDUMP_PID"
log "To view seen clients: cat $SEEN_CLIENTS_FILE"
log "To view log: tail -f $LOG"
log ""

# Keep script running
wait $TCPDUMP_PID
