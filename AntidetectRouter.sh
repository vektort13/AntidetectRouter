#!/bin/sh
# Unified Road-Warrior (VPS-friendly) — OpenWrt 24.10.x (x86_64)
# OpenVPN server (no data enc) + PBR (RW -> external tun*) via raw-nft
# SSH/LuCI management pinned via mgmt table; no fw4 rules; web publication as requested

# --------- UI helpers ----------
say()  { printf "\033[1;32m[RW]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[RW]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[RW]\033[0m %s\n" "$*"; }

# --------- small helpers ----------
ask_var() {
  local _q="$1" _name="$2" _def="${3:-}"; local _val
  printf "%s [%s]: " "$_q" "$_def"; read -r _val || true
  eval "$_name=\"${_val:-$_def}\""
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

say "=== Road-Warrior Auto Setup (VPS‑friendly) — unified ==="
say "Checking basic parameters..."

# --------- detection ----------
PUB_DEV="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
PUB_GW="$( ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
PUB_IP="$( ip -4 -o addr show dev "${PUB_DEV:-}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 )"

[ -z "${PUB_DEV:-}" ] && PUB_DEV="br-lan"
[ -z "${PUB_GW:-}" ]  && PUB_GW="$(ip r | awk '/^default/ {print $3; exit}')"
[ -z "${PUB_IP:-}" ]  && PUB_IP="$(ip -4 -o addr | awk '!/127\.0\.0\.1/ {print $4}' | head -n1 | cut -d/ -f1)"

say "Public dev: $PUB_DEV"
say "Public IP : ${PUB_IP:-UNKNOWN}"
say "Public GW : ${PUB_GW:-UNKNOWN}"

if ! check_interface "$PUB_DEV"; then
  err "Public interface $PUB_DEV not found — aborting."
  exit 1
fi

# --------- packages ----------
say "=== Installing base packages ==="
opkg update || warn "opkg update: errors occurred (continuing)"
install_pkg() {
  local p="$1"
  say "Installing: $p"
  opkg install -V1 "$p" >/dev/null 2>&1 || warn "Failed to install $p (continuing)"
}
for p in ca-bundle curl wget jq ip-full iptables-nft nftables nftables-json iptables-mod-nat-extra \
         openssl-util luci luci-ssl luci-compat luci-app-openvpn \
         openvpn-openssl kmod-tun openvpn-easy-rsa unzip nano; do
  install_pkg "$p"
done

# language packs for LuCI
for p in luci-i18n-base-ru luci-i18n-openvpn-ru luci-i18n-firewall-ru \
         luci-i18n-base-zh-cn luci-i18n-base-vi luci-i18n-base-es; do
  install_pkg "$p"
done

# dnsmasq-full (if lightweight version is installed)
opkg remove dnsmasq 2>/dev/null || true
install_pkg dnsmasq-full

# --------- root password (stable input) ----------
say "=== Root password (also for LuCI) ==="
if [ -z "${ROOT_PW:-}" ]; then
  TTY=/dev/tty
  if [ -r "$TTY" ]; then
    printf "Enter root password (Enter = keep current / set 12345 if empty): " >"$TTY"
    stty -echo <"$TTY" 2>/dev/null || true
    IFS= read -r ROOT_PW <"$TTY" || ROOT_PW=""
    stty echo <"$TTY" 2>/dev/null || true
    printf "\n" >"$TTY"
  else
    warn "TTY not available — skipping interactive input (will keep current password or set 12345 if empty)."
    ROOT_PW=""
  fi
fi
RW_PASS_SHOWN="(not changed)"
root_has_password() {
  local f; f="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)"
  [ -n "$f" ] && [ "$f" != "!" ] && [ "$f" != "*" ]
}
if [ -n "${ROOT_PW:-}" ]; then
  printf "%s\n%s\n" "$ROOT_PW" "$ROOT_PW" | passwd root >/dev/null 2>&1 && {
    RW_PASS_SHOWN="$ROOT_PW"; say "✓ Root password set (user-defined)";
  } || warn "Failed to set user-defined password"
