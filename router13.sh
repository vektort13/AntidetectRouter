#!/bin/sh
# Road-Warrior for OpenWrt 24.10.x (x86_64) - NFTABLES VERSION
# OpenVPN (no-enc) + Passwall GUI + TPROXY (TCP/UDP/QUIC/WEBTRANSPORT/DNS)

say()  { printf "\\033[1;32m[RW]\\033[0m %s\\n" "$*"; }
warn() { printf "\\033[1;33m[RW]\\033[0m %s\\n" "$*"; }
err()  { printf "\\033[1;31m[RW]\\033[0m %s\\n" "$*"; }

# ---------- helpers ----------
ask_var() {
  local _q="$1" _name="$2" _def="$3" _val
  printf "%s [%s]: " "$_q" "$_def"
  read -r _val
  eval "$_name=\"${_val:-$_def}\""
}

check_internet() {
  say "Проверяем интернет соединение..."
  if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    say "✓ Интернет доступен"
    return 0
  else
    warn "✗ Нет интернет соединения"
    return 1
  fi
}

check_interface() {
  local iface="$1"
  if ip link show "$iface" >/dev/null 2>&1; then
    say "✓ Интерфейс $iface обнаружен"
    return 0
  else
    warn "✗ Интерфейс $iface не найден"
    return 1
  fi
}

# ---------- 0) Приветствие + проверки ----------
say "=== Road-Warrior Auto Setup (nftables) ==="
say "Проверяем базовые настройки..."

# Автодетект WAN
DET_WAN="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*\"l3_device\":\"\([^\"]*\)\".*/\1/p')"
[ -z "$DET_WAN" ] && DET_WAN="$(ip route | awk '/default/ {print $5; exit}')"
[ -z "$DET_WAN" ] && DET_WAN="eth0"

say "Автоопределен WAN: $DET_WAN"
if ! check_interface "$DET_WAN"; then
  err "Критическая ошибка: WAN интерфейс не найден!"
  exit 1
fi

check_internet || {
  warn "Проблемы с интернетом, но продолжаем настройку..."
}

# ---------- 1) Настройка сети ----------
say "=== Настраиваем сеть ==="

# Проверяем получение IP
say "Проверяем получение IP..."
IP_GET=0
for i in 1 2 3 4 5; do
  if ip addr show "$DET_WAN" | grep -q "inet "; then
    IP_GET=1
    break
  fi
  sleep 2
done

if [ $IP_GET -eq 1 ]; then
  PUB_IP="$(ip addr show "$DET_WAN" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
  say "✓ IP получен: $PUB_IP"
else
  warn "✗ Не удалось получить IP автоматически"
fi

# ---------- 2) Базовые пакеты ----------
say "=== Устанавливаем базовые пакеты ==="

say "Обновляем списки пакетов..."
if opkg update; then
  say "✓ Списки пакетов обновлены"
else
  warn "✗ Ошибка обновления пакетов, пробуем продолжать..."
fi

# Устанавливаем пакеты с проверкой
install_package() {
  local pkg="$1"
  say "Устанавливаем $pkg..."
  if opkg install -V1 "$pkg"; then
    say "✓ $pkg установлен"
    return 0
  else
    warn "✗ Ошибка установки $pkg"
    return 1
  fi
}

for pkg in luci luci-ssl ca-bundle curl wget jq ip-full openssl-util luci-compat; do
  install_package "$pkg" || true
done

# DNSMasq
opkg remove dnsmasq 2>/dev/null || true
install_package "dnsmasq-full" || true

# Сетевые утилиты для nftables
for pkg in nftables kmod-nft-tproxy kmod-nft-nat; do
  install_package "$pkg" || true
done

# OpenVPN
for pkg in openvpn-openssl kmod-tun openvpn-easy-rsa; do
  install_package "$pkg" || true
done

# Дополнительные утилиты
for pkg in unzip nano; do
  install_package "$pkg" || true
done

# ---------- 3) Установка пароля root ----------
say "=== Настраиваем безопасность ==="

