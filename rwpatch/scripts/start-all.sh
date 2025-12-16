#!/bin/sh
# Master startup script v0.1
# Starts RW server and monitors - no waiting for upstream!
# dual-vpn-switcher handles everything automatically
# Usage: /root/start-all.sh [install]

LOG="/tmp/start-all.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# ==================== ФУНКЦИЯ: Установка в автозагрузку ====================
install_autostart() {
    log ""
    log "=========================================="
    log "УСТАНОВКА В АВТОЗАГРУЗКУ"
    log "=========================================="
    log ""
    
    # Проверяем rc.local
    if ! grep -q "start-all.sh" /etc/rc.local 2>/dev/null; then
        log "Добавляем в /etc/rc.local..."
        
        # Создаём backup
        cp /etc/rc.local /etc/rc.local.backup 2>/dev/null
        
        # Удаляем exit 0 если есть
        sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null
        
        # Добавляем наш запуск
        cat >> /etc/rc.local << 'EOF'

# Dual VPN Auto-start 0.1v
sleep 10
/root/start-all.sh &

exit 0
EOF
        
        chmod +x /etc/rc.local
        log "✓ Добавлено в /etc/rc.local"
    else
        log "✓ Уже установлено в /etc/rc.local"
    fi
    
    log ""
}

# ==================== ПРОВЕРКА РЕЖИМА УСТАНОВКИ ====================
if [ "$1" = "install" ]; then
    install_autostart
    exit 0
fi

# ==================== ОСНОВНОЙ ЗАПУСК ====================
: > "$LOG"

log "=========================================="
log "DUAL VPN STARTUP v0.1 - FINAL WORKING"
log "=========================================="
log ""

# ==================== STEP 1: UCI ====================
log "[1/4] Configuring UCI..."

# Force RW to tun0
uci set openvpn.rw.dev='tun0'
log "  RW → tun0 (FIXED!)"

# Remove dev from other VPN configs (let them auto-assign tun1, tun2, etc)
for config in $(uci show openvpn | grep "=openvpn" | cut -d. -f2 | cut -d= -f1 | grep -v rw); do
    uci delete openvpn.$config.dev 2>/dev/null
done

uci commit openvpn
log "✓ UCI saved"
log ""

# ==================== STEP 2: STOP ALL ====================
log "[2/4] Stopping all OpenVPN..."

/etc/init.d/openvpn stop 2>/dev/null
sleep 2
killall openvpn 2>/dev/null
sleep 1

log "✓ Stopped"
log ""

# ==================== STEP 3: START RW ONLY ====================
log "[3/4] Starting RW server (tun0)..."

/etc/init.d/openvpn start rw 2>&1 | tee -a "$LOG"

COUNT=0
while [ $COUNT -lt 10 ]; do
    if ip link show tun0 >/dev/null 2>&1; then
        RW_IP=$(ip addr show tun0 | grep 'inet ' | awk '{print $2}')
        log "✓ tun0: $RW_IP"
        break
    fi
    sleep 1
    COUNT=$((COUNT + 1))
done

if ! ip link show tun0 >/dev/null 2>&1; then
    log "✗ FAILED to start RW!"
    log "  Cannot continue without RW"
    exit 1
fi

log ""

# ==================== STEP 4: START MONITORS (NO UPSTREAM WAIT!) ====================
log "[4/4] Starting monitors..."

# 1. Universal client monitor (always runs)
killall universal-client-monitor.sh 2>/dev/null
sleep 1

if [ -f /root/universal-client-monitor.sh ]; then
    /root/universal-client-monitor.sh &
    sleep 1
    log "✓ Client monitor started (SSH/LuCI protection)"
else
    log "⚠️  universal-client-monitor.sh not found"
fi

# 2. Upstream monitor (monitors tun1, auto rw-fix)
killall upstream-monitor.sh 2>/dev/null
sleep 1

if [ -f /root/upstream-monitor.sh ]; then
    /root/upstream-monitor.sh &
    sleep 1
    log "✓ Upstream monitor started (auto rw-fix)"
else
    log "⚠️  upstream-monitor.sh not found"
fi

# 3. DUAL VPN SWITCHER (main logic) - CRITICAL!
killall dual-vpn-switcher.sh 2>/dev/null
sleep 1

if [ -f /root/dual-vpn-switcher.sh ]; then
    /root/dual-vpn-switcher.sh &
    sleep 1
    log "✓ Dual VPN Switcher started (MAIN CONTROLLER)"
else
    log "✗ CRITICAL: dual-vpn-switcher.sh not found!"
    log "  System will not switch modes automatically"
fi

# Note: vpn-dns-monitor will be started by dual-vpn-switcher when needed

log ""
log "=========================================="
log "STARTUP COMPLETE!"
log "=========================================="
log ""
log "System Status:"
log "  ✓ RW Server (tun0) running"
log "  ✓ All monitors active"
log ""
log "Monitors will automatically detect and configure:"
log "  - Passwall (if started) → fw4 OFF mode"
log "  - OpenVPN (if started) → fw4 ON + rw-fix + DNS mode"
log ""
log "You can now:"
log "  - Start Passwall via LuCI or: /etc/init.d/passwall start"
log "  - Start OpenVPN via LuCI or: /etc/init.d/openvpn start vpv"
log "  - Monitors will handle everything automatically!"
log ""
log "Logs:"
log "  - Main:       tail -f /tmp/start-all.log"
log "  - Switcher:   tail -f /tmp/dual-vpn-switcher.log"
log "  - Upstream:   tail -f /tmp/upstream-monitor.log"
log "  - Clients:    tail -f /tmp/universal-client-monitor.log"
log ""