else
  if root_has_password; then
    say "✓ Root password already set — leaving as is"
  else
    printf "%s\n%s\n" "12345" "12345" | passwd root >/dev/null 2>&1 && {
      RW_PASS_SHOWN="12345"; say "✓ Root password set: 12345";
    } || warn "Failed to set default password"
  fi
fi

# --------- OPTIONAL: Passwall feeds ----------
say "=== (Optional) Passwall GUI ==="
PASSWALL_KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/passwall.pub"
mkdir -p /etc/opkg/keys
uclient-fetch -q -T 15 -O /etc/opkg/keys/passwall.pub "$PASSWALL_KEY_URL" \
 || wget -q -O /etc/opkg/keys/passwall.pub "$PASSWALL_KEY_URL" \
 || warn "Could not download passwall.pub (non-critical)"
opkg-key add /etc/opkg/keys/passwall.pub >/dev/null 2>&1 || true
sed -i '/passwall_packages\|passwall_luci\|passwall2/d' /etc/opkg/customfeeds.conf 2>/dev/null
cat >> /etc/opkg/customfeeds.conf <<'EOF_PW'
src/gz passwall_luci https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-24.10/x86_64/passwall_luci
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-24.10/x86_64/passwall_packages
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-24.10/x86_64/passwall2
EOF_PW
opkg update >/dev/null 2>&1 || true
opkg install luci-app-passwall >/dev/null 2>&1 || opkg install luci-app-passwall2 >/dev/null 2>&1 || true
opkg install xray-core >/dev/null 2>&1 || opkg install sing-box >/dev/null 2>&1 || true

# --------- OpenVPN server (tun0) ----------
say "=== Configuring OpenVPN server (tun0) ==="
ask_var "OpenVPN port (UDP)" OPORT "1194"
ask_var "Client name (ovpn file)" CLIENT "client1"
ask_var "VPN IPv4 subnet"     VPN4_NET "10.99.0.0/24"
ask_var "VPN IPv6 subnet"     VPN6_NET "fd42:4242:4242:1::/64"

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
  say "✓ CA created"
}
[ -f "$OVPN_PKI/server.crt" ] || {
  openshell=false
  openssl genrsa -out "$OVPN_PKI/server.key" 2048
  openssl req -new -key "$OVPN_PKI/server.key" -out "$OVPN_PKI/server.csr" -subj "/CN=server" \
    -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/server.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/server.crt" -days 3650 -extensions server -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Server certificate created"
}
[ -f "$OVPN_PKI/$CLIENT.crt" ] || {
  openssl genrsa -out "$OVPN_PKI/$CLIENT.key" 2048
  openssl req -new -key "$OVPN_PKI/$CLIENT.key" -out "$OVPN_PKI/$CLIENT.csr" -subj "/CN=$CLIENT" \
    -config "$OVPN_PKI/openssl.cnf"
  openssl x509 -req -in "$OVPN_PKI/$CLIENT.csr" -CA "$OVPN_PKI/ca.crt" -CAkey "$OVPN_PKI/ca.key" \
    -CAcreateserial -out "$OVPN_PKI/$CLIENT.crt" -days 3650 -extensions client -extfile "$OVPN_PKI/openssl.cnf"
  say "✓ Client certificate created"
}
openvpn --genkey secret "$OVPN_PKI/tc.key" 2>/dev/null && say "✓ TLS-crypt key generated"

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
SRV_DNS="$(ip -4 -o addr show dev tun0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

if [ -z "$SRV_DNS" ]; then
  read RW_NET RW_MASK <<EOF
$(uci -q get openvpn.rw.server)
EOF
  ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24)+($2<<16)+($3<<8)+$4 )); }
  int2ip() { local ip=$1; printf "%d.%d.%d.%d\n" $(( (ip>>24)&255 )) $(( (ip>>16)&255 )) $(( (ip>>8)&255 )) $(( ip&255 )); }
  NET_INT=$(ip2int "$RW_NET")
  MSK_INT=$(ip2int "$RW_MASK")
  SRV_DNS="$(int2ip $(( (NET_INT & MSK_INT) + 1 )) )"
