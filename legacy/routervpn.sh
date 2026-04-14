#!/bin/sh
# Road-Warrior for OpenWrt 24.10.x (x86_64) — VPS-friendly (DigitalOcean)
# OpenVPN server (no data enc) + external OpenVPN client hardening + PBR (RW -> external tun*)
# SSH/LuCI are protected (management always via public interface)
# Passwall GUI optional; secure client retrieval via SSH/SCP only; zero changes to your default LAN/WAN layout

# --------- UI helpers ----------
say()  { printf "\033[1;32m[RW]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[RW]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[RW]\033[0m %s\n" "$*"; }

set_named_var() {
  local _name="$1" _value="$2"
  case "$_name" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  export "$_name=$_value"
}

# --------- small helpers ----------
ask_var() {
  local _q="$1" _name="$2" _def="${3:-}"; local _val
  printf "%s [%s]: " "$_q" "$_def"; read -r _val || true
  set_named_var "$_name" "${_val:-$_def}" || { err "Internal variable name error: $_name"; exit 1; }
}

cidr2mask() {
  local bits="${1#*/}" m=0 i=0
  [ -z "$bits" ] || [ "$bits" = "$1" ] && { echo 255.255.255.0; return; }
  while [ $i -lt 32 ]; do [ $i -lt "$bits" ] && m=$((m | (1<<(31-i)))); i=$((i+1)); done
  printf "%d.%d.%d.%d" $(( (m>>24)&255 )) $(( (m>>16)&255 )) $(( (m>>8)&255 )) $(( m&255 ))
}

mask2cidr() {
  IFS=. read -r o1 o2 o3 o4 <<EOF
$1
EOF
  local c=0 o; for o in $o1 $o2 $o3 $o4; do
    case $o in
      255) c=$((c+8));; 254) c=$((c+7));; 252) c=$((c+6));;
      248) c=$((c+5));; 240) c=$((c+4));; 224) c=$((c+3));;
      192) c=$((c+2));; 128) c=$((c+1));; 0) :;;
    esac
  done; echo "${c:-24}"
}

check_interface() { ip link show "$1" >/dev/null 2>&1; }
have_bin() { command -v "$1" >/dev/null 2>&1; }

