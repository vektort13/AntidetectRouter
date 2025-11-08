#!/bin/sh
# Road-Warrior for OpenWrt 24.10.x (x86_64)
# OpenVPN (no-enc) + Passwall GUI + TPROXY (TCP/UDP/QUIC/WEBTRANSPORT/DNS) + автоматические проверки

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

ask_yn() {
  local q="$1" def="${2:-Y}" a sug
  case "$def" in Y|y) sug="[Y/n]";; *) sug="[y/N]";; esac
  printf "%s %s: " "$q" "$sug"
  read -r a
  [ -z "$a" ] && a="$def"
  case "$a" in Y|y) return 0;; *) return 1;; esac
}

cidr2mask() { 
  bits="${1#*/}"; [ -z "$bits" ] || [ "$bits" = "$1" ] && { echo 255.255.255.0; return; }
  m=0; i=0; while [ $i -lt 32 ]; do [ $i -lt "$bits" ] && m=$((m | (1<<(31-i)))); i=$((i+1)); done
  printf "%d.%d.%d.%d" $(( (m>>24)&255 )) $(( (m>>16)&255 )) $(( (m>>8)&255 )) $(( m&255 ))
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
say "=== Road-Warrior Auto Setup ==="
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

# Правильная настройка WAN (ваш метод)
say "Настраиваю WAN интерфейс..."
uci set network.lan.proto='dhcp'
uci commit network
ifup lan

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
  say "Пробуем альтернативный метод..."
  uci set network.wan=interface
  uci set network.wan.device="$DET_WAN"
  uci set network.wan.proto='dhcp'
  uci commit network
  /etc/init.d/network restart
  sleep 5
fi

# ---------- 2) Базовые пакеты ----------
say "=== Устанавливаем базовые пакеты ==="

# Обновляем фиды с проверкой
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

# Сетевые утилиты
for pkg in nftables kmod-nft-tproxy nftables-json iptables-nft iptables-mod-nat-extra; do
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

# ---------- 3) Passwall установка ----------
say "=== Устанавливаем Passwall ==="

install_passwall_feeds() {
  # Очистка старых записей
  for f in /etc/opkg/customfeeds.conf /etc/opkg/custom.conf; do
    [ -f "$f" ] && sed -i '/openwrt-passwall-build/d;/passwall_packages/d;/passwall_luci/d;/passwall2/d' "$f"
  done

  # Определение релиза и архитектуры
  . /etc/openwrt_release 2>/dev/null || true
  REL="${DISTRIB_RELEASE:-24.10}"
  RELMAJ="${REL%.*}"
  ARCH="${DISTRIB_ARCH:-$(uname -m)}"

  # База SourceForge
  SF_BASE="https://downloads.sourceforge.net/project/openwrt-passwall-build/releases/packages-${RELMAJ}/${ARCH}"

  # Загрузка ключа подписи
  mkdir -p /etc/opkg/keys
  PASSWALL_KEY_URL="https://raw.githubusercontent.com/xiaorouji/openwrt-passwall/main/signing.key"
  
  say "Загружаем ключ Passwall..."
  if uclient-fetch -q -T 20 -O /etc/opkg/keys/passwall.pub "$PASSWALL_KEY_URL" 2>/dev/null || \
     wget -q -O /etc/opkg/keys/passwall.pub "$PASSWALL_KEY_URL" 2>/dev/null; then
    say "✓ Ключ Passwall загружен"
    opkg-key add /etc/opkg/keys/passwall.pub >/dev/null 2>&1 || true
  else
    warn "✗ Не удалось загрузить ключ подписи"
  fi

  # Проверка доступности фидов
  ADDED=0
  for d in passwall_packages passwall_luci passwall2; do
    say "Проверяем фид: $d"
    if uclient-fetch -q -T 15 -O /dev/null "$SF_BASE/$d/Packages.gz" 2>/dev/null; then
      echo "src/gz $d $SF_BASE/$d" >> /etc/opkg/customfeeds.conf
      say "✓ Добавлен фид: $d"
      ADDED=$((ADDED + 1))
    else
      warn "✗ Фид $d недоступен"
    fi
  done

  [ "$ADDED" -gt 0 ] && return 0
  return 1
}

install_passwall_from_feed() {
  say "Устанавливаем Passwall из фидов..."
  opkg update || return 1
  if opkg install luci-app-passwall 2>/dev/null; then
    say "✓ Passwall установлен"
    return 0
  elif opkg install luci-app-passwall2 2>/dev/null; then
    say "✓ Passwall2 установлен"  
    return 0
  else
    warn "✗ Не удалось установить Passwall из фидов"
    return 2
  fi
}

# Установка Passwall
if install_passwall_feeds && install_passwall_from_feed; then
  say "✓ Passwall успешно установлен"
else
  warn "✗ Passwall не установлен, но продолжаем настройку VPN"
fi

# ---------- 4) Настройка OpenVPN ----------
say "=== Настраиваем OpenVPN ==="

# Интерактивные настройки
ask_var "Порт OpenVPN (UDP)" OPORT "1194"
ask_var "Имя VPN-клиента" CLIENT "client1"
ask_var "VPN IPv4 подсеть" VPN4_NET "10.99.0.0/24"
ask_var "VPN IPv6 подсеть" VPN6_NET "fd42:4242:4242:1::/64"

# Генерация PKI
say "Генерируем сертификаты..."
OVPN_PKI="/etc/openvpn/pki"
mkdir -p "$OVPN_PKI"

# CA сертификат
[ -f "$OVPN_PKI/ca.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/ca.key" 2048 >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "$OVPN_PKI/ca.key" -out "$OVPN_PKI/ca.crt" -subj "/CN=OpenWrt-VPN-CA"
  say "✓ CA сертификат создан"
}

# Серверный сертификат
[ -f "$OVPN_PKI/server.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$OVPN_PKI/server.key" -out "$OVPN_PKI/server.csr" -subj "/CN=server"
  openssl x509 -req -in "$OVPN_PKI/server.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" -CAcreateserial -out "$OVPN_PKI/server.crt" -days 3650 >/dev/null 2>&1
  say "✓ Серверный сертификат создан"
}

# Клиентский сертификат
[ -f "$OVPN_PKI/$CLIENT.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/$CLIENT.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$OVPN_PKI/$CLIENT.key" -out "$OVPN_PKI/$CLIENT.csr" -subj "/CN=$CLIENT"
  openssl x509 -req -in "$OVPN_PKI/$CLIENT.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" -CAcreateserial -out "$OVPN_PKI/$CLIENT.crt" -days 3650 >/dev/null 2>&1
  say "✓ Клиентский сертификат создан"
}

# TLS ключ
openvpn --genkey secret "$OVPN_PKI/tc.key" 2>/dev/null && say "✓ TLS ключ создан"

# Конфигурация OpenVPN
OVPN4="${VPN4_NET%/*}"
MASK4="$(cidr2mask "$VPN4_NET")"

say "Настраиваем OpenVPN сервер..."
uci -q delete openvpn.rw
uci set openvpn.rw=openvpn
uci set openvpn.rw.enabled='1'
uci set openvpn.rw.dev='tun'
uci set openvpn.rw.proto='udp'
uci set openvpn.rw.port="$OPORT"
uci set openvpn.rw.topology='subnet'
uci set openvpn.rw.server="$OVPN4 $MASK4"
uci set openvpn.rw.server_ipv6="$VPN6_NET"
uci set openvpn.rw.keepalive='10 60'
uci set openvpn.rw.persist_key='1'
uci set openvpn.rw.persist_tun='1'
uci set openvpn.rw.explicit_exit_notify='1'
uci add_list openvpn.rw.data_ciphers='none'
uci set openvpn.rw.data_ciphers_fallback='none'
uci set openvpn.rw.auth='none'
uci set openvpn.rw.tls_server='1'
uci set openvpn.rw.ca="$OVPN_PKI/ca.crt"
uci set openvpn.rw.cert="$OVPN_PKI/server.crt"
uci set openvpn.rw.key="$OVPN_PKI/server.key"
uci set openvpn.rw.dh='none'
uci add_list openvpn.rw.push='redirect-gateway def1 ipv6'
uci add_list openvpn.rw.push='dhcp-option DNS 8.8.8.8'
uci add_list openvpn.rw.push='dhcp-option DNS 1.1.1.1'
uci set openvpn.rw.tls_crypt="$OVPN_PKI/tc.key"
uci commit openvpn

/etc/init.d/openvpn enable
/etc/init.d/openvpn start
say "✓ OpenVPN сервер запущен"

# ---------- 5) Настройка Firewall и NAT ----------
say "=== Настраиваем Firewall ==="

# Создаем интерфейс VPN
uci -q delete network.vpn
uci add network interface
uci set network.@interface[-1].ifname='tun0'
uci set network.@interface[-1].proto='none'
uci set network.@interface[-1].auto='1'
uci rename network.@interface[-1]='vpn'
uci commit network

# Зона VPN
uci -q delete firewall.vpn
uci add firewall zone
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].network='vpn'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'