fi
for v in $(uci -q show openvpn.rw | sed -n "s/^openvpn\.rw\.push='\(.*\)'/\1/p" | grep -i '^dhcp-option DNS '); do
  uci -q del_list openvpn.rw.push="$v"
done

uci add_list openvpn.rw.push="dhcp-option DNS $SRV_DNS"
uci add_list openvpn.rw.push='block-outside-dns'
uci set openvpn.rw.tls_crypt="$OVPN_PKI/tc.key"
uci set openvpn.rw.status='/tmp/openvpn-status.log'
uci set openvpn.rw.log='/tmp/openvpn.log'
uci set openvpn.rw.verb='3'
uci commit openvpn
/etc/init.d/openvpn enable
/etc/init.d/openvpn restart
say "✓ OpenVPN server started"

# --------- Hardening OpenVPN clients ----------
say "Hardening OpenVPN clients (route-nopull / ignore redirect-gateway)..."
for f in /etc/openvpn/*.ovpn; do
  [ -f "$f" ] || continue
  grep -q '^route-nopull' "$f" || echo 'route-nopull' >>"$f"
  grep -q 'pull-filter ignore "redirect-gateway"' "$f" || echo 'pull-filter ignore "redirect-gateway"' >>"$f"
  grep -q 'pull-filter ignore "route-ipv6"' "$f" || echo 'pull-filter ignore "route-ipv6"' >>"$f"
  grep -q 'pull-filter ignore "ifconfig-ipv6"' "$f" || echo 'pull-filter ignore "ifconfig-ipv6"' >>"$f"
  grep -q '^script-security 2' "$f" || echo 'script-security 2' >>"$f"
done
for s in $(uci show openvpn 2>/dev/null | sed -n 's/^openvpn\.\([^.]*\)=openvpn/\1/p'); do
  [ "$(uci -q get openvpn.$s.client || echo 0)" = "1" ] || continue
  uci set openvpn.$s.route_nopull='1'
  uci -q delete openvpn.$s.pull_filter
  uci add_list openvpn.$s.pull_filter='ignore "redirect-gateway"'
  uci add_list openvpn.$s.pull_filter='ignore "route-ipv6"'
  uci add_list openvpn.$s.pull_filter='ignore "ifconfig-ipv6"'
done
uci commit openvpn
# Cleanup of potential /1 and IPv6 default routes
ip route del 0.0.0.0/1 dev tun+ 2>/dev/null || true
ip route del 128.0.0.0/1 dev tun+ 2>/dev/null || true
ip -6 route del ::/1      dev tun+ 2>/dev/null || true
ip -6 route del 2000::/3  dev tun+ 2>/dev/null || true

# --------- Rescue button ----------
cat >/usr/sbin/rw-fix <<'EOF_FIX'
#!/bin/sh
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Cleaning hijacked default routes and restarting services..."
ip route del 0.0.0.0/1  dev tun+ 2>/dev/null
ip route del 128.0.0.0/1 dev tun+ 2>/dev/null
ip -6 route del ::/1      dev tun+ 2>/dev/null
ip -6 route del 2000::/3  dev tun+ 2>/dev/null
ip route del default      dev tun+ 2>/dev/null
ip -6 route del default   dev tun+ 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/openvpn  restart 2>/dev/null || true
printf "\033[1;32m[rw-fix]\033[0m %s\n" "Done."
EOF_FIX
chmod +x /usr/sbin/rw-fix

# --------- Policy: mgmt table (SSH/LuCI pin) ----------
say "=== Management protection (mgmt table) ==="
grep -qE '^[[:space:]]*200[[:space:]]+mgmt$' /etc/iproute2/rt_tables || echo '200 mgmt' >> /etc/iproute2/rt_tables
[ -n "$PUB_GW" ] && ip route replace table mgmt default via "$PUB_GW" dev "$PUB_DEV"
if [ -n "$PUB_IP" ]; then
  ip rule add pref 100 from "$PUB_IP/32" table mgmt 2>/dev/null || ip rule replace pref 100 from "$PUB_IP/32" table mgmt
  say "✓ Traffic from $PUB_IP pinned via $PUB_DEV ($PUB_GW)"
else
  warn "Could not determine public IP — skipping mgmt rule"
fi

# --------- NAT + PBR (raw-nft, without fw4/fw rules) ----------
say "=== NAT/PBR (raw-nft) for RW->external tun* ==="
# base
sysctl -w net.ipv4.ip_forward=1          >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
for n in all default; do sysctl -w net.ipv4.conf.$n.rp_filter=0 >/dev/null || true; done
for i in $(ls /proc/sys/net/ipv4/conf 2>/dev/null); do sysctl -w net.ipv4.conf.$i.rp_filter=0 >/dev/null || true; done

# detection
RW_CIDR="$(uci -q get openvpn.rw.server | awk '{ip=$1; m=$2; if(m ~ /\./){split(m,a,".");c=0;for(i=1;i<=4;i++){o=a[i]+0;c+= (o==255?8:o==254?7:o==252?6:o==248?5:o==240?4:o==224?3:o==192?2:o==128?1:0)}; print ip"/"c}else print "10.99.0.0/24"}')"
[ -z "$RW_CIDR" ] && RW_CIDR="10.99.0.0/24"
SRV_IF="$(ip route show "$RW_CIDR" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; [ -z "$SRV_IF" ] && SRV_IF="tun0"
EXT_IF="$(ip -o link show | awk -F': ' '/: tun[0-9]+/ {print $2}' | grep -v "^${SRV_IF}$" | while read -r d; do ip -4 addr show dev "$d" | grep -q 'inet ' && echo "$d" && break; done)"
say "PUB_DEV=$PUB_DEV  SRV_IF=$SRV_IF  EXT_IF=${EXT_IF:-<none>}  RW=$RW_CIDR  PORT=$OPORT"

# do not use fw4
if /etc/init.d/firewall status >/dev/null 2>&1; then /etc/init.d/firewall stop || true; fi

# cleanup of our previous tables
nft delete table inet rwfix 2>/dev/null || true

# NAT: everything from SRV_IF is masqueraded out (including via tunX)
nft -f - <<EOF
add table inet rwfix
add chain inet rwfix post { type nat hook postrouting priority 100; }
add rule  inet rwfix post iifname "$SRV_IF" oifname != "$SRV_IF" masquerade
EOF

# PBR: traffic coming from SRV_IF goes to table vpnout (if EXT_IF exists)
grep -qE '^[[:space:]]*100[[:space:]]+vpnout$' /etc/iproute2/rt_tables || echo '100 vpnout' >> /etc/iproute2/rt_tables
while ip rule show | grep -q "lookup vpnout"; do
  pref="$(ip rule show | awk '/vpnout/ {print $1}' | head -n1)"; [ -n "$pref" ] && ip rule del pref "$pref" || break
done
ip route flush table vpnout 2>/dev/null || true
if [ -n "${EXT_IF:-}" ] && ip -4 addr show dev "$EXT_IF" | grep -q 'inet '; then
  ip route replace table vpnout default dev "$EXT_IF"
  ip rule add pref 110 iif "$SRV_IF" lookup vpnout
  say "PBR: $SRV_IF -> table vpnout (default via $EXT_IF)"
else
  say "PBR: no external tunX — table vpnout cleared, RW traffic goes via main"
fi

# restart OpenVPN
/etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn start >/dev/null 2>&1 || true

# --------- Generate .ovpn (with float) ----------
PUB_DETECTED="$(curl -s --max-time 3 ifconfig.me || curl -s --max-time 3 ipinfo.io/ip || echo "$PUB_IP")"
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
say "✓ Client config created: /root/${CLIENT}.ovpn"

# --------- YOUR BLOCK: publish via web and show to user ----------
say "Configuring web access to the configuration..."
mkdir -p /www/vpn
cp "/root/${CLIENT}.ovpn" "/www/vpn/"
chmod 644 "/www/vpn/${CLIENT}.ovpn"

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
        code { background:#f3f3f3; padding:2px 6px; border-radius:4px; }
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
        <p><strong>Password:</strong> $RW_PASS_SHOWN</p>
        <p><em>LuCI password = SSH password of user <code>root</code>.</em></p>
    </div>

    <p>Use the OpenVPN file in your OpenVPN client to connect to the VPN.</p>
</body>
</html>
EOF

if ! grep -q "home.*/www/vpn" /etc/config/uhttpd 2>/dev/null; then
  uci add uhttpd uhttpd
  uci set uhttpd.@uhttpd[-1].home="/www/vpn"
  uci set uhttpd.@uhttpd[-1].rfc1918_filter="0"
  uci commit uhttpd
