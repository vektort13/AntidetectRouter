#!/bin/sh
# Road-Warrior for OpenWrt (Custom Image VPS)
# LuCI + luci-app-xray + Xray(TPROXY+DNS) + OpenVPN no-enc + IPv6 + TTL
set -e

say()  { printf "\033[1;32m[RW]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[RW]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[RW]\033[0m %s\n" "$*"; }

# -------- 0) Автодетект сети / интерфейсов --------
WAN_IF="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p')"
[ -z "$WAN_IF" ] && WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
[ -z "$WAN_IF" ] && WAN_IF="eth0"

has_v4() { ip -4 addr show dev "$WAN_IF" | grep -q 'inet '; }
has_v6() { ip -6 addr show dev "$WAN_IF" scope global | grep -q 'inet6 '; }

if ! has_v4; then
  warn "IPv4 по DHCP не получен на $WAN_IF — настраиваю WAN=DHCP..."
  uci -q delete network.wan
  uci -q delete network.wan6
  uci set network.wan='interface'
  uci set network.wan.device="$WAN_IF"
  uci set network.wan.proto='dhcp'
  uci commit network
  /etc/init.d/network restart
  sleep 4
fi

# -------- 1) Пакеты --------
say "Устанавливаю пакеты (LuCI, Xray, OpenVPN, nft tproxy, dnsmasq-full, утилиты)"
opkg update
# базовые
opkg install -V1 luci luci-ssl ca-bundle curl jq ip-full
# DNS: заменим dnsmasq на full (если стоял lite)
opkg remove dnsmasq 2>/dev/null || true
opkg install dnsmasq-full
# Xray + GUI
opkg install xray-core xray-geodata 2>/dev/null || true
opkg install luci-app-xray 2>/dev/null || true
if ! opkg list-installed | grep -q '^luci-app-xray'; then
  warn "luci-app-xray в фидах не найден — пробую из релиза GitHub..."
  # универсальный fall-back (может не сработать у некоторых сборок — тогда поставь вручную через LuCI → Software)
  URL="$(curl -fsSL https://api.github.com/repos/yichya/luci-app-xray/releases/latest | jq -r '.assets[]?.browser_download_url' | grep '_all.ipk' | head -n1 || true)"
  if [ -n "$URL" ]; then
    curl -fsSL -o /tmp/luci-app-xray.ipk "$URL"
    opkg install /tmp/luci-app-xray.ipk || warn "Не удалось поставить luci-app-xray из релиза."
  else
    warn "Не смог получить ссылку на релиз luci-app-xray."
  fi
fi
# VPN
opkg install openvpn-openssl easy-rsa
# nft+tproxy
opkg install nftables kmod-nft-tproxy
# (опц.) редактор
opkg install nano 2>/dev/null || true

# -------- 2) Включаем LuCI (HTTPS) --------
say "Включаю LuCI (HTTPS)"
/etc/init.d/uhttpd enable
/etc/init.d/uhttpd start

# -------- 3) Мини‑конфиг Xray: TPROXY inbound + DNS через Xray --------
say "Пишу /etc/xray/config.json (inbound=tproxy:12345 + dns-out; прокси настроишь в GUI)"
mkdir -p /etc/xray /var/log/xray
cat >/etc/xray/config.json <<'JSON'
{
  "log": { "loglevel": "info", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "tag": "tproxy-in",
    "protocol": "dokodemo-door",
    "port": 12345,
    "settings": { "network": "tcp,udp", "followRedirect": true },
    "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "dns-out", "protocol": "dns", "settings": { "address": "8.8.8.8" } }
  ],
  "dns": { "servers": [ "8.8.8.8", "1.1.1.1", "https+local://dns.cloudflare.com/dns-query" ] },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": [ "tproxy-in" ], "port": 53, "outboundTag": "dns-out" }
    ]
  }
}
JSON
/etc/init.d/xray enable
/etc/init.d/xray restart

# -------- 4) Policy routing под TPROXY (fwmark 0x1 -> table 100; v4/v6) --------
say "Policy routing для TPROXY (fwmark 0x1 -> table 100, локальная доставка)"
ip rule add fwmark 0x1 table 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip -6 rule add fwmark 0x1 table 100 2>/dev/null || true
ip -6 route add local ::/0 dev lo table 100 2>/dev/null || true

