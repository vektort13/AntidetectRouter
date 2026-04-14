#!/bin/sh
# RoadWarrior One-Command Installer for OpenWrt
# Installs and configures OpenVPN server with guided setup.

set -u

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BLUE='\033[1;34m'

ROOT_PASSWORD_STATUS='unchanged'
ROOT_PASSWORD_GENERATED=''

print_line() {
    printf '%s\n' "------------------------------------------------------------"
}

title() {
    print_line
    printf '%b%s%b\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"
    print_line
}

ok() {
    printf '%b%s%b %s\n' "$C_GREEN" "[OK]" "$C_RESET" "$1"
}

info() {
    printf '%b%s%b %s\n' "$C_BLUE" "[INFO]" "$C_RESET" "$1"
}

warn() {
    printf '%b%s%b %s\n' "$C_YELLOW" "[WARN]" "$C_RESET" "$1"
}

fail() {
    printf '%b%s%b %s\n' "$C_RED" "[FAIL]" "$C_RESET" "$1"
}

abort() {
    fail "$1"
    exit 1
}

prompt_value() {
    question="$1"
    default="$2"
    hint="$3"

    [ -n "$hint" ] && info "$hint" >&2
    printf '%s [%s]: ' "$question" "$default" >&2
    IFS= read -r answer
    [ -z "$answer" ] && answer="$default"
    PROMPT_RESULT="$answer"
}

prompt_yes_no() {
    question="$1"
    default="$2"

    if [ "$default" = "Y" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    printf '%s %s: ' "$question" "$suffix"
    IFS= read -r yn
    [ -z "$yn" ] && yn="$default"

    case "$yn" in
        Y|y) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_validated_value() {
    question="$1"
    default="$2"
    hint="$3"
    validator="$4"
    error_message="$5"

    while :; do
        prompt_value "$question" "$default" "$hint"
        if "$validator" "$PROMPT_RESULT"; then
            return 0
        fi
        warn "$error_message"
    done
}

require_root() {
    [ "$(id -u)" -eq 0 ] || abort "Run this installer as root."
}

check_platform() {
    if [ ! -f /etc/openwrt_release ]; then
        warn "OpenWrt release file not found. Script is designed for OpenWrt."
        prompt_yes_no "Continue anyway?" "N" || abort "Aborted by user."
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
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
    old_ifs="$IFS"
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

    return 0
}

is_valid_ipv4_cidr() {
    network="${1%/*}"
    bits="${1#*/}"

    [ "$network" != "$1" ] || return 1
    is_valid_ipv4 "$network" || return 1
    is_uint "$bits" || return 1
    [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

is_valid_ipv6_address() {
    addr="$1"
    # Must be non-empty, contain only hex digits and colons, have at least one colon
    case "$addr" in ''|*[!0-9A-Fa-f:]*) return 1 ;; esac
    case "$addr" in *:*) ;; *) return 1 ;; esac
    # Max 39 chars (8 groups of 4 + 7 colons)
    [ "${#addr}" -le 39 ] || return 1
    # No triple colon (:::)
    case "$addr" in *:::*) return 1 ;; esac
    # At most one :: abbreviation
    rest="${addr#*::}"
    [ "$rest" = "$addr" ] || { case "$rest" in *::*) return 1 ;; esac; }
    return 0
}

is_valid_ipv6_cidr() {
    network="${1%/*}"
    bits="${1#*/}"

    [ "$network" != "$1" ] || return 1
    is_valid_ipv6_address "$network" || return 1
    is_uint "$bits" || return 1
    [ "$bits" -ge 0 ] && [ "$bits" -le 128 ]
}

check_interface() {
    [ -n "$1" ] && ip link show "$1" >/dev/null 2>&1
}

is_valid_client_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

is_valid_remote_target() {
    target="$1"

    [ -n "$target" ] || return 1
    printf '%s' "$target" | grep -q '[[:space:]]' && return 1

    is_valid_ipv4 "$target" && return 0
    is_valid_ipv6_address "$target" && return 0

    case "$target" in
        -*|.*|*.|*..*|*[!0-9A-Za-z.-]*) return 1 ;;
    esac

    printf '%s' "$target" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
}