fi

/etc/init.d/uhttpd restart
say "✓ Web interface configured"

# ---------- Router DNS + forwarding outbound VPN DNS ----------
say "Preparing base dnsmasq configuration..."

# Remove hardcoded 1.1.1.1/8.8.8.8 and return to system DNS of VPS
uci -q delete dhcp.@dnsmasq[0].server || true
uci set dhcp.@dnsmasq[0].noresolv='0'

# dnsmasq must listen on tun0 for RW clients
if ! uci show dhcp.@dnsmasq[0].interface 2>/dev/null | grep -q "tun0"; then
  uci add_list dhcp.@dnsmasq[0].interface='tun0'
fi
uci set dhcp.@dnsmasq[0].bind_dynamic='1'
uci commit dhcp
/etc/init.d/dnsmasq restart || true
say "✓ dnsmasq is configured to serve RW clients via tun0"

# ---------- Script hook for outbound OpenVPN client ----------
say "Installing OpenVPN DNS-hook: /etc/openvpn/rw-dyn-dns.sh"

cat >/etc/openvpn/rw-dyn-dns.sh <<'EOF_HOOK'
#!/bin/sh
# rw-dyn-dns.sh
# OpenVPN client up/down hook to switch upstream DNS for dnsmasq:
#  - up: use DNS pushed by VPN server (dhcp-option DNS ...) via interface $dev
#  - down: revert dnsmasq to VPS/OpenWrt DNS (resolv.conf.auto)

