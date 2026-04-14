#!/bin/sh
# ============================================================
# MATRIX VEKTORT13 - One-Click Installer for LuCI
# ============================================================
# Автоматическая установка Matrix анимации в LuCI
# Работает с любой версией LuCI (старой и новой)
# ============================================================

set -e

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║                                                        ║"
echo "║        MATRIX VEKTORT13 - LuCI Installer               ║"
echo "║                                                        ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# ПРОВЕРКИ
# ============================================================

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo "✗ ERROR: Нужны права root!"
    echo "  Запусти: sudo $0"
    exit 1
fi

echo "✓ Права root"

# Check LuCI
if [ ! -d "/www/luci-static" ]; then
    echo "✗ ERROR: LuCI не найден!"
    exit 1
fi

echo "✓ LuCI найден"

# Check matrix script exists
if [ ! -f "./matrix-v6-LUCI-INTEGRATION.js" ]; then
    echo "✗ ERROR: Файл matrix-v6-LUCI-INTEGRATION.js не найден!"
    echo ""
    echo "Убедись что файл находится в той же папке что и установщик:"
    echo "  ls -la matrix-v6-LUCI-INTEGRATION.js"
    exit 1
fi

echo "✓ Matrix скрипт найден"
echo ""

# ============================================================
# ОПРЕДЕЛЕНИЕ ТИПА LUCI
# ============================================================

echo "Определяю тип LuCI..."

HEADER_FILE=""
LUCI_TYPE=""

# Modern LuCI (ucode templates)
if [ -f "/usr/share/ucode/luci/template/themes/bootstrap/header.ut" ]; then
    HEADER_FILE="/usr/share/ucode/luci/template/themes/bootstrap/header.ut"
    LUCI_TYPE="modern"
    echo "  → Современный LuCI (ucode templates)"
# Legacy LuCI (lua templates)
elif [ -f "/usr/lib/lua/luci/view/header.htm" ]; then
    HEADER_FILE="/usr/lib/lua/luci/view/header.htm"
    LUCI_TYPE="legacy"
    echo "  → Старый LuCI (lua templates)"
else
    echo "✗ ERROR: Не могу найти header template!"
    echo ""
    echo "Поиск возможных вариантов..."
    find /usr -name "header.*" -type f 2>/dev/null | head -5
    exit 1
fi

echo "✓ Header найден: $HEADER_FILE"
echo ""

# ============================================================
# ОПРЕДЕЛЕНИЕ КУДА КОПИРОВАТЬ СКРИПТ
# ============================================================

if [ "$LUCI_TYPE" = "modern" ]; then
    SCRIPT_DIR="/www/luci-static/bootstrap"
    SCRIPT_PATH="$SCRIPT_DIR/matrix-vektort13.js"
    SCRIPT_URL="{{ media }}/matrix-vektort13.js"
else
    SCRIPT_DIR="/www/luci-static/resources"
    SCRIPT_PATH="$SCRIPT_DIR/matrix-vektort13.js"
    SCRIPT_URL="/luci-static/resources/matrix-vektort13.js"
fi

# ============================================================
# ПРОВЕРКА УЖЕ УСТАНОВЛЕНО
# ============================================================

if grep -q "MATRIX VEKTORT13" "$HEADER_FILE" 2>/dev/null; then
    echo "⚠️  Matrix уже установлен!"
    echo ""
    printf "Переустановить? (y/N): "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Отменено."
        exit 0
    fi
    echo ""
fi

# ============================================================
# УСТАНОВКА
# ============================================================

BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  УСТАНОВКА                                             ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# [1/4] Backup
echo "[1/4] Создаю бэкап..."
cp "$HEADER_FILE" "${HEADER_FILE}${BACKUP_SUFFIX}"
echo "  ✓ $HEADER_FILE → ${HEADER_FILE}${BACKUP_SUFFIX}"
echo ""

# [2/4] Copy script
echo "[2/4] Копирую Matrix скрипт..."
mkdir -p "$SCRIPT_DIR"
cp "./matrix-v6-LUCI-INTEGRATION.js" "$SCRIPT_PATH"
chmod 644 "$SCRIPT_PATH"
echo "  ✓ $SCRIPT_PATH"
echo ""

# [3/4] Inject into header
echo "[3/4] Инжектирую в header..."

# Remove old injection if exists
sed -i '/<!-- MATRIX VEKTORT13 START -->/,/<!-- MATRIX VEKTORT13 END -->/d' "$HEADER_FILE"

# Find </head> line number
HEAD_LINE=$(grep -n "</head>" "$HEADER_FILE" | head -1 | cut -d: -f1)