detect_wan_interface() {
    wan_dev=""

    if have_cmd ubus; then
        wan_dev="$(ubus call network.interface.wan status 2>/dev/null | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p')"
    fi

    [ -z "$wan_dev" ] && wan_dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"

    printf '%s' "$wan_dev"
}

detect_default_gateway() {
    preferred_dev="$1"
    gateway=""

    if [ -n "$preferred_dev" ]; then
        gateway="$(ip -4 route show default 2>/dev/null | awk -v dev="$preferred_dev" '$0 ~ (" dev " dev "($| )") { for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
    fi

    [ -z "$gateway" ] && gateway="$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"

    printf '%s' "$gateway"
}

detect_interface_ip() {
    iface="$1"
    addr="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
    [ -z "$addr" ] && addr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')"
    printf '%s' "${addr%/*}"
}

detect_public_ip() {
    public_ip=""

    # Prefer uclient-fetch/wget first (available on fresh OpenWrt before curl is installed)
    public_ip="$(uclient-fetch -q -T 4 -O - https://api.ipify.org 2>/dev/null)"
    [ -z "$public_ip" ] && public_ip="$(wget -q -T 4 -O - https://api.ipify.org 2>/dev/null)"
    [ -z "$public_ip" ] && public_ip="$(curl -4s --max-time 4 https://api.ipify.org 2>/dev/null)"
    [ -z "$public_ip" ] && public_ip="$(curl -4s --max-time 4 https://ifconfig.me/ip 2>/dev/null)"
    [ -z "$public_ip" ] && public_ip="$(curl -4s --max-time 4 https://icanhazip.com 2>/dev/null)"

    printf '%s' "$public_ip" | tr -d '\r\n '
}

show_interface_hints() {
    title "Network Interface Hints"
    printf '%s\n' "Detected interfaces and IPv4 addresses:"

    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' ); do
        [ "$iface" = "lo" ] && continue
        ipv4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
        [ -z "$ipv4" ] && ipv4="-"
        printf '  - %-12s IPv4: %s\n' "$iface" "$ipv4"
    done

    default_route="$(ip -4 route show default 2>/dev/null | head -1)"
    [ -n "$default_route" ] && printf '\nDefault route: %s\n' "$default_route"
}

cidr2mask() {
    bits="${1#*/}"
    if [ -z "$bits" ] || [ "$bits" = "$1" ]; then
        echo "255.255.255.0"
        return
    fi

    m=0
    i=0
    while [ "$i" -lt 32 ]; do
        [ "$i" -lt "$bits" ] && m=$((m | (1 << (31 - i))))
        i=$((i + 1))
    done

    printf '%d.%d.%d.%d\n' $(((m >> 24) & 255)) $(((m >> 16) & 255)) $(((m >> 8) & 255)) $((m & 255))
}

ip2int() {
    echo "$1" | awk -F. '{print ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4}'
}

int2ip() {
    n="$1"
    printf '%d.%d.%d.%d\n' $(((n >> 24) & 255)) $(((n >> 16) & 255)) $(((n >> 8) & 255)) $((n & 255))
}

first_host_of_cidr() {
    net="${1%/*}"
    mask="$(cidr2mask "$1")"
    n_int="$(ip2int "$net")"
    m_int="$(ip2int "$mask")"
    int2ip $(((n_int & m_int) + 1))
}

generate_random_secret() {
    secret=''

    if have_cmd openssl; then
        secret="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=\r\n' | cut -c1-16)"
    fi

    if [ -z "$secret" ] && [ -r /dev/urandom ] && have_cmd od; then
        secret="$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \r\n' | cut -c1-16)"
    fi

    printf '%s' "$secret"
}

install_pkg() {
    pkg="$1"
    if opkg install "$pkg" >/dev/null 2>&1; then
        ok "Installed: $pkg"
        return 0
    fi
    warn "Could not install: $pkg"
    return 1
}

package_installed() {
    opkg status "$1" 2>/dev/null | grep -q 'Status: install ok installed'
}

root_has_password() {
    root_hash="$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)"
    [ -n "$root_hash" ] && [ "$root_hash" != "!" ] && [ "$root_hash" != "*" ]
}