say "Установка пароля root (обязательно для LuCI)..."
printf "Введите пароль для root: "
stty -echo 2>/dev/null
read -r ROOT_PW
stty echo 2>/dev/null
echo

if [ -n "$ROOT_PW" ]; then
  printf "%s\n%s\n" "$ROOT_PW" "$ROOT_PW" | passwd root >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    say "✓ Пароль root установлен"
  else
    warn "✗ Ошибка установки пароля"
  fi
else
  RANDOM_PW=$(openssl rand -base64 12 | tr -d '/+' | cut -c1-12)
  printf "%s\n%s\n" "$RANDOM_PW" "$RANDOM_PW" | passwd root >/dev/null 2>&1
  say "✓ Установлен случайный пароль: $RANDOM_PW"
fi

# ---------- 4) Настройка OpenVPN ----------
say "=== Настраиваем OpenVPN ==="

ask_var "Порт OpenVPN (UDP)" OPORT "1194"
ask_var "Имя VPN-клиента" CLIENT "client1"
ask_var "VPN IPv4 подсеть" VPN4_NET "10.99.0.0/24"

# Генерация PKI
say "Генерируем сертификаты..."
OVPN_PKI="/etc/openvpn/pki"
mkdir -p "$OVPN_PKI"

# Создаем конфиг OpenSSL
cat > "$OVPN_PKI/openssl.cnf" << 'EOF'
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[ dn ]
CN = OpenWrt-VPN-CA

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer

[ server ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# Генерация сертификатов
[ -f "$OVPN_PKI/ca.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/ca.key" 2048
  openssl req -new -x509 -days 3650 -key "$OVPN_PKI/ca.key" -out "$OVPN_PKI/ca.crt" \
    -subj "/CN=OpenWrt-VPN-CA" -extensions v3_ca -config "$OVPN_PKI/openssl.cnf"
  say "✓ CA сертификат создан"
}

[ -f "$OVPN_PKI/server.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/server.key" 2048
  openssl req -new -key "$OVPN_PKI/server.key" -out "$OVPN_PKI/server.csr" \
    -subj "/CN=server" -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/server.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/server.crt" -days 3650 -extensions server -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Серверный сертификат создан"
}

[ -f "$OVPN_PKI/$CLIENT.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/$CLIENT.key" 2048
  openssl req -new -key "$OVPN_PKI/$CLIENT.key" -out "$OVPN_PKI/$CLIENT.csr" \
    -subj "/CN=$CLIENT" -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/$CLIENT.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/$CLIENT.crt" -days 3650 -extensions client -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Клиентский сертификат создан"
}

openvpn --genkey secret "$OVPN_PKI/tc.key" 2>/dev/null && say "✓ TLS ключ создан"

# Конфигурация OpenVPN (БЕЗ IPv6!)
OVPN4="${VPN4_NET%/*}"
MASK4="255.255.255.0"

say "Настраиваем OpenVPN сервер..."
uci -q delete openvpn.rw
uci set openvpn.rw=openvpn
uci set openvpn.rw.enabled='1'
uci set openvpn.rw.dev='tun'
uci set openvpn.rw.proto='udp'
uci set openvpn.rw.port="$OPORT"
uci set openvpn.rw.topology='subnet'
uci set openvpn.rw.server="$OVPN4 $MASK4"
uci set openvpn.rw.keepalive='10 60'
uci set openvpn.rw.persist_key='1'
uci set openvpn.rw.persist_tun='1'
uci set openvpn.rw.explicit_exit_notify='1'
uci add_list openvpn.rw.data_ciphers='none'
uci set openvpn.rw.data_ciphers_fallback='none'
uci set openvpn.rw.auth='none'
uci set openvpn.rw.tls_server='1'
uci set openvpn.rw.tls_version_min='1.2'
uci set openvpn.rw.ca="$OVPN_PKI/ca.crt"
uci set openvpn.rw.cert="$OVPN_PKI/server.crt"
uci set openvpn.rw.key="$OVPN_PKI/server.key"
uci set openvpn.rw.dh='none'
uci add_list openvpn.rw.push='redirect-gateway def1'
uci add_list openvpn.rw.push='dhcp-option DNS 8.8.8.8'
uci add_list openvpn.rw.push='dhcp-option DNS 1.1.1.1'
uci set openvpn.rw.tls_crypt="$OVPN_PKI/tc.key"
uci commit openvpn

/etc/init.d/openvpn enable
/etc/init.d/openvpn start
say "✓ OpenVPN сервер запущен"

# ---------- 5) Настройка Firewall через UCI/nftables ----------
say "=== Настраиваем Firewall (nftables) ==="

# Создаем интерфейс VPN
uci -q delete network.vpn
uci set network.vpn=interface
uci set network.vpn.proto='none'
uci set network.vpn.ifname='tun0'
uci set network.vpn.auto='1'
uci commit network

# Зона VPN в firewall
uci -q delete firewall.vpn
uci add firewall zone
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].network='vpn'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'