# -------- 5) nft TPROXY: перехват TCP/UDP+DNS с tun0 на :12345 --------
say "Устанавливаю nft‑правила TPROXY (prerouting на tun0 → :12345)"
cat >/etc/nftables.d/90-xray-tproxy.nft <<'NFT'
table inet xray {
  set v4_skip { type ipv4_addr; flags interval; elements = {
    127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
    169.254.0.0/16, 224.0.0.0/4, 240.0.0.0/4
  } }
  set v6_skip { type ipv6_addr; flags interval; elements = {
    ::1/128, fc00::/7, fe80::/10, ff00::/8
  } }

  chain preroute {
    type filter hook prerouting priority mangle; policy accept;
    # DNS сначала, чтобы не текло
    iifname "tun0" ip protocol udp udp dport 53 tproxy to :12345 meta mark set 0x1
    iifname "tun0" meta l4proto udp udp dport 53 tproxy to :12345 meta mark set 0x1
    # TCP/UDP остальной
    iifname "tun0" ip daddr @v4_skip return
    iifname "tun0" ip protocol { tcp, udp } tproxy to :12345 meta mark set 0x1
    iifname "tun0" ip6 daddr @v6_skip return
    iifname "tun0" meta l4proto { tcp, udp } tproxy to :12345 meta mark set 0x1
  }

  chain accept_mark {
    type filter hook input priority mangle; policy accept;
    meta mark 0x1 accept
  }
}
NFT
nft -f /etc/nftables.d/90-xray-tproxy.nft
/etc/init.d/firewall restart

# -------- 6) OpenVPN сервер (UDP/TUN) без шифрования + PKI + клиент .ovpn --------
say "Генерирую PKI (CA/Server/Client) и настраиваю OpenVPN (UDP/TUN) БЕЗ шифрования"
OPORT="${OPORT:-1194}"
VPN4_NET="${VPN4_NET:-10.99.0.0/24}"
VPN6_NET="${VPN6_NET:-fd42:4242:4242:1::/64}" # ULA для клиентов

OVPN4="$(echo "$VPN4_NET" | cut -d/ -f1)"
MASK4="$(ipcalc.sh $VPN4_NET | awk -F= '/NETMASK/{print $2}')"

[ -d /etc/easy-rsa/pki ] || easyrsa init-pki
[ -f /etc/easy-rsa/pki/ca.crt ] || easyrsa build-ca nopass
[ -f /etc/easy-rsa/pki/issued/server.crt ] || easyrsa build-server-full server nopass
CLIENT="${CLIENT:-client1}"
[ -f /etc/easy-rsa/pki/issued/${CLIENT}.crt ] || easyrsa build-client-full ${CLIENT} nopass