ask_valid() {
  local _q="$1" _name="$2" _def="${3:-}" _validator="$4" _error="$5" _val
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

# --------- detection ----------
say "=== Road-Warrior Auto Setup (VPS‑friendly) ==="
say "Проверяем базовые параметры..."

# Публичный интерфейс/шлюз/адрес берём из фактического default
PUB_DEV="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
PUB_GW="$( ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
PUB_IP="$( ip -4 -o addr show dev "$PUB_DEV" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 )"

if [ -z "$PUB_DEV" ]; then
  PUB_DEV="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p')"
fi
[ -z "$PUB_GW" ]  && PUB_GW="$(ip r | awk '/^default/ {print $3; exit}')"
[ -z "$PUB_IP" ]  && PUB_IP="$(ip -4 -o addr | awk '!/127\.0\.0\.1/ {print $4}' | head -n1 | cut -d/ -f1)"

if [ -z "$PUB_DEV" ]; then
  err "Не удалось определить публичный интерфейс (default route/WAN)."
  exit 1
fi

say "Публичный dev: $PUB_DEV"
say "Публичный IP : ${PUB_IP:-UNKNOWN}"
say "Публичный GW : ${PUB_GW:-UNKNOWN}"

if ! check_interface "$PUB_DEV"; then
  err "Публичный интерфейс $PUB_DEV не найден — останов."
  exit 1
fi

# --------- packages ----------
say "=== Устанавливаем базовые пакеты ==="
opkg update || {
  err "opkg update завершился с ошибкой. Проверьте интернет/время/CA и повторите запуск."
  exit 1
}

install_pkg() {
  local p="$1"
  say "Устанавливаю: $p"
  opkg install -V1 "$p" >/dev/null 2>&1 || warn "Не удалось установить $p (продолжаю)"
}

for p in ca-bundle curl wget jq ip-full iptables-nft nftables nftables-json iptables-mod-nat-extra \
         openssl-util luci luci-ssl luci-compat luci-app-openvpn \
         openvpn-openssl kmod-tun unzip nano; do
  install_pkg "$p"
done

# dnsmasq-full (с защитой от потери DNS)
ensure_dnsmasq_full

# --------- root password (без подвисаний) ----------
say "=== Пароль root (для LuCI тоже) ==="
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

root_has_password() {
  local f; f="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)"
  [ -n "$f" ] && [ "$f" != "!" ] && [ "$f" != "*" ]
}
if [ -n "${ROOT_PW:-}" ]; then
  printf "%s\n%s\n" "$ROOT_PW" "$ROOT_PW" | passwd root >/dev/null 2>&1 && {
    say "✓ Пароль root обновлён";
  } || {
    err "Не удалось установить пользовательский пароль"
    exit 1
  }
else
  if root_has_password; then
    say "✓ Пароль root уже установлен — оставляю без изменений"
  else
    DEFAULT_PW="$(generate_random_secret)"
    [ -n "$DEFAULT_PW" ] || {
      err "Не удалось сгенерировать пароль root"
      exit 1
    }
    printf "%s\n%s\n" "$DEFAULT_PW" "$DEFAULT_PW" | passwd root >/dev/null 2>&1 && {
      say "✓ Пароль root сгенерирован автоматически";
      printf 'root\n%s\n' "$DEFAULT_PW" > /root/roadwarrior-credentials.txt
      chmod 600 /root/roadwarrior-credentials.txt
      warn "Учётные данные root сохранены в /root/roadwarrior-credentials.txt"
    } || {
      err "Не удалось выставить пароль root"
      exit 1
    }
  fi
fi

# --------- OPTIONAL: Passwall feeds (не обязательно) ----------
say "=== (Опционально) Passwall GUI ==="
PASSWALL_KEY_URL="https://sourceforge.net/projects/openwrt-passwall-build/files/ipk.pub/download"
mkdir -p /etc/opkg/keys
uclient-fetch -q -T 15 -O /etc/opkg/keys/ipk.pub "$PASSWALL_KEY_URL" \
 || wget -q -O /etc/opkg/keys/ipk.pub "$PASSWALL_KEY_URL" \
 || warn "Не смог скачать ipk.pub (не критично)"
opkg-key add /etc/opkg/keys/ipk.pub >/dev/null 2>&1 || true
PW_RELEASE="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release 2>/dev/null | awk -F. '{print $1"."$2}')"
PW_ARCH="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2" "$3}' | sort -k2,2n | tail -1 | awk '{print $1}')"
[ -z "$PW_RELEASE" ] && PW_RELEASE="24.10"
[ -z "$PW_ARCH" ] && PW_ARCH="x86_64"
say "Фиды Passwall: $PW_RELEASE/$PW_ARCH"
sed -i '/passwall_packages\|passwall_luci\|passwall2/d' /etc/opkg/customfeeds.conf 2>/dev/null
cat >> /etc/opkg/customfeeds.conf <<EOF_PW
src/gz passwall_luci https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall_luci
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall_packages
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${PW_RELEASE}/${PW_ARCH}/passwall2
EOF_PW
if opkg update >/dev/null 2>&1; then
  opkg install luci-app-passwall >/dev/null 2>&1 || opkg install luci-app-passwall2 >/dev/null 2>&1 || true
  opkg install xray-core >/dev/null 2>&1 || opkg install sing-box >/dev/null 2>&1 || true
else
  warn "Не удалось обновить индексы для Passwall — пропускаю установку Passwall"
fi

# --------- OpenVPN server (tun0) ----------
say "=== Настройка OpenVPN сервера (tun0) ==="
ask_valid "Порт OpenVPN (UDP)" OPORT "1194" is_valid_port "Введите числовой порт от 1 до 65535"
ask_var "Имя клиента (ovpn-файл)" CLIENT "client1"
CLIENT="$(sanitize_client_name "$CLIENT")"
[ -n "$CLIENT" ] || CLIENT="client1"
ask_valid "VPN IPv4 подсеть"     VPN4_NET "10.99.0.0/24" is_valid_ipv4_cidr "Введите корректную IPv4 CIDR-подсеть, например 10.99.0.0/24"
ask_valid "VPN IPv6 подсеть"     VPN6_NET "fd42:4242:4242:1::/64" is_valid_ipv6_cidr "Введите корректную IPv6 CIDR-подсеть, например fd42:4242:4242:1::/64"

OVPN_PKI="/etc/openvpn/pki"; mkdir -p "$OVPN_PKI"
cat > "$OVPN_PKI/openssl.cnf" << 'EOF_OCNF'
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
EOF_OCNF

[ -f "$OVPN_PKI/ca.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/ca.key" 2048
  openssl req -new -x509 -days 3650 -key "$OVPN_PKI/ca.key" -out "$OVPN_PKI/ca.crt" \
    -subj "/CN=OpenWrt-VPN-CA" -extensions v3_ca -config "$OVPN_PKI/openssl.cnf"
  say "✓ CA создан"
}
[ -f "$OVPN_PKI/server.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/server.key" 2048
  openssl req -new -key "$OVPN_PKI/server.key" -out "$OVPN_PKI/server.csr" -subj "/CN=server" \
    -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/server.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/server.crt" -days 3650 -extensions server -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Серверный сертификат создан"
}
[ -f "$OVPN_PKI/$CLIENT.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/$CLIENT.key" 2048
  openssl req -new -key "$OVPN_PKI/$CLIENT.key" -out "$OVPN_PKI/$CLIENT.csr" -subj "/CN=$CLIENT" \
    -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/$CLIENT.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/$CLIENT.crt" -days 3650 -extensions client -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Клиентский сертификат создан"
}
[ -f "$OVPN_PKI/tc.key" ] || { openvpn --genkey secret "$OVPN_PKI/tc.key" 2>/dev/null && say "✓ TLS-crypt ключ создан"; }

OVPN4="${VPN4_NET%/*}"; MASK4="$(cidr2mask "$VPN4_NET")"

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
/etc/init.d/openvpn restart
say "✓ OpenVPN сервер запущен"

# --------- Hardening всех клиентов OpenVPN (чтобы не воровали default) ----------
say "Харденинг OpenVPN-клиентов (route-nopull / ignore redirect-gateway)..."
for f in /etc/openvpn/*.ovpn; do
  [ -f "$f" ] || continue
  grep -q '^route-nopull' "$f" || echo 'route-nopull' >>"$f"
  grep -q 'pull-filter ignore "redirect-gateway"' "$f" || echo 'pull-filter ignore "redirect-gateway"' >>"$f"
  grep -q 'pull-filter ignore "route-ipv6"' "$f" || echo 'pull-filter ignore "route-ipv6"' >>"$f"
  grep -q 'pull-filter ignore "ifconfig-ipv6"' "$f" || echo 'pull-filter ignore "ifconfig-ipv6"' >>"$f"
  grep -q '^script-security 2' "$f" || echo 'script-security 2' >>"$f"
done
# для UCI-инстансов с client=1
for s in $(uci show openvpn 2>/dev/null | sed -n 's/^openvpn\.\([^.]*\)=openvpn/\1/p'); do
  [ "$(uci -q get openvpn.$s.client || echo 0)" = "1" ] || continue
  uci set openvpn.$s.route_nopull='1'
  uci -q delete openvpn.$s.pull_filter
  uci add_list openvpn.$s.pull_filter='ignore "redirect-gateway"'
  uci add_list openvpn.$s.pull_filter='ignore "route-ipv6"'
  uci add_list openvpn.$s.pull_filter='ignore "ifconfig-ipv6"'
done
uci commit openvpn
# Чистка потенциальных /1 и IPv6-дефолтов
ip route del 0.0.0.0/1 dev tun+ 2>/dev/null || true
ip route del 128.0.0.0/1 dev tun+ 2>/dev/null || true
ip -6 route del ::/1      dev tun+ 2>/dev/null || true
ip -6 route del 2000::/3  dev tun+ 2>/dev/null || true

# --------- Кнопка спасения ----------
cat >/usr/sbin/rw-fix <<'EOF_FIX'
#!/bin/sh
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Чистим украденные default и перезапускаем сервисы..."
ip route del 0.0.0.0/1  dev tun+ 2>/dev/null
ip route del 128.0.0.0/1 dev tun+ 2>/dev/null
ip -6 route del ::/1      dev tun+ 2>/dev/null
ip -6 route del 2000::/3  dev tun+ 2>/dev/null
ip route del default      dev tun+ 2>/dev/null
ip -6 route del default   dev tun+ 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true
/etc/init.d/openvpn restart  2>/dev/null || true
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Готово."
EOF_FIX
chmod +x /usr/sbin/rw-fix

# --------- Firewall & network stubs ----------
say "=== Настраиваем Firewall ==="

# Определяем WAN-зону динамически
WAN_NETWORK="$(detect_network_name_by_device "$PUB_DEV" || true)"
[ -z "$WAN_NETWORK" ] && WAN_NETWORK='wan'
WAN_ZONE="$(detect_firewall_zone_by_network "$WAN_NETWORK" || true)"
[ -z "$WAN_ZONE" ] && WAN_ZONE="$WAN_NETWORK"
say "Uplink network: $WAN_NETWORK (zone: $WAN_ZONE)"

# интерфейс 'vpn' указывает на серверный tun0 (только для зоны)
uci -q delete network.vpn
uci set network.vpn=interface
uci set network.vpn.device='tun0'
uci set network.vpn.proto='none'
uci set network.vpn.auto='1'
uci commit network
/etc/init.d/network reload

# Зона для server tun0
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
  if [ "$(uci -q get firewall.$section.name)" = "vpn" ]; then
    uci -q delete firewall.$section
  fi
done
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=forwarding$/\1/p'); do
  if [ "$(uci -q get firewall.$section.src)" = "vpn" ]; then
    _dest="$(uci -q get firewall.$section.dest)"
    if [ "$_dest" = "wan" ] || [ "$_dest" = "$WAN_ZONE" ]; then
      uci -q delete firewall.$section
    fi
  fi
done
for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=rule$/\1/p'); do
  if [ "$(uci -q get firewall.$section.name)" = "Allow-OpenVPN-UDP" ]; then
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

# Открываем порт OpenVPN на всех входах (чтобы не зависеть от названия зоны)
uci set firewall.allow_openvpn=rule
uci set firewall.allow_openvpn.name='Allow-OpenVPN-UDP'
uci set firewall.allow_openvpn.src='*'
uci set firewall.allow_openvpn.proto='udp'
uci set firewall.allow_openvpn.dest_port="$OPORT"
uci set firewall.allow_openvpn.target='ACCEPT'

uci set firewall.vpn_to_wan=forwarding
uci set firewall.vpn_to_wan.src='vpn'
uci set firewall.vpn_to_wan.dest="$WAN_ZONE"

uci commit firewall
/etc/init.d/firewall restart
say "✓ Firewall базово готов"

# --------- Policy: mgmt таблица (защита SSH/LuCI) ----------
say "=== Защита управления (mgmt table) ==="
grep -qE '^[[:space:]]*200[[:space:]]+mgmt$' /etc/iproute2/rt_tables || echo '200 mgmt' >> /etc/iproute2/rt_tables
[ -n "$PUB_GW" ] && ip route replace table mgmt default via "$PUB_GW" dev "$PUB_DEV"
while ip rule show 2>/dev/null | grep -q 'lookup mgmt'; do
  pref="$(ip rule show 2>/dev/null | awk '/lookup mgmt/ { sub(/:/, "", $1); print $1; exit }')"
  [ -n "$pref" ] || break
  ip rule del pref "$pref" >/dev/null 2>&1 || break
done
if [ -n "$PUB_IP" ]; then
  ip rule add pref 100 from "$PUB_IP/32" table mgmt 2>/dev/null || ip rule replace pref 100 from "$PUB_IP/32" table mgmt
  say "✓ Трафик с $PUB_IP закреплён через $PUB_DEV ($PUB_GW)"
else
  warn "Не удалось определить публичный IP — пропускаю mgmt rule"
fi

# --------- vpnout-apply (PBR для RW -> внешний туннель) ----------
say "=== Устанавливаем vpnout-apply (PBR RW -> external tun*) ==="
cat >/usr/sbin/vpnout-apply <<'EOF_PBR'
#!/bin/sh
# Finds RW server tun (by RW subnet), detects external tun*, applies PBR (table vpnout) + firewall zone wan_vpn

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

mask2cidr() {
  IFS=. read -r o1 o2 o3 o4 <<EOF
$1
EOF
  local c=0 o; for o in $o1 $o2 $o3 $o4; do
    case $o in 255) c=$((c+8));; 254) c=$((c+7));; 252) c=$((c+6));;
      248) c=$((c+5));; 240) c=$((c+4));; 224) c=$((c+3));;
      192) c=$((c+2));; 128) c=$((c+1));; 0) :;; esac
  done; echo "${c:-24}"
}

get_rw_cidr() {
  local srv net msk cidr
  srv="$(uci -q get openvpn.rw.server 2>/dev/null || true)"
  if [ -n "$srv" ]; then
    net="$(echo "$srv" | awk '{print $1}')"
    msk="$(echo "$srv" | awk '{print $2}')"
    if echo "$msk" | grep -q '\.'; then cidr="$(mask2cidr "$msk")"; echo "$net/$cidr"; return; fi
  fi
  echo "10.99.0.0/24"
}

pick_server_tun() { ip route show "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

pick_external_tun() {
  local server_if="$1" dev last=""
  for dev in $(ip -o link show | awk -F': ' '/: tun[0-9]+/ {print $2}' | sort -V); do
    [ "$dev" = "$server_if" ] && continue
    if ip -o -4 addr show dev "$dev" | grep -q 'inet '; then last="$dev"; fi
  done
  echo "$last"
}

ensure_rt_table() { grep -qE '^[[:space:]]*100[[:space:]]+vpnout$' /etc/iproute2/rt_tables || echo '100 vpnout' >> /etc/iproute2/rt_tables; }

apply_fw() {
  local ext_if="$1" section zone_section fexists
  [ -n "$ext_if" ] || return 0

  # zone wan_vpn (masq)
  zone_section=""
  for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
    [ "$(uci -q get firewall.$section.name)" = "wan_vpn" ] && { zone_section="$section"; break; }
  done
  if [ -z "$zone_section" ]; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='wan_vpn'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=zone$/\1/p'); do
      [ "$(uci -q get firewall.$section.name)" = "wan_vpn" ] && { zone_section="$section"; break; }
    done
  fi
  [ -n "$zone_section" ] || return 1
  uci -q del firewall.$zone_section.device
  uci add_list firewall.$zone_section.device="$ext_if"

  # forwarding vpn (server) -> wan_vpn
  fexists="no"
  for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get firewall.$section.src)" = "vpn" ] || continue
    [ "$(uci -q get firewall.$section.dest)" = "wan_vpn" ] || continue
    fexists="yes"
    break
  done
  [ "$fexists" = "yes" ] || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='vpn'; uci set firewall.@forwarding[-1].dest='wan_vpn'; }

  uci commit firewall
  /etc/init.d/firewall reload
}

main() {
  local cidr srv_if ext_if
  cidr="$(get_rw_cidr)"
  srv_if="$(pick_server_tun "$cidr" || true)"
  ext_if="$(pick_external_tun "$srv_if")"

  ensure_rt_table

  if [ -n "$ext_if" ]; then
    ip route replace table vpnout default dev "$ext_if"
    # срезаем /1 и IPv6-дефолты, если провайдер их пихает
    ip route del 0.0.0.0/1  dev "$ext_if" 2>/dev/null || true
    ip route del 128.0.0.0/1 dev "$ext_if" 2>/dev/null || true
    ip -6 route del ::/1      dev "$ext_if" 2>/dev/null || true
    ip -6 route del 2000::/3  dev "$ext_if" 2>/dev/null || true
    # правило: RW-подсеть -> таблица vpnout
    while ip rule show | grep -q "from $cidr.*table vpnout"; do ip rule del from "$cidr" table vpnout || true; done
    ip rule add pref 110 from "$cidr" table vpnout

    apply_fw "$ext_if"
  else
    # внешнего туннеля нет — чистим таблицу и правило
    ip rule del from "$cidr" table vpnout 2>/dev/null || true
    ip route flush table vpnout 2>/dev/null || true
  fi
}
main
exit 0
EOF_PBR
chmod +x /usr/sbin/vpnout-apply

# hotplug: при появлении/исчезновении tun* перекидываем политику
mkdir -p /etc/hotplug.d/net /etc/hotplug.d/iface
cat >/etc/hotplug.d/net/99-vpnout <<'EOF_HPN'
#!/bin/sh
case "$DEVICE" in
  tun[0-9]*) /usr/sbin/vpnout-apply ;;
esac
EOF_HPN
chmod +x /etc/hotplug.d/net/99-vpnout
cat >/etc/hotplug.d/iface/99-vpnout <<'EOF_HPI'
#!/bin/sh
case "$INTERFACE" in
  tun[0-9]*) /usr/sbin/vpnout-apply ;;
esac
EOF_HPI
chmod +x /etc/hotplug.d/iface/99-vpnout

# Первичный вызов
/usr/sbin/vpnout-apply
say "✓ PBR установлен (RW -> внешний tun*, управление закреплено)"

# --------- Закрытая выдача клиентского файла ----------
say "=== Закрываем web-раздачу .ovpn и логов ==="

# ovpn клиентский файл
PUB_DETECTED="$(curl -4s --max-time 3 https://ifconfig.me/ip || curl -4s --max-time 3 https://ipinfo.io/ip || echo "$PUB_IP")"
[ -z "$PUB_DETECTED" ] && PUB_DETECTED="$PUB_IP"
cat >"/root/${CLIENT}.ovpn" <<EOCLI
client
float
dev tun
proto udp
remote $PUB_DETECTED $OPORT
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
cleanup_legacy_web_publish
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
say "✓ Конфиг остаётся только в /root; web-раздача отключена"

# --------- DNS роутера (чтобы не зависеть от push) ----------
say "=== Жёсткие DNS для роутера ==="
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci commit dhcp
/etc/init.d/dnsmasq restart
say "✓ DNS настроен"

# --------- Финальные проверки ----------
say "=== Финальные проверки ==="
svc_ok() { /etc/init.d/"$1" status >/dev/null 2>&1 && say "✓ $1 запущен" || warn "$1 не запущен"; }
svc_ok openvpn
svc_ok uhttpd
svc_ok firewall

if netstat -tulpn 2>/dev/null | grep -q ":$OPORT"; then
  say "✓ Порт $OPORT/udp слушается"
else
  warn "Порт $OPORT/udp не слушается"
fi

say "=== ГОТОВО ==="
SCP_TARGET="$PUB_DETECTED"
[ -n "$SCP_TARGET" ] || SCP_TARGET="$PUB_IP"
case "$SCP_TARGET" in
  *:*) SCP_TARGET="[$SCP_TARGET]" ;;
esac
echo ""
echo "📡 Конфиг клиента на роутере: /root/${CLIENT}.ovpn"
echo "📥 Пример скачивания по SCP: scp root@${SCP_TARGET}:/root/${CLIENT}.ovpn ."
if [ -f /root/roadwarrior-credentials.txt ]; then
  echo "🔐 Сгенерированный пароль root: /root/roadwarrior-credentials.txt"
fi
echo "SSH/LuCI всегда идут через публичный интерфейс: ${PUB_DEV} (${PUB_IP})"
echo "RW-подсеть: ${VPN4_NET} (только она уходит через внешний tun*, когда он поднят)"
echo "Web-раздача .ovpn и логов отключена; используйте SSH/SCP или SFTP"
echo "Rescue: /usr/sbin/rw-fix"
echo ""