if [ -z "$HEAD_LINE" ]; then
    echo "✗ ERROR: Не могу найти </head> в header!"
    echo "Восстанавливаю бэкап..."
    cp "${HEADER_FILE}${BACKUP_SUFFIX}" "$HEADER_FILE"
    exit 1
fi

# Inject BEFORE </head> using line insert
if [ "$LUCI_TYPE" = "modern" ]; then
    # Modern LuCI: preserve indentation and use ucode variables
    sed -i "${HEAD_LINE}i\\                <!-- MATRIX VEKTORT13 START -->" "$HEADER_FILE"
    HEAD_LINE=$((HEAD_LINE + 1))
    sed -i "${HEAD_LINE}i\\                <script src=\"{{ media }}/matrix-vektort13.js?v={{ time() }}\" defer></script>" "$HEADER_FILE"
    HEAD_LINE=$((HEAD_LINE + 1))
    sed -i "${HEAD_LINE}i\\                <!-- MATRIX VEKTORT13 END -->" "$HEADER_FILE"
else
    # Legacy LuCI: simple injection
    sed -i "${HEAD_LINE}i\\<!-- MATRIX VEKTORT13 START -->" "$HEADER_FILE"
    HEAD_LINE=$((HEAD_LINE + 1))
    sed -i "${HEAD_LINE}i\\<script src=\"$SCRIPT_URL?v=$(date +%s)\" defer></script>" "$HEADER_FILE"
    HEAD_LINE=$((HEAD_LINE + 1))
    sed -i "${HEAD_LINE}i\\<!-- MATRIX VEKTORT13 END -->" "$HEADER_FILE"
fi

echo "  ✓ Инжектировано в $HEADER_FILE"
echo ""

# [4/4] Restart
echo "[4/4] Перезапускаю веб-сервер..."
if /etc/init.d/uhttpd restart >/dev/null 2>&1; then
    echo "  ✓ uhttpd перезапущен"
else
    echo "  ⚠️  Ошибка перезапуска, попробуй вручную:"
    echo "     /etc/init.d/uhttpd restart"
fi

echo ""

# ============================================================
# УСПЕХ
# ============================================================

echo "╔════════════════════════════════════════════════════════╗"
echo "║  ✅ УСТАНОВКА ЗАВЕРШЕНА!                               ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "📦 Что установлено:"
echo "  • Matrix скрипт: $SCRIPT_PATH"
echo "  • Инжектировано в: $HEADER_FILE"
echo "  • Бэкап: ${HEADER_FILE}${BACKUP_SUFFIX}"
echo ""
echo "🎬 Как использовать:"
echo "  1. Открой веб-интерфейс роутера"
echo "  2. Наслаждайся Matrix анимацией!"
echo "  3. Кнопка 'MATRIX OFF' справа внизу - отключить"
echo "  4. Настройка сохраняется в браузере"
echo ""
echo "💡 Советы:"
echo "  • Очисти кэш браузера: Ctrl+Shift+R"
echo "  • Проверь консоль браузера: F12"
echo ""
echo "🗑️  Удаление:"
echo "  • Восстанови бэкап:"
echo "    cp ${HEADER_FILE}${BACKUP_SUFFIX} $HEADER_FILE"
echo "    /etc/init.d/uhttpd restart"
echo ""

# ============================================================
# ОПРЕДЕЛЕНИЕ IP
# ============================================================

ROUTER_IP=""

# Try uci
if command -v uci >/dev/null 2>&1; then
    ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null)
fi

# Try br-lan
if [ -z "$ROUTER_IP" ]; then
    ROUTER_IP=$(ip -4 -o addr show br-lan 2>/dev/null | awk '/inet /{print $4; exit}' | cut -d/ -f1)
fi

# Try default route interface (works across non-eth0 devices)
if [ -z "$ROUTER_IP" ]; then
    WAN_DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$WAN_DEV" ]; then
        ROUTER_IP=$(ip -4 -o addr show "$WAN_DEV" 2>/dev/null | awk '/inet /{print $4; exit}' | cut -d/ -f1)
    fi
    
    # If private IP, try to get external
    if [ -n "$ROUTER_IP" ] && echo "$ROUTER_IP" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
        EXTERNAL_IP=$(curl -s --max-time 3 https://ifconfig.me/ip 2>/dev/null || curl -s --max-time 3 https://icanhazip.com 2>/dev/null)
        if [ -n "$EXTERNAL_IP" ]; then
            ROUTER_IP="$EXTERNAL_IP"
        fi
    fi
fi

# Show URL
echo "╔════════════════════════════════════════════════════════╗"
if [ -n "$ROUTER_IP" ]; then
    echo "║  🌐 http(s)://$ROUTER_IP"
else
    echo "║  🌐 http(s)://YOUR-ROUTER-IP"
fi
echo "╚════════════════════════════════════════════════════════╝"
echo ""