setup_root_password() {
    tty_path='/dev/tty'
    entered_password=''
    generated_password=''

    title "Root Password"

    if [ -r "$tty_path" ]; then
        # Ensure terminal echo is restored on interrupt
        trap 'stty echo <"$tty_path" 2>/dev/null; trap - INT TERM' INT TERM
        printf '%s' 'Enter root password (leave empty to keep current or auto-generate if missing): ' >"$tty_path"
        stty -echo <"$tty_path" 2>/dev/null || true
        IFS= read -r entered_password <"$tty_path" || entered_password=''
        stty echo <"$tty_path" 2>/dev/null || true
        trap - INT TERM
        printf '\n' >"$tty_path"
    else
        warn "TTY unavailable. Keeping current password or generating one if root has none."
    fi

    if [ -n "$entered_password" ]; then
        if printf '%s\n%s\n' "$entered_password" "$entered_password" | passwd root >/dev/null 2>&1; then
            ROOT_PASSWORD_STATUS='updated'
            ok "Root password updated"
        else
            abort "Could not set root password."
        fi
        return 0
    fi

    if root_has_password; then
        ROOT_PASSWORD_STATUS='existing'
        info "Root password already set; leaving unchanged"
        return 0
    fi

    generated_password="$(generate_random_secret)"
    [ -n "$generated_password" ] || abort "Could not generate a fallback root password."

    if printf '%s\n%s\n' "$generated_password" "$generated_password" | passwd root >/dev/null 2>&1; then
        ROOT_PASSWORD_STATUS='generated'
        ROOT_PASSWORD_GENERATED="$generated_password"
        cat > /root/roadwarrior-credentials.txt <<EOF
root
$generated_password
EOF
        chmod 600 /root/roadwarrior-credentials.txt
        ok "Root password generated automatically"
        warn "Generated root credentials saved to /root/roadwarrior-credentials.txt"
    else
        abort "Could not set generated root password."
    fi
}

ensure_dnsmasq_full() {
    had_dnsmasq=0

    if package_installed dnsmasq-full; then
        ok "dnsmasq-full already installed"
        return 0
    fi

    package_installed dnsmasq && had_dnsmasq=1

    if opkg install dnsmasq-full >/dev/null 2>&1; then
        ok "Installed: dnsmasq-full"
        return 0
    fi

    if [ "$had_dnsmasq" -eq 1 ]; then
        warn "Direct dnsmasq-full install failed; replacing dnsmasq with rollback protection"
        opkg remove dnsmasq >/dev/null 2>&1 || abort "Could not remove dnsmasq before installing dnsmasq-full."
    fi

    if opkg install dnsmasq-full >/dev/null 2>&1; then
        ok "Installed: dnsmasq-full"
        return 0
    fi

    warn "Could not install dnsmasq-full"

    if [ "$had_dnsmasq" -eq 1 ] && ! package_installed dnsmasq; then
        if opkg install dnsmasq >/dev/null 2>&1; then
            warn "Restored dnsmasq after dnsmasq-full installation failed"
        else
            abort "Neither dnsmasq-full nor dnsmasq could be installed. DNS would be left broken."
        fi
    fi

    package_installed dnsmasq-full && return 0
    package_installed dnsmasq && return 1
    abort "Neither dnsmasq-full nor dnsmasq is installed."
}

setup_management_routing() {
    public_dev="$1"
    source_ip="$2"
    gateway="$3"

    if [ -z "$public_dev" ] || [ -z "$source_ip" ]; then
        warn "Skipping management route pinning; WAN interface or source IP is unavailable"
        return 0
    fi

    grep -qE '^[[:space:]]*200[[:space:]]+mgmt$' /etc/iproute2/rt_tables 2>/dev/null || echo '200 mgmt' >> /etc/iproute2/rt_tables

    if [ -n "$gateway" ]; then
        ip route replace table mgmt default via "$gateway" dev "$public_dev" >/dev/null 2>&1 || {
            warn "Could not install management routing table"
            return 1
        }
    else
        ip route replace table mgmt default dev "$public_dev" >/dev/null 2>&1 || {
            warn "Could not install management routing table without an explicit gateway"
            return 1
        }
    fi

    while ip rule show 2>/dev/null | grep -q 'lookup mgmt'; do
        rule_pref="$(ip rule show 2>/dev/null | awk '/lookup mgmt/ { sub(/:/, "", $1); print $1; exit }')"
        [ -n "$rule_pref" ] || break
        ip rule del pref "$rule_pref" >/dev/null 2>&1 || break
    done

    if ip rule add pref 100 from "$source_ip/32" table mgmt >/dev/null 2>&1; then
        ok "Management traffic pinned to $public_dev"
    else
        warn "Could not add management routing rule for $source_ip"
    fi
}

