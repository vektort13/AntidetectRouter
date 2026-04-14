#!/bin/sh
# Road-Warrior for OpenWrt 24.10.x (x86_64)
# OpenVPN (no-enc) + Passwall GUI + TPROXY (TCP/UDP/QUIC/WEBTRANSPORT/DNS) + автоматические проверки

say()  { printf "\\033[1;32m[RW]\\033[0m %s\\n" "$*"; }
warn() { printf "\\033[1;33m[RW]\\033[0m %s\\n" "$*"; }
err()  { printf "\\033[1;31m[RW]\\033[0m %s\\n" "$*"; }

set_named_var() {
  local _name="$1" _value="$2"
  case "$_name" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  export "$_name=$_value"
}

# ---------- helpers ----------
ask_var() {
  local _q="$1" _name="$2" _def="$3" _val
  printf "%s [%s]: " "$_q" "$_def"
  read -r _val || true
  set_named_var "$_name" "${_val:-$_def}" || { err "Internal variable name error: $_name"; exit 1; }
}

ask_valid() {
  local _q="$1" _name="$2" _def="$3" _validator="$4" _error="$5" _val
  while :; do
    printf "%s [%s]: " "$_q" "$_def"
    read -r _val || true
    _val="${_val:-$_def}"
    if "$_validator" "$_val"; then
      set_named_var "$_name" "$_val" || { err "Internal variable name error: $_name"; exit 1; }
      return 0
    fi
    warn "$_error"
  done
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
  local bits m i
  bits="${1#*/}"; [ -z "$bits" ] || [ "$bits" = "$1" ] && { echo 255.255.255.0; return; }
  m=0; i=0; while [ $i -lt 32 ]; do [ $i -lt "$bits" ] && m=$((m | (1<<(31-i)))); i=$((i+1)); done
  printf "%d.%d.%d.%d" $(( (m>>24)&255 )) $(( (m>>16)&255 )) $(( (m>>8)&255 )) $(( m&255 ))
}

ip2int() {
  local IFS=.
  set -- $1
  echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 ))
}

int2ip() {
  local ip="$1"
  printf "%d.%d.%d.%d\n" $(( (ip>>24)&255 )) $(( (ip>>16)&255 )) $(( (ip>>8)&255 )) $(( ip&255 ))
}

first_host_of_cidr() {
  local network="${1%/*}" mask n_int m_int
  mask="$(cidr2mask "$1")"
  n_int="$(ip2int "$network")"
  m_int="$(ip2int "$mask")"
  int2ip $(( (n_int & m_int) + 1 ))
}

detect_network_name_by_device() {
  local dev="$1" section section_dev
  for section in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
    section_dev="$(uci -q get network.$section.device)"
    [ -z "$section_dev" ] && section_dev="$(uci -q get network.$section.ifname)"
    if [ "$section_dev" = "$dev" ]; then
      printf '%s' "$section"
      return 0
    fi
    echo " $section_dev " | grep -q " $dev " && {
      printf '%s' "$section"
      return 0
    }
  done
  return 1
}