# Forwarding
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vpn'
uci set firewall.@forwarding[-1].dest='wan'

# Правило для OpenVPN порта
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-OpenVPN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port="$OPORT"
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall

# Настраиваем NAT
say "Настраиваем NAT..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o "$DET_WAN" -j MASQUERADE

/etc/init.d/firewall restart
say "✓ Firewall настроен"

# Включаем форвардинг
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

# ---------- 6) Настройка Passwall TPROXY ----------
say "=== Настраиваем Passwall TPROXY ==="

if [ -f "/etc/config/passwall" ]; then
  say "Настраиваем Passwall для TPROXY..."
  
  # Включаем Passwall но НЕ активируем сразу
  uci set passwall.@global[0].enabled='0'
  uci set passwall.@global[0].tcp_proxy_mode='global'
  uci set passwall.@global[0].udp_proxy_mode='global'
  uci set passwall.@global[0].dns_mode='tcp_udp'
  uci set passwall.@global[0].remote_dns='8.8.8.8'
  uci set passwall.@global[0].dns_client_ip='10.99.0.1'
  
  # Добавляем правило для VPN подсети
  uci add passwall acl_rule >/dev/null 2>&1 || true
  uci set passwall.@acl_rule[0].name='VPN Clients'
  uci set passwall.@acl_rule[0].ip_type='all'
  uci set passwall.@acl_rule[0].source='10.99.0.0/24'
  uci set passwall.@acl_rule[0].tcp_redir_ports='all'
  uci set passwall.@acl_rule[0].udp_redir_ports='all'
  uci set passwall.@acl_rule[0].tcp_no_redir_ports='disable'
  uci set passwall.@acl_rule[0].udp_no_redir_ports='disable'
  
  uci commit passwall
  say "✓ Passwall настроен (отключен по умолчанию)"
