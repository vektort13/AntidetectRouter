#!/bin/sh
# VEKTORT13 ROLLBACK SCRIPT
# Откатывает все примененные патчи

echo "=============================================="
echo "VEKTORT13 ROLLBACK - Откат всех патчей"
echo "=============================================="
echo ""

# 1. Откат OpenVPN Hotplug
if [ -f /usr/libexec/openvpn-hotplug.backup ]; then
    echo "Откатываю OpenVPN hotplug..."
    cp /usr/libexec/openvpn-hotplug.backup /usr/libexec/openvpn-hotplug
    chmod +x /usr/libexec/openvpn-hotplug
    echo "✓ Hotplug восстановлен"
else
    echo "⚠️  Backup hotplug не найден"
fi

echo ""

# 2. Откат Dual VPN Switcher
LATEST_BACKUP=$(ls -t /root/dual-vpn-switcher.sh.backup.* 2>/dev/null | head -1)
if [ -n "$LATEST_BACKUP" ]; then
    echo "Откатываю dual-vpn-switcher..."
    cp "$LATEST_BACKUP" /root/dual-vpn-switcher.sh
    chmod +x /root/dual-vpn-switcher.sh
    
    # Рестарт
    killall dual-vpn-switcher.sh 2>/dev/null
    sleep 1
    /root/dual-vpn-switcher.sh >/dev/null 2>&1 &
    
    echo "✓ Switcher восстановлен из: $LATEST_BACKUP"
else
    echo "⚠️  Backup switcher не найден"
fi

echo ""

# 3. Рестарт OpenVPN
echo "Перезапуск OpenVPN..."
/etc/init.d/openvpn restart
sleep 2
echo "✓ OpenVPN перезапущен"

echo ""
echo "=============================================="
echo "ROLLBACK COMPLETE"
echo "=============================================="
echo ""
echo "Проверь статус:"
echo "  ./diagnostics.sh"
echo ""
echo "Логи:"
echo "  tail -f /tmp/dual-vpn-switcher.log"
echo "  logread | grep openvpn"
echo "=============================================="