mkdir -p /etc/openvpn/pki
cp -r /etc/easy-rsa/pki/* /etc/openvpn/pki/

# UCI конфиг OpenVPN‑сервера
uci -q delete openvpn.rw
uci set openvpn.rw=openvpn
uci set openvpn.rw.enabled='1'
uci set openvpn.rw.dev='tun0'
uci set openvpn.rw.proto='udp'
uci set openvpn.rw.port="$OPORT"
uci set openvpn.rw.topology='subnet'
uci set openvpn.rw.server="$OVPN4 $MASK4"
uci set openvpn.rw.server_ipv6="$VPN6_NET"
uci set openvpn.rw.keepalive='10 60'
uci set openvpn.rw.persist_key='1'
uci set openvpn.rw.persist_tun='1'
uci set openvpn.rw.explicit_exit_notify='1'
# --- отключаем шифрование/HMAC на data‑channel:
uci add_list openvpn.rw.data_ciphers='none'
uci set openvpn.rw.data_ciphers_fallback='none'
uci set openvpn.rw.auth='none'
# для старых клиентов 2.5 можно: uci set openvpn.rw.ncp_disable='1'
uci set openvpn.rw.tls_server='1'
uci set openvpn.rw.ca='/etc/openvpn/pki/ca.crt'
uci set openvpn.rw.cert='/etc/openvpn/pki/issued/server.crt'
uci set openvpn.rw.key='/etc/openvpn/pki/private/server.key'
uci set openvpn.rw.dh='none'
uci add_list openvpn.rw.push='redirect-gateway def1 ipv6'
uci add_list openvpn.rw.push='dhcp-option DNS 10.99.0.1'
uci add_list openvpn.rw.push='dhcp-option DNS6 fd42:4242:4242:1::1'
uci commit openvpn
/etc/init.d/openvpn enable
/etc/init.d/openvpn restart

# Клиентский профиль .ovpn
PUB4="$(ip -4 addr show dev "$WAN_IF" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
cat >/root/${CLIENT}.ovpn <<EOCLI
client
dev tun
proto udp
remote ${PUB4} ${OPORT}
nobind
persist-key
persist-tun
verb 3
data-ciphers none
data-ciphers-fallback none
auth none
# ncp-disable

<ca>
$(cat /etc/openvpn/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/pki/issued/${CLIENT}.crt)
</cert>
<key>
$(cat /etc/openvpn/pki/private/${CLIENT}.key)
</key>
EOCLI

# -------- 7) Firewall: зона VPN, форвардинг в WAN, NAT/NAT66, порт 1194 --------
say "Правила firewall: зона VPN, форвардинг VPN->WAN, NAT v4/v6, порт 1194/udp"
# интерфейс tun0 как network 'vpn'
uci -q delete network.vpn
uci add network interface
uci set network.@interface[-1].ifname='tun0'
uci set network.@interface[-1].proto='none'
uci set network.@interface[-1].auto='1'
uci rename network.@interface[-1]='vpn'
uci commit network

# зона vpn
uci -q delete firewall.vpn
uci add firewall zone
uci set firewall.@zone[-1].name='vpn'
uci set firewall.@zone[-1].network='vpn'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'

# NAT66 и на WAN
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].masq6='1'

# форвардинг vpn -> wan
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vpn'
uci set firewall.@forwarding[-1].dest='wan'

# правило на вход UDP/1194
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-OpenVPN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port="$OPORT"
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart

# IPv6 forwarding (ядро)
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

# -------- 8) TTL — интерактивный выбор и применение (IPv4 + IPv6) --------
say "TTL‑фикс: выбери режим"
echo " 1) Не менять TTL"
echo " 2) Компенсировать +1 (ttl=ttl+1; hoplimit=+1)"
echo " 3) Зафиксировать конкретный TTL (по умолчанию 127)"
printf "Выбор [1/2/3, по умолчанию 3]: "
read TTLMODE
[ -z "$TTLMODE" ] && TTLMODE=3

TTL_RULE=""
case "$TTLMODE" in
  1) say "TTL не меняем";;
  2) TTL_RULE='ip ttl set ip ttl + 1; ip6 hoplimit set ip6 hoplimit + 1';;
  3) printf "Укажи TTL (Enter = 127): "; read TTLV; [ -z "$TTLV" ] && TTLV=127
     TTL_RULE="ip ttl set ${TTLV}; ip6 hoplimit set ${TTLV}";;
  *) TTL_RULE="ip ttl set 127; ip6 hoplimit set 127";;
esac

if [ -n "$TTL_RULE" ]; then
  say "Применяю TTL/HopLimit на исходящем (${WAN_IF})"
  cat >/etc/nftables.d/95-ttlfix.nft <<NFT2
table inet ttlfix {
  chain post {
    type route hook postrouting priority mangle; policy accept;
    oifname "${WAN_IF}" ${TTL_RULE}
  }
}
NFT2
  nft -f /etc/nftables.d/95-ttlfix.nft
  /etc/init.d/firewall restart
fi

# -------- 9) Вывод итогов --------
say "ГОТОВО!"
IP4="$(ip -4 addr show dev "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
IP6="$(ip -6 addr show dev "$WAN_IF" scope global | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -n1)"
echo "LuCI (HTTPS): https://${IP4}"
[ -n "$IP6" ] && echo "LuCI (IPv6): https://[${IP6}]/"
echo "Xray GUI: LuCI → Services → Xray → добавь свой прокси (Node) и включи Transparent Proxy"
echo "OpenVPN клиентский профиль: /root/${CLIENT}.ovpn  (подключайся OpenVPN GUI 2.5/2.6)"
echo "Логи Xray: /var/log/xray/*.log | nft: nft list ruleset | OpenVPN: logread -e openvpn"