detect_firewall_zone_by_network() {
  local net_name="$1" section zone_networks zone_name
  for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
    zone_networks="$(uci -q get firewall.$section.network)"
    echo " $zone_networks " | grep -q " $net_name " || continue
    zone_name="$(uci -q get firewall.$section.name)"
    [ -n "$zone_name" ] && printf '%s' "$zone_name" || printf '%s' "$section"
    return 0
  done
  return 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_port() {
  is_uint "$1" || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_valid_ipv4() {
  local old_ifs="$IFS" octet
  IFS=.
  set -- $1
  IFS="$old_ifs"
  [ $# -eq 4 ] || return 1
  for octet in "$@"; do
    case "$octet" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

is_valid_ipv4_cidr() {
  local network="${1%/*}" bits="${1#*/}"
  [ "$network" != "$1" ] || return 1
  is_valid_ipv4 "$network" || return 1
  is_uint "$bits" || return 1
  [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

is_valid_ipv6_address() {
  case "$1" in
    *:*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    ''|*[!0-9A-Fa-f:]* ) return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_ipv6_cidr() {
  local network="${1%/*}" bits="${1#*/}"
  [ "$network" != "$1" ] || return 1
  is_valid_ipv6_address "$network" || return 1
  is_uint "$bits" || return 1
  [ "$bits" -ge 0 ] && [ "$bits" -le 128 ]
}

sanitize_client_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]//g'
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

have_bin() { command -v "$1" >/dev/null 2>&1; }

generate_random_secret() {
  local secret=""
  if have_bin openssl; then
    secret="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=\r\n' | cut -c1-16)"
  fi
  if [ -z "$secret" ] && [ -r /dev/urandom ] && have_bin od; then
    secret="$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \r\n' | cut -c1-16)"
  fi
  printf '%s' "$secret"
}

package_installed() {
  opkg status "$1" 2>/dev/null | grep -q 'Status: install ok installed'
}

ensure_dnsmasq_full() {
  local had_dnsmasq=0

  if package_installed dnsmasq-full; then
    say "✓ dnsmasq-full уже установлен"
    return 0
  fi

  package_installed dnsmasq && had_dnsmasq=1

  if opkg install dnsmasq-full >/dev/null 2>&1; then
    say "✓ dnsmasq-full установлен"
    return 0
  fi

  if [ "$had_dnsmasq" -eq 1 ]; then
    warn "Прямая установка dnsmasq-full не удалась; пробую заменить dnsmasq с откатом"
    opkg remove dnsmasq >/dev/null 2>&1 || {
      err "Не удалось удалить dnsmasq перед установкой dnsmasq-full"
      exit 1
    }
  fi

  if opkg install dnsmasq-full >/dev/null 2>&1; then
    say "✓ dnsmasq-full установлен"
    return 0
  fi

  if [ "$had_dnsmasq" -eq 1 ] && ! package_installed dnsmasq; then
    opkg install dnsmasq >/dev/null 2>&1 || {
      err "Не удалось восстановить dnsmasq после ошибки установки dnsmasq-full"
      exit 1
    }
    warn "dnsmasq восстановлен после неудачной установки dnsmasq-full"
  fi

  package_installed dnsmasq-full && return 0
  err "dnsmasq-full не установлен; продолжаю с обычным dnsmasq"
  return 1
}

root_has_password() {
  local f
  f="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)"
  [ -n "$f" ] && [ "$f" != "!" ] && [ "$f" != "*" ]
}

cleanup_legacy_web_publish() {
  local section changed=0

  /etc/init.d/vpnlog disable >/dev/null 2>&1 || true
  /etc/init.d/vpnlog stop >/dev/null 2>&1 || true
  rm -f /etc/init.d/vpnlog /usr/sbin/vpn-log-publisher
  rm -f /www/vpn/*.ovpn /www/vpn/index.html /www/vpn/openvpn.log
  rmdir /www/vpn 2>/dev/null || true

  for section in $(uci show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^.]*\)=uhttpd$/\1/p'); do
    if [ "$(uci -q get "uhttpd.$section.home")" = "/www/vpn" ]; then
      uci -q delete "uhttpd.$section"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    uci commit uhttpd >/dev/null 2>&1 || true
  fi
}

# ---------- 0) Приветствие + проверки ----------
say "=== Road-Warrior Auto Setup ==="
say "Проверяем базовые настройки..."

# Автодетект WAN
DET_WAN="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*\"l3_device\":\"\([^\"]*\)\".*/\1/p')"
[ -z "$DET_WAN" ] && DET_WAN="$(ip route | awk '/default/ {print $5; exit}')"

if [ -z "$DET_WAN" ]; then
  err "Критическая ошибка: не удалось определить uplink интерфейс (WAN/default route)."
  exit 1
fi

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

# Правильная настройка WAN
LAN_UPLINK=0
WAN_NETWORK=''
WAN_ZONE='wan'

if ask_yn "Переключить LAN в DHCP-клиент для VPS-сценария?" "Y"; then
  say "Настраиваю LAN интерфейс как uplink..."
  uci set network.lan.proto='dhcp'
  uci commit network
  ifup lan
  LAN_UPLINK=1
  WAN_NETWORK='lan'
else
  say "Оставляю текущую сетевую схему без изменения LAN"
fi

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

if [ "$LAN_UPLINK" -ne 1 ] || [ $IP_GET -ne 1 ]; then
  WAN_NETWORK="$(detect_network_name_by_device "$DET_WAN" || true)"
fi
[ -z "$WAN_NETWORK" ] && WAN_NETWORK='wan'
WAN_ZONE="$(detect_firewall_zone_by_network "$WAN_NETWORK" || true)"
[ -z "$WAN_ZONE" ] && WAN_ZONE="$WAN_NETWORK"
say "Использую uplink network: $WAN_NETWORK (zone: $WAN_ZONE)"

# ---------- 2) Базовые пакеты ----------
say "=== Устанавливаем базовые пакеты ==="

# Обновляем фиды с проверкой
say "Обновляем списки пакетов..."
if opkg update; then
  say "✓ Списки пакетов обновлены"
else
  err "✗ Ошибка обновления пакетов. Остановка, чтобы избежать частичной установки."
  exit 1
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

for pkg in luci luci-ssl ca-bundle curl wget jq ip-full openssl-util luci-compat luci-app-openvpn; do
  install_package "$pkg" || true
done

# DNSMasq
ensure_dnsmasq_full

# Сетевые утилиты
for pkg in nftables kmod-nft-tproxy nftables-json iptables-nft iptables-mod-nat-extra; do
  install_package "$pkg" || true
done

# OpenVPN
for pkg in openvpn-openssl kmod-tun; do
  install_package "$pkg" || true
done

# Дополнительные утилиты
for pkg in unzip nano; do
  install_package "$pkg" || true
done

# ---------- 3) Установка пароля root и Passwall ----------
say "=== Настраиваем безопасность ==="

# Единый UX для root-пароля
say "Установка пароля root (для LuCI тоже)..."
if [ -z "${ROOT_PW:-}" ]; then
  TTY=/dev/tty
  if [ -r "$TTY" ]; then
    printf "Введите пароль для root (Enter = оставить текущий или сгенерировать, если пароля нет): " >"$TTY"
    stty -echo <"$TTY" 2>/dev/null || true
    IFS= read -r ROOT_PW <"$TTY" || ROOT_PW=""
    stty echo <"$TTY" 2>/dev/null || true
    printf "\n" >"$TTY"
  else
    warn "TTY недоступен. Оставляю текущий пароль или сгенерирую новый, если у root его нет."
    ROOT_PW=""
  fi
fi

if [ -n "$ROOT_PW" ]; then
  if printf "%s\n%s\n" "$ROOT_PW" "$ROOT_PW" | passwd root >/dev/null 2>&1; then
    say "✓ Пароль root обновлён"
  else
    err "Не удалось установить пароль root"
    exit 1
  fi
else
  if root_has_password; then
    say "✓ Пароль root уже установлен — оставляю без изменений"
  else
    RANDOM_PW="$(generate_random_secret)"
    [ -n "$RANDOM_PW" ] || {
      err "Не удалось сгенерировать пароль root"
      exit 1
    }
    if printf "%s\n%s\n" "$RANDOM_PW" "$RANDOM_PW" | passwd root >/dev/null 2>&1; then
      printf 'root\n%s\n' "$RANDOM_PW" > /root/roadwarrior-credentials.txt
      chmod 600 /root/roadwarrior-credentials.txt
      say "✓ Пароль root сгенерирован автоматически"
      warn "Учётные данные root сохранены в /root/roadwarrior-credentials.txt"
    else
      err "Не удалось выставить пароль root"
      exit 1
    fi
  fi
fi

# ---------- 4) Passwall установка ----------
say "=== Устанавливаем Passwall ==="
# Ключ подписи именно для сборок на SourceForge
PASSWALL_KEY_URL="https://sourceforge.net/projects/openwrt-passwall-build/files/ipk.pub/download"
mkdir -p /etc/opkg/keys
say "Загружаем ключ Passwall build..."
if uclient-fetch -q -T 20 -O /etc/opkg/keys/ipk.pub "$PASSWALL_KEY_URL" || \
   wget -q -O /etc/opkg/keys/ipk.pub "$PASSWALL_KEY_URL"; then
  opkg-key add /etc/opkg/keys/ipk.pub >/dev/null 2>&1 || true
  say "✓ Ключ добавлен"
else
  warn "✗ Не удалось загрузить ключ подписи (ipk.pub)"
fi

# Чистим старые записи и добавляем фиды под текущий release/arch
PW_RELEASE="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release 2>/dev/null | awk -F. '{print $1"."$2}')"
PW_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2" "$3}' | sort -k2,2n | tail -1 | awk '{print $1}')"
[ -z "$PW_RELEASE" ] && PW_RELEASE="24.10"
[ -z "$PW_ARCH" ] && PW_ARCH="x86_64"

sed -i '/passwall_packages\|passwall_luci\|passwall2/d' /etc/opkg/customfeeds.conf 2>/dev/null
cat >> /etc/opkg/customfeeds.conf <<EOF
src/gz passwall_luci https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall_luci
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall_packages
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall2
EOF
say "✓ Фиды Passwall (${PW_RELEASE}/${PW_ARCH}) добавлены"

# Обновление списков и установка (НЕ прячем stderr, чтобы видеть причину, если будет ошибка)
say "Обновляем индексы opkg..."
opkg update || {
  err "opkg update завершился с ошибкой — проверьте интернет/время/CA"
  exit 1
}

say "Пробуем установить luci-app-passwall..."
if opkg install luci-app-passwall; then
  say "✓ luci-app-passwall установлен"
else
  warn "Не вышло, пробуем luci-app-passwall2..."
  opkg install luci-app-passwall2 && say "✓ luci-app-passwall2 установлен" || \
    warn "✗ Не удалось установить ни luci-app-passwall, ни luci-app-passwall2"
fi
opkg install xray-core >/dev/null 2>&1 || opkg install sing-box >/dev/null 2>&1 || true
# ---------- 5) Настройка OpenVPN с исправленными сертификатами ----------
say "=== Настраиваем OpenVPN ==="

# Интерактивные настройки
ask_valid "Порт OpenVPN (UDP)" OPORT "1194" is_valid_port "Введите числовой порт от 1 до 65535"
ask_var "Имя VPN-клиента" CLIENT "client1"
CLIENT="$(sanitize_client_name "$CLIENT")"
[ -n "$CLIENT" ] || CLIENT="client1"
ask_valid "VPN IPv4 подсеть" VPN4_NET "10.99.0.0/24" is_valid_ipv4_cidr "Введите корректную IPv4 CIDR-подсеть, например 10.99.0.0/24"
ask_valid "VPN IPv6 подсеть" VPN6_NET "fd42:4242:4242:1::/64" is_valid_ipv6_cidr "Введите корректную IPv6 CIDR-подсеть, например fd42:4242:4242:1::/64"

# Генерация PKI с правильными расширениями
say "Генерируем сертификаты с правильными расширениями..."
OVPN_PKI="/etc/openvpn/pki"
mkdir -p "$OVPN_PKI"

# Создаем конфиг OpenSSL с правильными расширениями ключей
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

# CA сертификат с расширениями
[ -f "$OVPN_PKI/ca.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/ca.key" 2048
  openssl req -new -x509 -days 3650 -key "$OVPN_PKI/ca.key" -out "$OVPN_PKI/ca.crt" \
    -subj "/CN=OpenWrt-VPN-CA" -extensions v3_ca -config "$OVPN_PKI/openssl.cnf"
  say "✓ CA сертификат создан"
}

# Серверный сертификат с расширениями
[ -f "$OVPN_PKI/server.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/server.key" 2048
  openssl req -new -key "$OVPN_PKI/server.key" -out "$OVPN_PKI/server.csr" \
    -subj "/CN=server" -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/server.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/server.crt" -days 3650 -extensions server -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Серверный сертификат создан"
}

# Клиентский сертификат с расширениями
[ -f "$OVPN_PKI/$CLIENT.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/$CLIENT.key" 2048
  openssl req -new -key "$OVPN_PKI/$CLIENT.key" -out "$OVPN_PKI/$CLIENT.csr" \
    -subj "/CN=$CLIENT" -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/$CLIENT.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/$CLIENT.crt" -days 3650 -extensions client -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Клиентский сертификат создан"
}

# TLS ключ
[ -f "$OVPN_PKI/tc.key" ] || { openvpn --genkey secret "$OVPN_PKI/tc.key" 2>/dev/null && say "✓ TLS ключ создан"; }

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
uci set openvpn.rw.tls_version_min='1.2'
uci set openvpn.rw.ca="$OVPN_PKI/ca.crt"
uci set openvpn.rw.cert="$OVPN_PKI/server.crt"
uci set openvpn.rw.key="$OVPN_PKI/server.key"
uci set openvpn.rw.dh='none'
uci add_list openvpn.rw.push='redirect-gateway def1'
uci add_list openvpn.rw.push='redirect-gateway ipv6'
SRV_DNS="$(first_host_of_cidr "$VPN4_NET")"
uci add_list openvpn.rw.push="dhcp-option DNS $SRV_DNS"
uci add_list openvpn.rw.push='block-outside-dns'
uci set openvpn.rw.tls_crypt="$OVPN_PKI/tc.key"
uci set openvpn.rw.status='/tmp/openvpn-status.log'
uci set openvpn.rw.log='/tmp/openvpn.log'
uci set openvpn.rw.verb='3'
uci commit openvpn

/etc/init.d/openvpn enable
/etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn start
say "✓ OpenVPN сервер запущен"

# ---------- 6) Настройка Firewall и NAT ----------
say "=== Настраиваем Firewall ==="

# Создаем интерфейс VPN
uci -q delete network.vpn
uci set network.vpn=interface
uci set network.vpn.device='tun0'
uci set network.vpn.proto='none'
uci set network.vpn.auto='1'
uci commit network
/etc/init.d/network reload

# Зона VPN
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
  if [ "$(uci -q get firewall.$section.name)" = "vpn" ]; then
    uci -q delete firewall.$section
  fi
done
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=forwarding$/\1/p'); do
  [ "$(uci -q get firewall.$section.src)" = "vpn" ] || continue
  if [ "$(uci -q get firewall.$section.dest)" = "$WAN_ZONE" ] || [ "$(uci -q get firewall.$section.dest)" = "lan" ] || [ "$(uci -q get firewall.$section.dest)" = "wan" ]; then
    uci -q delete firewall.$section
  fi
done
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=rule$/\1/p'); do
  if [ "$(uci -q get firewall.$section.name)" = "Allow-OpenVPN" ] || [ "$(uci -q get firewall.$section.name)" = "Allow-OpenVPN-UDP" ]; then
    uci -q delete firewall.$section
  fi
done

uci set firewall.vpn=zone
uci set firewall.vpn.name='vpn'
uci set firewall.vpn.network='vpn'
uci set firewall.vpn.input='ACCEPT'
uci set firewall.vpn.output='ACCEPT'
uci set firewall.vpn.forward='ACCEPT'
uci set firewall.vpn.masq='0'
uci set firewall.vpn.mtu_fix='1'

for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
  [ "$(uci -q get firewall.$section.name)" = "$WAN_ZONE" ] && {
     uci set firewall.$section.masq='1'
     uci set firewall.$section.mtu_fix='1'
   }
done

# Forwarding
uci set firewall.vpn_to_uplink=forwarding
uci set firewall.vpn_to_uplink.src='vpn'
uci set firewall.vpn_to_uplink.dest="$WAN_ZONE"

# Правило для OpenVPN порта
uci set firewall.allow_openvpn=rule
uci set firewall.allow_openvpn.name='Allow-OpenVPN'
uci set firewall.allow_openvpn.src="$WAN_ZONE"
uci set firewall.allow_openvpn.proto='udp'
uci set firewall.allow_openvpn.dest_port="$OPORT"
uci set firewall.allow_openvpn.target='ACCEPT'

uci commit firewall
/etc/init.d/openvpn restart

/etc/init.d/firewall restart
say "✓ Firewall настроен"

# Включаем форвардинг
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
for n in all default; do sysctl -w net.ipv4.conf.$n.rp_filter=0 >/dev/null || true; done
for i in $(ls /proc/sys/net/ipv4/conf 2>/dev/null); do sysctl -w net.ipv4.conf.$i.rp_filter=0 >/dev/null || true; done

# ---------- Rescue button ----------
cat >/usr/sbin/rw-fix <<'EOF_FIX'
#!/bin/sh
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Чистим украденные default и перезапускаем сервисы..."
for tunnel_iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep '^tun[0-9][0-9]*$'); do
  ip route del 0.0.0.0/1 dev "$tunnel_iface" 2>/dev/null || true
  ip route del 128.0.0.0/1 dev "$tunnel_iface" 2>/dev/null || true
  ip route del default dev "$tunnel_iface" 2>/dev/null || true
  ip -6 route del ::/1 dev "$tunnel_iface" 2>/dev/null || true
  ip -6 route del 2000::/3 dev "$tunnel_iface" 2>/dev/null || true
  ip -6 route del default dev "$tunnel_iface" 2>/dev/null || true
done
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true
/etc/init.d/openvpn restart 2>/dev/null || true
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Готово."
EOF_FIX
chmod +x /usr/sbin/rw-fix

# ---------- 7) Настройка Passwall TPROXY ----------
say "=== Настраиваем Passwall TPROXY ==="

if [ -f "/etc/config/passwall" ]; then
  say "Настраиваем Passwall для TPROXY..."
  VPN4_DNS="$(first_host_of_cidr "$VPN4_NET")"
  
  # Включаем Passwall но НЕ активируем сразу
  uci set passwall.@global[0].enabled='0'
  uci set passwall.@global[0].tcp_proxy_mode='global'
  uci set passwall.@global[0].udp_proxy_mode='global'
  uci set passwall.@global[0].dns_mode='tcp_udp'
  uci set passwall.@global[0].remote_dns='8.8.8.8'
  uci set passwall.@global[0].dns_client_ip="$VPN4_DNS"
  
  # Добавляем правило для VPN подсети
  for section in $(uci show passwall 2>/dev/null | sed -n 's/^passwall\.\([^.]*\)=acl_rule$/\1/p'); do
    if [ "$(uci -q get passwall.$section.name)" = "VPN Clients" ]; then
      uci -q delete passwall.$section
    fi
  done
  uci set passwall.rw_vpn_clients=acl_rule
  uci set passwall.rw_vpn_clients.enabled='1'
  uci set passwall.rw_vpn_clients.name='VPN Clients'
  uci set passwall.rw_vpn_clients.ip_type='all'
  uci set passwall.rw_vpn_clients.source="$VPN4_NET"
  uci set passwall.rw_vpn_clients.tcp_redir_ports='all'
  uci set passwall.rw_vpn_clients.udp_redir_ports='all'
  uci set passwall.rw_vpn_clients.tcp_no_redir_ports='disable'
  uci set passwall.rw_vpn_clients.udp_no_redir_ports='disable'
  
  uci commit passwall
  say "✓ Passwall настроен (отключен по умолчанию)"
else
  warn "Passwall не установлен, TPROXY недоступен"
fi

# ---------- 8) LuCI и веб-интерфейс ----------
say "=== Настраиваем веб-интерфейс ==="

/etc/init.d/uhttpd enable
/etc/init.d/uhttpd start

# Создаем клиентский конфиг
say "Создаем клиентский конфиг..."
PUB_IP="$(curl -4s --max-time 3 https://ifconfig.me/ip || curl -4s --max-time 3 https://ipinfo.io/ip || ip addr show "$DET_WAN" | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"
[ -z "$PUB_IP" ] && PUB_IP="YOUR_SERVER_IP"

cat >"/root/${CLIENT}.ovpn" <<EOCLI
client
float
dev tun
proto udp
remote $PUB_IP $OPORT
resolv-retry infinite
nobind
persist-key
block-outside-dns
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

# Закрываем статическую web-раздачу .ovpn
say "Отключаем web-раздачу клиентского конфига..."
cleanup_legacy_web_publish
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
say "✓ Web-раздача отключена; конфиг остаётся только в /root"

# ---------- DNS роутера ----------
say "=== Настраиваем DNS ==="
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci commit dhcp
/etc/init.d/dnsmasq restart
say "✓ DNS роутера настроен (1.1.1.1/8.8.8.8)"

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

# Проверяем доступность локального файла
if [ -f "/root/${CLIENT}.ovpn" ]; then
  say "✓ OVPN файл сохранён в /root/${CLIENT}.ovpn"
else
  warn "✗ OVPN файл не создан"
fi

# ---------- 10) Итоговая информация ----------
say "=== НАСТРОЙКА ЗАВЕРШЕНА ==="
SCP_TARGET="$PUB_IP"
case "$SCP_TARGET" in
  *:*) SCP_TARGET="[$SCP_TARGET]" ;;
esac
echo ""
echo "📡 ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
echo "================================"
echo "LuCI (веб-интерфейс): https://$PUB_IP"
echo "OpenVPN конфиг на роутере: /root/${CLIENT}.ovpn"
echo "Пример скачивания по SCP: scp root@${SCP_TARGET}:/root/${CLIENT}.ovpn ."
echo "OpenVPN порт: $OPORT (UDP)"
echo "Пароль LuCI: не выводится по соображениям безопасности"
if [ -f /root/roadwarrior-credentials.txt ]; then
  echo "Сгенерированный пароль root: /root/roadwarrior-credentials.txt"
fi
echo ""
echo "🔧 ДОПОЛНИТЕЛЬНЫЕ ВОЗМОЖНОСТИ:"
echo "================================"
echo "Passwall: LuCI → Services → Passwall"
echo "  - Включите 'Main Switch' для активации TPROXY"
echo "  - Добавьте свои прокси (Socks5/Xray/OpenVPN) в 'Node List'"
echo "  - Настройте правила в 'Access Control'"
echo ""
echo "📋 КОМАНДЫ ДЛЯ ПРОВЕРКИ:"
echo "================================"
echo "Статус OpenVPN: /etc/init.d/openvpn status"
echo "Логи OpenVPN: logread | grep openvpn"
echo "Подключенные клиенты: cat /tmp/openvpn-status.log"
echo "Статус Passwall: /etc/init.d/passwall status"
echo "Rescue-кнопка: /usr/sbin/rw-fix"
echo ""
echo "⚠️  ВАЖНЫЕ ЗАМЕЧАНИЯ:"
echo "================================"
echo "1. Passwall отключен по умолчанию - включите его через LuCI"
echo "2. При первом включении Passwall добавьте ноду 'Direct' для тестирования"
echo "3. Весь трафик через VPN будет идти через выбранные в Passwall прокси"
echo "4. TPROXY перехватывает TCP/UDP/QUIC/WEBTRANSPORT/DNS трафик"
echo "5. Web-раздача .ovpn отключена; используйте SSH/SCP или SFTP для передачи конфигурации"

say "Заберите конфиг по SCP: scp root@${SCP_TARGET}:/root/${CLIENT}.ovpn ."
say "Для входа в LuCI используйте учетную запись root и установленный ранее пароль"