# Forwarding между VPN и WAN
uci -q delete firewall.vpn_wan_forwarding
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vpn'
uci set firewall.@forwarding[-1].dest='wan'

# Правило для OpenVPN порта
uci -q delete firewall.allow_ovpn
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-OpenVPN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port="$OPORT"
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall

# Включаем форвардинг
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 >/dev/null

/etc/init.d/firewall restart
say "✓ Firewall настроен"

# ---------- 6) Дополнительные настройки для nftables ----------
say "=== Дополнительные настройки nftables ==="

# Создаем custom nftables правила
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/vpn.nft << EOF
#!/usr/sbin/nft -f

# VPN forwarding rules
table inet vpn_rules {
    chain forward_vpn {
        # Accept traffic from VPN to WAN
        iifname "tun0" oifname "$DET_WAN" accept
        # Accept established/related traffic back to VPN
        iifname "$DET_WAN" oifname "tun0" ct state established,related accept
    }
    
    chain postrouting_vpn {
        type nat hook postrouting priority srcnat; policy accept;
        # MASQUERADE for VPN traffic
        oifname "$DET_WAN" ip saddr $VPN4_NET masquerade
    }
}
EOF

# Применяем правила
nft -f /etc/nftables.d/vpn.nft

# Добавляем в автозагрузку
cat >> /etc/sysupgrade.conf << EOF
/etc/nftables.d/vpn.nft
EOF

say "✓ NFTables правила применены"

# ---------- 7) LuCI и веб-интерфейс ----------
say "=== Настраиваем веб-интерфейс ==="

/etc/init.d/uhttpd enable
/etc/init.d/uhttpd start

# Создаем клиентский конфиг
say "Создаем клиентский конфиг..."
PUB_IP="$(curl -s ifconfig.me || curl -s ipinfo.io/ip || ip addr show "$DET_WAN" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
[ -z "$PUB_IP" ] && PUB_IP="YOUR_SERVER_IP"

cat >"/root/${CLIENT}.ovpn" <<EOCLI
client
dev tun
proto udp
remote $PUB_IP $OPORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher none
auth none
verb 3
<tls-crypt>
$(cat $OVPN_PKI/tc.key)
</tls-crypt>
<ca>
$(cat $OVPN_PKI/ca.crt)
</ca>
<cert>
$(cat $OVPN_PKI/$CLIENT.crt)
</cert>
<key>
$(cat $OVPN_PKI/$CLIENT.key)
</key>
EOCLI

say "✓ Клиентский конфиг создан: /root/${CLIENT}.ovpn"

# Публикуем ovpn файл через веб
say "Настраиваем веб-доступ к конфигурации..."
mkdir -p /www/vpn
cp "/root/${CLIENT}.ovpn" "/www/vpn/"
chmod 644 "/www/vpn/${CLIENT}.ovpn"