cleanup_tunnel_default_routes() {
    for tunnel_iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep '^tun[0-9][0-9]*$'); do
        ip route del 0.0.0.0/1 dev "$tunnel_iface" >/dev/null 2>&1 || true
        ip route del 128.0.0.0/1 dev "$tunnel_iface" >/dev/null 2>&1 || true
        ip route del default dev "$tunnel_iface" >/dev/null 2>&1 || true
        ip -6 route del ::/1 dev "$tunnel_iface" >/dev/null 2>&1 || true
        ip -6 route del 2000::/3 dev "$tunnel_iface" >/dev/null 2>&1 || true
        ip -6 route del default dev "$tunnel_iface" >/dev/null 2>&1 || true
    done
}

harden_existing_openvpn_clients() {
    title "OpenVPN Client Hardening"

    for config_file in /etc/openvpn/*.ovpn; do
        [ -f "$config_file" ] || continue
        grep -q '^route-nopull$' "$config_file" || printf '%s\n' 'route-nopull' >> "$config_file"
        grep -q '^pull-filter ignore "redirect-gateway"$' "$config_file" || printf '%s\n' 'pull-filter ignore "redirect-gateway"' >> "$config_file"
        grep -q '^pull-filter ignore "route-ipv6"$' "$config_file" || printf '%s\n' 'pull-filter ignore "route-ipv6"' >> "$config_file"
        grep -q '^pull-filter ignore "ifconfig-ipv6"$' "$config_file" || printf '%s\n' 'pull-filter ignore "ifconfig-ipv6"' >> "$config_file"
        grep -q '^script-security 2$' "$config_file" || printf '%s\n' 'script-security 2' >> "$config_file"
    done

    for section in $(uci show openvpn 2>/dev/null | sed -n 's/^openvpn\.\([^.]*\)=openvpn$/\1/p'); do
        [ "$section" = 'rw' ] && continue
        if [ "$(uci -q get openvpn.$section.client || echo 0)" = '1' ]; then
            uci set openvpn.$section.route_nopull='1'
            uci -q delete openvpn.$section.pull_filter
            uci add_list openvpn.$section.pull_filter='ignore "redirect-gateway"'
            uci add_list openvpn.$section.pull_filter='ignore "route-ipv6"'
            uci add_list openvpn.$section.pull_filter='ignore "ifconfig-ipv6"'
        fi
    done

    uci commit openvpn
    /etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn start >/dev/null 2>&1
    cleanup_tunnel_default_routes
    ok "Existing OpenVPN clients hardened"
}

write_openssl_cnf() {
    path="$1"
    cat > "$path" <<'EOF'
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
}

setup_pki() {
    pki_dir="$1"
    client_name="$2"

    mkdir -p "$pki_dir"
    write_openssl_cnf "$pki_dir/openssl.cnf"

    if [ ! -f "$pki_dir/ca.crt" ]; then
        openssl genrsa -out "$pki_dir/ca.key" 2048 >/dev/null 2>&1
        openssl req -new -x509 -days 3650 \
            -key "$pki_dir/ca.key" \
            -out "$pki_dir/ca.crt" \
            -subj "/CN=OpenWrt-VPN-CA" \
            -extensions v3_ca \
            -config "$pki_dir/openssl.cnf" >/dev/null 2>&1
        ok "Created CA certificate"
    else
        info "Using existing CA certificate"
    fi

    if [ ! -f "$pki_dir/server.crt" ]; then
        openssl genrsa -out "$pki_dir/server.key" 2048 >/dev/null 2>&1
        openssl req -new \
            -key "$pki_dir/server.key" \
            -out "$pki_dir/server.csr" \
            -subj "/CN=server" \
            -config "$pki_dir/openssl.cnf" >/dev/null 2>&1
        openssl x509 -req \
            -in "$pki_dir/server.csr" \
            -CA "$pki_dir/ca.crt" \
            -CAkey "$pki_dir/ca.key" \
            -CAcreateserial \
            -out "$pki_dir/server.crt" \
            -days 3650 \
            -extensions server \
            -extfile "$pki_dir/openssl.cnf" >/dev/null 2>&1
        ok "Created server certificate"
    else
        info "Using existing server certificate"
    fi

    if [ ! -f "$pki_dir/$client_name.crt" ]; then
        openssl genrsa -out "$pki_dir/$client_name.key" 2048 >/dev/null 2>&1
        openssl req -new \
            -key "$pki_dir/$client_name.key" \
            -out "$pki_dir/$client_name.csr" \
            -subj "/CN=$client_name" \
            -config "$pki_dir/openssl.cnf" >/dev/null 2>&1
        openssl x509 -req \
            -in "$pki_dir/$client_name.csr" \
            -CA "$pki_dir/ca.crt" \
            -CAkey "$pki_dir/ca.key" \
            -CAcreateserial \
            -out "$pki_dir/$client_name.crt" \
            -days 3650 \
            -extensions client \
            -extfile "$pki_dir/openssl.cnf" >/dev/null 2>&1
        ok "Created client certificate: $client_name"
    else
        info "Using existing client certificate: $client_name"
    fi

    if [ ! -f "$pki_dir/tc.key" ]; then
        openvpn --genkey secret "$pki_dir/tc.key" >/dev/null 2>&1
        ok "Created tls-crypt key"
    fi
}

setup_openvpn_uci() {
    pki_dir="$1"
    port="$2"
    vpn4_cidr="$3"
    vpn6_cidr="$4"

    v4_net="${vpn4_cidr%/*}"
    v4_mask="$(cidr2mask "$vpn4_cidr")"
    dns_push="$(first_host_of_cidr "$vpn4_cidr")"

    uci -q delete openvpn.rw
    uci set openvpn.rw=openvpn
    uci set openvpn.rw.enabled='1'
    uci set openvpn.rw.dev='tun'
    uci set openvpn.rw.proto='udp'
    uci set openvpn.rw.port="$port"
    uci set openvpn.rw.topology='subnet'
    uci set openvpn.rw.server="$v4_net $v4_mask"
    uci set openvpn.rw.server_ipv6="$vpn6_cidr"
    uci set openvpn.rw.keepalive='10 60'
    uci set openvpn.rw.persist_key='1'
    uci set openvpn.rw.persist_tun='1'
    uci set openvpn.rw.explicit_exit_notify='1'
    uci add_list openvpn.rw.data_ciphers='AES-256-GCM'
    uci add_list openvpn.rw.data_ciphers='AES-128-GCM'
    uci set openvpn.rw.data_ciphers_fallback='AES-256-GCM'
    uci set openvpn.rw.tls_server='1'
    uci set openvpn.rw.tls_version_min='1.2'
    uci set openvpn.rw.ca="$pki_dir/ca.crt"
    uci set openvpn.rw.cert="$pki_dir/server.crt"
    uci set openvpn.rw.key="$pki_dir/server.key"
    uci set openvpn.rw.dh='none'
    uci add_list openvpn.rw.push='redirect-gateway def1'
    uci add_list openvpn.rw.push='redirect-gateway ipv6'
    uci add_list openvpn.rw.push="dhcp-option DNS $dns_push"
    uci add_list openvpn.rw.push='block-outside-dns'
    uci set openvpn.rw.tls_crypt="$pki_dir/tc.key"
    uci set openvpn.rw.status='/tmp/openvpn-status.log'
    uci set openvpn.rw.log='/tmp/openvpn.log'
    uci set openvpn.rw.verb='3'
    uci commit openvpn

    /etc/init.d/openvpn enable >/dev/null 2>&1
    /etc/init.d/openvpn restart >/dev/null 2>&1 || /etc/init.d/openvpn start >/dev/null 2>&1
    ok "OpenVPN service configured and started"
}

detect_network_name_by_device() {
    dev="$1"

    for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
        sec_dev="$(uci -q get network.$sec.device)"
        [ -z "$sec_dev" ] && sec_dev="$(uci -q get network.$sec.ifname)"

        if [ "$sec_dev" = "$dev" ]; then
            printf '%s' "$sec"
            return
        fi

        echo " $sec_dev " | grep -q " $dev " && {
            printf '%s' "$sec"
            return
        }
    done

    printf '%s' "wan"
}

detect_firewall_zone_by_network() {
    net_name="$1"

    for zone in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
        zone_nets="$(uci -q get firewall.$zone.network)"
        echo " $zone_nets " | grep -q " $net_name " && {
            zone_name="$(uci -q get firewall.$zone.name)"
            [ -z "$zone_name" ] && zone_name="$zone"
            printf '%s' "$zone_name"
            return
        }
    done

    printf '%s' "wan"
}

setup_firewall() {
    port="$1"
    wan_zone="$2"
    [ -z "$wan_zone" ] && wan_zone="wan"

    uci -q delete network.vpn
    uci set network.vpn=interface
    uci set network.vpn.device='tun0'
    uci set network.vpn.proto='none'
    uci set network.vpn.auto='1'
    uci commit network
    /etc/init.d/network reload >/dev/null 2>&1

    uci -q delete firewall.vpn
    uci set firewall.vpn=zone
    uci set firewall.vpn.name='vpn'
    uci set firewall.vpn.network='vpn'
    uci set firewall.vpn.input='ACCEPT'
    uci set firewall.vpn.output='ACCEPT'
    uci set firewall.vpn.forward='ACCEPT'
    uci set firewall.vpn.masq='0'
    uci set firewall.vpn.mtu_fix='1'

    uci -q delete firewall.allow_openvpn
    uci set firewall.allow_openvpn=rule
    uci set firewall.allow_openvpn.name='Allow-OpenVPN-UDP'
    uci set firewall.allow_openvpn.src="$wan_zone"
    uci set firewall.allow_openvpn.proto='udp'
    uci set firewall.allow_openvpn.dest_port="$port"
    uci set firewall.allow_openvpn.target='ACCEPT'

    uci -q delete firewall.vpn_to_wan
    uci set firewall.vpn_to_wan=forwarding
    uci set firewall.vpn_to_wan.src='vpn'
    uci set firewall.vpn_to_wan.dest="$wan_zone"

    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1

    # Make IP forwarding persistent via sysctl.conf
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    # Upstream DNS for dnsmasq (prevent empty resolv after VPN setup)
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci -q del dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    uci commit dhcp
    /etc/init.d/dnsmasq restart >/dev/null 2>&1

    ok "Firewall and forwarding configured"
}

setup_passwall_optional() {
    title "Optional: Passwall Setup"

    prompt_yes_no "Install Passwall feeds and GUI now?" "Y" || {
        info "Skipping Passwall setup"
        return
    }

    key_url="https://sourceforge.net/projects/openwrt-passwall-build/files/ipk.pub/download"
    release="$(sed -n "s/^DISTRIB_RELEASE='\([^']*\)'.*/\1/p" /etc/openwrt_release 2>/dev/null | awk -F. '{print $1"."$2}')"
    arch="$(opkg print-architecture 2>/dev/null | awk '$1=="arch"{print $2" "$3}' | sort -k2,2n | tail -1 | awk '{print $1}')"

    [ -z "$release" ] && release="24.10"
    [ -z "$arch" ] && arch="x86_64"
    mkdir -p /etc/opkg/keys

    if uclient-fetch -q -T 15 -O /etc/opkg/keys/ipk.pub "$key_url" || wget -q -O /etc/opkg/keys/ipk.pub "$key_url"; then
        opkg-key add /etc/opkg/keys/ipk.pub >/dev/null 2>&1 || true
        ok "Passwall signing key added"
    else
        warn "Could not download passwall signing key"
    fi

    sed -i '/passwall_packages\|passwall_luci\|passwall2/d' /etc/opkg/customfeeds.conf 2>/dev/null
    cat >> /etc/opkg/customfeeds.conf <<EOF
src/gz passwall_luci https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall_luci
src/gz passwall_packages https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall_packages
src/gz passwall2 https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall2
EOF

    if opkg update >/dev/null 2>&1; then
        opkg install luci-app-passwall >/dev/null 2>&1 || opkg install luci-app-passwall2 >/dev/null 2>&1 || warn "Could not install Passwall GUI"
        opkg install xray-core >/dev/null 2>&1 || opkg install sing-box >/dev/null 2>&1 || warn "Could not install xray-core/sing-box"
    else
        warn "opkg update failed for passwall feeds; skipping optional Passwall package installation"
        return
    fi

    ok "Passwall optional setup done"
}