set -eu

DNS_TMP="/tmp/vpn-upstream-dns.list"

case "${script_type:-}" in
  up)
    : > "$DNS_TMP"
    i=1
    while true; do
      eval "opt=\${foreign_option_$i:-}"
      [ -z "${opt:-}" ] && break
      case "$opt" in
        *"dhcp-option DNS "*)
          echo "$opt" | awk '{print $3}' >> "$DNS_TMP"
          ;;
      esac
      i=$((i+1))
    done

    # If server did not push any DNS - do not break existing scheme
    if [ ! -s "$DNS_TMP" ]; then
      exit 0
    fi

    EXT_IF="${dev:-}"

    uci -q delete dhcp.@dnsmasq[0].server || true
    uci set dhcp.@dnsmasq[0].noresolv='1'

    while read -r ns; do
      [ -n "$ns" ] && uci add_list dhcp.@dnsmasq[0].server="/#/${ns}${EXT_IF:+@${EXT_IF}}"
    done < "$DNS_TMP"

    uci commit dhcp
    /etc/init.d/dnsmasq reload || true
    ;;

  down)
    # Revert to VPS/OpenWrt DNS
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci set dhcp.@dnsmasq[0].noresolv='0'
    uci commit dhcp
    /etc/init.d/dnsmasq reload || true
    ;;
esac

exit 0
EOF_HOOK