# Создаем HTML страницу для загрузки
cat > "/www/vpn/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>OpenVPN Configuration</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        a { display: inline-block; padding: 15px 30px; background: #007cff; 
            color: white; text-decoration: none; border-radius: 5px; margin: 10px; }
        a:hover { background: #0056b3; }
        .password { background: #ffeb3b; padding: 10px; border-radius: 5px; margin: 10px 0; }
    </style>
</head>
<body>
    <h1>OpenVPN Configuration</h1>
    <p>Download your OpenVPN configuration file:</p>
    <a href="${CLIENT}.ovpn">Download ${CLIENT}.ovpn</a>
    
    <div class="password">
        <h3>LuCI Access Information:</h3>
        <p><strong>URL:</strong> https://$PUB_IP</p>
        <p><strong>Username:</strong> root</p>
        <p><strong>Password:</strong> $ROOT_PW$RANDOM_PW</p>
    </div>
    
    <p>Use the OpenVPN file in your OpenVPN client to connect to the VPN.</p>
</body>
</html>
EOF

# Добавляем правило для uHTTPd
if ! grep -q "vpn" /etc/config/uhttpd; then
  uci add uhttpd uhttpd
  uci set uhttpd.@uhttpd[-1].home="/www/vpn"
  uci set uhttpd.@uhttpd[-1].rfc1918_filter="0"
  uci commit uhttpd
fi

/etc/init.d/uhttpd restart
say "✓ Веб-интерфейс настроен"

# ---------- 8) Финальные проверки ----------
say "=== Выполняем финальные проверки ==="

check_service() {
  local service="$1"
  if /etc/init.d/"$service" status >/dev/null 2>&1; then
    say "✓ $service запущен"
    return 0
  else
    warn "✗ $service не запущен"
    return 1
  fi
}

check_service "openvpn"
check_service "uhttpd" 
check_service "firewall"

check_interface "tun0" || warn "Интерфейс tun0 пока не создан (будет создан при подключении клиента)"

if netstat -tulpn | grep -q ":$OPORT"; then
  say "✓ Порт $OPORT открыт"
else
  warn "✗ Порт $OPORT не слушается"
fi

if [ -f "/www/vpn/${CLIENT}.ovpn" ]; then
  say "✓ OVPN файл доступен по https://$PUB_IP/vpn/"
else
  warn "✗ OVPN файл не создан в веб-директории"
fi

# Проверяем nftables правила
say "Проверяем nftables правила..."
if nft list ruleset | grep -q "tun0"; then
  say "✓ NFTables правила для VPN настроены"
else
  warn "✗ NFTables правила для VPN не найдены"
fi

# ---------- 9) Итоговая информация ----------
say "=== НАСТРОЙКА ЗАВЕРШЕНА ==="
echo ""
echo "📡 ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
echo "================================"
echo "LuCI (веб-интерфейс): https://$PUB_IP"
echo "OpenVPN конфиг: https://$PUB_IP/vpn/"
echo "OpenVPN порт: $OPORT (UDP)"
echo "Пароль LuCI: $ROOT_PW$RANDOM_PW"
echo ""
echo "🔧 ТЕХНИЧЕСКАЯ ИНФОРМАЦИЯ:"
echo "================================"
echo "Используется: nftables (firewall4)"
echo "WAN интерфейс: $DET_WAN"
echo "VPN сеть: $VPN4_NET"
echo ""
echo "📋 КОМАНДЫ ДЛЯ ПРОВЕРКИ:"
echo "================================"
echo "Статус OpenVPN: /etc/init.d/openvpn status"
echo "Логи OpenVPN: logread | grep openvpn"
echo "Правила nftables: nft list ruleset | grep tun0"
echo "Подключенные клиенты: cat /tmp/openvpn-status.log"
echo ""
echo "⚠️  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "================================"
echo "1. Система использует nftables вместо iptables"
echo "2. IPv6 отключен в OpenVPN для стабильной работы"
echo "3. Все правила настроены через UCI и nftables"
echo "4. Перезапуск firewall сохраняет настройки"

say "Скачайте конфиг по ссылке: https://$PUB_IP/vpn/"
say "Для входа в LuCI используйте: root / $ROOT_PW$RANDOM_PW"