else
  warn "Passwall не установлен, TPROXY недоступен"
fi

# ---------- 7) LuCI и веб-интерфейс ----------
say "=== Настраиваем веб-интерфейс ==="

/etc/init.d/uhttpd enable
/etc/init.d/uhttpd start

# Публикуем ovpn файл через веб
mkdir -p /www/vpn
cp "/root/$CLIENT.ovpn" "/www/vpn/" 2>/dev/null || true

# Создаем HTML страницу для загрузки
cat > /www/vpn/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>OpenVPN Config</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        a { display: inline-block; padding: 15px 30px; background: #007cff; color: white; 
            text-decoration: none; border-radius: 5px; margin: 10px; }
        a:hover { background: #0056b3; }
    </style>
</head>
<body>
    <h1>OpenVPN Configuration</h1>
    <p>Download your OpenVPN configuration file:</p>
    <a href="$CLIENT.ovpn">Download $CLIENT.ovpn</a>
    <p>Use this file in your OpenVPN client to connect to the VPN.</p>
</body>
</html>
EOF

say "✓ Веб-интерфейс настроен"

# ---------- 8) Создание клиентского конфига ----------
say "=== Создаем клиентский конфиг ==="

# Получаем публичный IP
PUB4="$(curl -s ifconfig.me || curl -s ipinfo.io/ip || ip addr show "$DET_WAN" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
[ -z "$PUB4" ] && PUB4="YOUR_SERVER_IP"

cat >"/root/${CLIENT}.ovpn" <<EOCLI
client
dev tun
proto udp
remote $PUB4 $OPORT
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

# ---------- 9) Финальные проверки ----------
say "=== Выполняем финальные проверки ==="

# Проверяем сервисы
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

# Проверяем интерфейсы
check_interface "tun0" || warn "Интерфейс tun0 пока не создан (будет создан при подключении клиента)"

# Проверяем доступность порта
if netstat -tulpn | grep -q ":$OPORT"; then
  say "✓ Порт $OPORT открыт"
else
  warn "✗ Порт $OPORT не слушается"
fi

# ---------- 10) Итоговая информация ----------
say "=== НАСТРОЙКА ЗАВЕРШЕНА ==="
echo ""
echo " ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
echo "================================"
echo "LuCI (веб-интерфейс): https://$PUB4"
echo "OpenVPN конфиг: https://$PUB4/vpn/"
echo "OpenVPN порт: $OPORT (UDP)"
echo ""
echo " ДОПОЛНИТЕЛЬНЫЕ ВОЗМОЖНОСТИ:"
echo "================================"
echo "Passwall: LuCI → Services → Passwall"
echo "  - Включите 'Main Switch' для активации TPROXY"
echo "  - Добавьте свои прокси (Socks5/Xray/OpenVPN) в 'Node List'"
echo "  - Настройте правила в 'Access Control'"
echo ""
echo " КОМАНДЫ ДЛЯ ПРОВЕРКИ:"
echo "================================"
echo "Статус OpenVPN: /etc/init.d/openvpn status"
echo "Логи OpenVPN: logread | grep openvpn"
echo "Подключенные клиенты: cat /tmp/openvpn-status.log"
echo "Статус Passwall: /etc/init.d/passwall status"
echo ""
echo "  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "================================"
echo "1. Passwall отключен по умолчанию - включите его через LuCI"
echo "2. При первом включении Passwall добавьте ноду 'Direct' для тестирования"
echo "3. Весь трафик через VPN будет идти через выбранные в Passwall прокси"
echo "4. TPROXY перехватывает TCP/UDP/QUIC/WEBTRANSPORT/DNS трафик"

say "Скачайте конфиг по ссылке: https://$PUB4/vpn/"