chmod +x /etc/openvpn/rw-dyn-dns.sh

# ---------- Add hook to all /etc/openvpn/*.ovpn (outbound clients) ----------
say "Registering hook in /etc/openvpn/*.ovpn (if present)..."

for f in /etc/openvpn/*.ovpn; do
  [ -f "$f" ] || continue
  say "  updating $f"
  grep -q '^script-security 2' "$f"                   || echo 'script-security 2' >>"$f"
  grep -q '^up /etc/openvpn/rw-dyn-dns.sh' "$f"       || echo 'up /etc/openvpn/rw-dyn-dns.sh' >>"$f"
  grep -q '^down /etc/openvpn/rw-dyn-dns.sh' "$f"     || echo 'down /etc/openvpn/rw-dyn-dns.sh' >>"$f"
  grep -q 'pull-filter accept "dhcp-option"' "$f"     || echo 'pull-filter accept "dhcp-option"' >>"$f"
done

# Restart OpenVPN to load hook and updated DNS push
/etc/init.d/openvpn restart || true
say "✓ RW DNS + automatic use of outbound VPN DNS is configured"

# ---------- Final checks ----------
say "=== Running final checks ==="
check_service() {
  local service="$1"
  if /etc/init.d/"$service" status >/dev/null 2>&1; then
    say "✓ $service is running"
    return 0
  else
    warn "✗ $service is not running"
    return 1
  fi
}
check_service "openvpn"
check_service "uhttpd"
check_service "firewall"

check_interface "tun0" || warn "Interface tun0 not created yet (it will be created when a client connects)"

if netstat -tulpn 2>/dev/null | grep -q ":$OPORT"; then
  say "✓ Port $OPORT is listening"
else
  warn "✗ Port $OPORT is not listening"
fi

if [ -f "/www/vpn/${CLIENT}.ovpn" ]; then
  say "✓ OVPN file available at https://$PUB_IP/vpn/"
else
  warn "✗ OVPN file not created in web directory"
fi

# ---------- Final information ----------
say "=== SETUP COMPLETED ==="
echo ""
echo "📡 CONNECTION INFORMATION:"
echo "================================"
echo "LuCI (web interface): https://$PUB_IP"
echo "OpenVPN config: https://$PUB_IP/vpn/"
echo "OpenVPN port: $OPORT (UDP)"
echo "LuCI password: $RW_PASS_SHOWN"
echo ""
echo "ℹ️  Important: in OpenWrt the LuCI password is the same as the SSH password for user 'root'."
echo "If you change the password with the 'passwd' command over SSH, it will automatically change for LuCI login as well."
echo ""
echo "🔧 ADDITIONAL OPTIONS:"
echo "================================"
echo "Passwall: LuCI → Services → Passwall"
echo "  - Enable 'Main Switch' to activate TPROXY"
echo "  - Add your proxies (Socks5/Xray/OpenVPN) in 'Node List'"
echo "  - Configure rules in 'Access Control'"
echo ""
echo "📋 COMMANDS FOR CHECKING:"
echo "================================"
echo "OpenVPN status: /etc/init.d/openvpn status"
echo "OpenVPN logs:   logread -e openvpn | tail -n 120"
echo "Connected clients: cat /tmp/openvpn-status.log"
echo "Passwall status:   /etc/init.d/passwall status"
echo "Rescue button:     /usr/sbin/rw-fix"
echo ""
echo "⚠️  IMPORTANT NOTES:"
echo "================================"
echo "1. Traffic of RW clients (subnet $VPN4_NET) goes through the active EXTERNAL OpenVPN client (tun*)."
echo "2. The router itself (SSH/LuCI) always uses the public interface; /1 and IPv6 defaults on tun+ are removed."
echo "3. Quick rescue: /usr/sbin/rw-fix (does not change LAN, fixes DNS and default route)."
echo ""
say "Download the config at: https://$PUB_IP/vpn/"
say "To log in to LuCI use: root / $RW_PASS_SHOWN"