generate_client_ovpn() {
    pki_dir="$1"
    client_name="$2"
    public_ip="$3"
    port="$4"

    [ -z "$public_ip" ] && public_ip="YOUR_PUBLIC_IP"

    out_file="/root/${client_name}.ovpn"
    cat > "$out_file" <<EOF
client
float
dev tun
proto udp
remote $public_ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
block-outside-dns
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM
cipher AES-256-GCM
verb 3
<tls-crypt>
$(cat "$pki_dir/tc.key")
</tls-crypt>
<ca>
$(cat "$pki_dir/ca.crt")
</ca>
<cert>
$(cat "$pki_dir/$client_name.crt")
</cert>
<key>
$(cat "$pki_dir/$client_name.key")
</key>
EOF

    chmod 600 "$out_file"
    ok "Generated client file: $out_file"
}

publish_client_file() {
    client_name="$1"
    changed='0'
    rm -f /usr/sbin/rw-unpublish
    rm -f /www/vpn/*.ovpn /www/vpn/index.html /www/vpn/openvpn.log
    rmdir /www/vpn 2>/dev/null || true

    for section in $(uci show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^.]*\)=uhttpd$/\1/p'); do
        if [ "$(uci -q get "uhttpd.$section.home")" = "/www/vpn" ]; then
            uci -q delete "uhttpd.$section"
            changed='1'
        fi
    done

    if [ "$changed" = '1' ]; then
        uci commit uhttpd >/dev/null 2>&1 || true
    fi

    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    info "Static web publication is disabled. Retrieve /root/${client_name}.ovpn over SSH, SCP, or SFTP."
}

write_helpers() {
    cat > /usr/sbin/rw-fix <<'EOF'
#!/bin/sh

printf '\033[1;32m[rw-fix]\033[0m %s\n' "Cleaning tunnel default routes and restarting services..."
for tunnel_iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep '^tun[0-9][0-9]*$'); do
    ip route del 0.0.0.0/1 dev "$tunnel_iface" 2>/dev/null || true
    ip route del 128.0.0.0/1 dev "$tunnel_iface" 2>/dev/null || true
    ip route del default dev "$tunnel_iface" 2>/dev/null || true
    ip -6 route del ::/1 dev "$tunnel_iface" 2>/dev/null || true
    ip -6 route del 2000::/3 dev "$tunnel_iface" 2>/dev/null || true
    ip -6 route del default dev "$tunnel_iface" 2>/dev/null || true
done
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/openvpn restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true
printf '\033[1;32m[rw-fix]\033[0m %s\n' "Done."
EOF

    chmod +x /usr/sbin/rw-fix

    cat > /usr/sbin/rw-help <<'EOF'
#!/bin/sh

echo "RoadWarrior Helper"
echo "-----------------"
echo "Rescue command: rw-fix"
echo ""
echo "OpenVPN status:"
/etc/init.d/openvpn status 2>/dev/null || true
echo ""
echo "OpenVPN port listeners:"
netstat -lupn 2>/dev/null | grep -E 'openvpn|:1194' || true
echo ""
echo "Last OpenVPN logs:"
logread -e openvpn 2>/dev/null | tail -n 40 || true
echo ""
echo "Connected clients:"
cat /tmp/openvpn-status.log 2>/dev/null || echo "No status file yet"
EOF

    chmod +x /usr/sbin/rw-help
    ok "Installed helper commands: rw-fix, rw-help"
}

main() {
    title "RoadWarrior One-Command Installer"

    require_root
    check_platform

    show_interface_hints

    WAN_DEFAULT="$(detect_wan_interface)"
    PUB_DEFAULT="$(detect_public_ip)"

    prompt_validated_value "WAN interface" "$WAN_DEFAULT" "Tip: usually default-route interface" check_interface "Selected network interface does not exist."
    WAN_IF="$PROMPT_RESULT"
    prompt_validated_value "OpenVPN UDP port" "1194" "Tip: 1194 is standard" is_valid_port "Enter a numeric port between 1 and 65535."
    OVPN_PORT="$PROMPT_RESULT"
    prompt_validated_value "Client profile name" "client1" "Tip: use letters/numbers/_/- only" is_valid_client_name "Use only letters, numbers, underscore, or dash."
    CLIENT_NAME="$PROMPT_RESULT"
    prompt_validated_value "VPN IPv4 subnet (CIDR)" "10.99.0.0/24" "Tip: avoid overlap with LAN" is_valid_ipv4_cidr "Enter a valid IPv4 CIDR such as 10.99.0.0/24."
    VPN4_CIDR="$PROMPT_RESULT"
    prompt_validated_value "VPN IPv6 subnet (CIDR)" "fd42:4242:4242:1::/64" "Tip: keep default unless needed" is_valid_ipv6_cidr "Enter a valid IPv6 CIDR such as fd42:4242:4242:1::/64."
    VPN6_CIDR="$PROMPT_RESULT"
    prompt_validated_value "Public server IP or hostname" "$PUB_DEFAULT" "Detected automatically; edit if needed" is_valid_remote_target "Enter a valid IPv4, IPv6, or hostname value."
    PUBLIC_IP="$PROMPT_RESULT"

    WAN_NET="$(detect_network_name_by_device "$WAN_IF")"
    WAN_ZONE="$(detect_firewall_zone_by_network "$WAN_NET")"
    WAN_SOURCE_IP="$(detect_interface_ip "$WAN_IF")"
    WAN_GATEWAY="$(detect_default_gateway "$WAN_IF")"
    info "Selected WAN device: $WAN_IF"
    info "Resolved WAN network: $WAN_NET"
    info "Resolved WAN firewall zone: $WAN_ZONE"
    info "Resolved WAN source IPv4: ${WAN_SOURCE_IP:-unknown}"
    info "Resolved WAN gateway: ${WAN_GATEWAY:-direct-link}"

    title "Package Installation"
    info "Running opkg update..."
    opkg update >/dev/null 2>&1 || abort "opkg update failed; check internet/time/CA and rerun."

    install_pkg ca-bundle
    install_pkg curl
    install_pkg wget
    install_pkg jq
    install_pkg ip-full
    install_pkg openssl-util
    install_pkg luci
    install_pkg luci-ssl
    install_pkg luci-compat
    install_pkg luci-app-openvpn
    install_pkg openvpn-openssl
    install_pkg kmod-tun
    ensure_dnsmasq_full

    setup_root_password

    setup_passwall_optional

    title "OpenVPN PKI"
    PKI_DIR="/etc/openvpn/pki"
    setup_pki "$PKI_DIR" "$CLIENT_NAME"

    title "OpenVPN + Firewall"
    setup_openvpn_uci "$PKI_DIR" "$OVPN_PORT" "$VPN4_CIDR" "$VPN6_CIDR"
    setup_firewall "$OVPN_PORT" "$WAN_ZONE"
    setup_management_routing "$WAN_IF" "$WAN_SOURCE_IP" "$WAN_GATEWAY"
    harden_existing_openvpn_clients

    title "Client Configuration"
    generate_client_ovpn "$PKI_DIR" "$CLIENT_NAME" "$PUBLIC_IP" "$OVPN_PORT"
    publish_client_file "$CLIENT_NAME"
    write_helpers

    title "Done"
    SCP_TARGET="$PUBLIC_IP"
    case "$SCP_TARGET" in
        *:*) SCP_TARGET="[$SCP_TARGET]" ;;
    esac
    printf 'LuCI URL: https://%s\n' "$PUBLIC_IP"
    printf 'OpenVPN file: /root/%s.ovpn\n' "$CLIENT_NAME"
    printf 'OpenVPN web publish: disabled\n'
    printf 'SCP example: scp root@%s:/root/%s.ovpn .\n' "$SCP_TARGET" "$CLIENT_NAME"
    if [ "$ROOT_PASSWORD_STATUS" = 'generated' ]; then
        printf 'Generated root credentials: /root/roadwarrior-credentials.txt\n'
    fi
    printf 'Rescue command: rw-fix\n'
    printf 'Status command: rw-help\n'
    printf '\n'
    ok "RoadWarrior setup finished"
}

main "$@"
