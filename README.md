# AntiDetect Router (beta) v.0.5.1

> **Status:** ⚠️ Early beta – expect bugs, rough edges and sharp corners.  
> **Author:** Vektor T13  
> **Website:** [detect.expert](https://detect.expert)

## 🧩 Changelog — v0.5.1 (Patch Update) (credit: [**Shatzki_alone**](https://t.me/Shatzki_alone))

**Status:** ⚠️ Beta patch update  
**Author:** @Shatzki_alone

### ✅ Upstream Runtime Patch (RWPATCH)

This release hardens and fixes the integrated RWPATCH runtime to ensure
correct routing, DNS behaviour, and leak-free operation in raw nftables mode.

### 🔒 Kill Switch — Reworked (Critical Fix)

- Kill Switch logic has been **fully reimplemented**
- ❌ Removed dependency on `fw4` firewall (fw4 is intentionally disabled)
- ❌ Removed interface detection by hardcoded name (`rw*`)
- ✅ RW interface is now resolved dynamically:
  - `uci get openvpn.rw.dev`
  - fallback to `tun0`
- ✅ Kill Switch rules are installed into a **dedicated nftables table**:
  - `inet rwks`
  - This table is **not modified** by Passwall or firewall scripts
- ✅ When no outbound VPN is active:
  - RW client traffic to the public internet is **fully blocked**
  - Access to private RFC1918 networks is **allowed**
- ✅ Prevents all known IP-leak scenarios:
  - outbound VPN down
  - restart
  - crash
  - switch failure

### 🌐 DNS Handling Cleanup

- `openvpn-hotplug` is **fully deprecated and removed**
- All DNS logic is now handled exclusively by:
  - `vpn-dns-monitor.sh`
  - `dual-vpn-switcher.sh`
- Ensures:
  - DNS always follows the active outbound VPN (`tunX`)
  - No DNS leaks on VPN drop or reconnect
  - No reliance on OpenVPN up/down hooks when `RWPATCH_ENABLE=1`

### 🧠 universal-client-monitor.sh — WAN/Gateway Fix

- Fixed critical issue with **hardcoded network values**:
  - ❌ `WAN_IF=br-lan`
  - ❌ static gateway values
- WAN interface and gateway are now:
  - detected from the running system
  - automatically patched after Web UI installation
- Prevents accidental SSH / LuCI lock-out after patch installation

### 🧩 Web UI Integration Safety

- Web UI installation no longer breaks runtime scripts
- Post-install patching ensures consistency between:
  - `/root/*.sh`
  - `/www/cgi-bin/vektort13/*.sh`
- Web UI now reflects **real runtime state**, not assumed defaults

### 🔁 Runtime Stability Improvements

- Kill Switch logic moved to **`dual-vpn-switcher.sh`**
  - single source of truth
- Removed duplicate / early Kill Switch rules from the main installer
- Prevents conflicting nftables rules during boot and restarts
- Improves compatibility with:
  - Passwall
  - multiple outbound OpenVPN clients
  - raw nftables routing mode

### ⚠️ Important Notes

- `fw4` firewall remains **intentionally disabled**
- Kill Switch does **not** appear in LuCI firewall views
- Kill Switch rules can be inspected via:
  ```sh
  nft list table inet rwks

## 🧩 Changelog — v0.3.0

### ✅ Upstream patch: **RWPATCH runtime** (credit: [**Shatzki_alone**](https://t.me/Shatzki_alone))

RWPATCH is a set of helper scripts that provides the “smart runtime” for this router:

- `start-all.sh` — launches RW server + monitors, adds autostart to `rc.local`
- `dual-vpn-switcher.sh` — main controller: switches Passwall/OpenVPN modes, manages fw4, starts monitors
- `upstream-monitor.sh` — watches upstream `tun*` and triggers `rw-fix` when needed
- `universal-client-monitor.sh` — SSH/LuCI protection (adds `/32` routes to prevent lock-out)
- `vpn-dns-monitor.sh` — DNS follower (keeps `dnsmasq` using DNS from active outbound VPN)
- `mega-snapshot.sh` — diagnostics bundle generator
- `rw-fix` — emergency “panic button” to recover routing/DNS

### ✅ AntiDetect Router changes (our integration)

What this project adds on top of RWPATCH:

- Auto-download + install RWPATCH files from GitHub into the **exact paths** expected by the patch README:
  - `/root/*.sh` and `/usr/sbin/rw-fix`
- Safer install flow:
  - backups for existing files (`*.bak.<timestamp>`)
  - **abort patch autostart/start** if any download failed
- Upstream OpenVPN autodetection wrapper:
  - generates `/root/dual-vpn-autodetect.sh`
  - patches `start-all.sh` to run the wrapper (so upstream client name is detected from UCI)
- Patches `universal-client-monitor.sh` with detected:
  - `WAN_IF="<public dev>"`
  - `GATEWAY="<public gw>"`
- OpenVPN TLS-crypt key hardening:
  - `tc.key` is **not regenerated** if it already exists (old `.ovpn` remains valid)
- uhttpd safety:
  - does **not** create extra uhttpd instances with `home=/www/vpn`
  - removes old conflicting instances if they exist
- Final checks:
  - firewall status is informational (script uses raw nft)
  - port check uses `ss` with fallback to `netstat`
---

AntiDetect Router is a one‑shot shell script that turns a clean OpenWrt 24.10.x (x86_64) VPS into a **VPS‑friendly “road‑warrior” hub** with:

- an inbound **OpenVPN server** for your devices,  
- optional **outbound VPN / proxy chain** via Passwall + Xray/sing‑box,  
- **policy‑based routing (PBR)** that sends VPN clients out through external tun* interfaces,  
- smart **DNS routing** that automatically follows the active outbound VPN,  
- a minimal **web landing page** to grab your `.ovpn` file and LuCI login details.

Everything is configured automatically from a single script: certificates, OpenVPN, nftables, routing tables, LuCI, DNS, and helper utilities.

---

## ⚠️ IMPORTANT WARNINGS – READ BEFORE USE

> ❗ This project is an **beta‑stage tool for advanced users**, not a polished consumer product.

- **IPv6 support vs VPS providers**  
  The script includes full logic for **IPv6 routing and OpenVPN IPv6 pools**.  
  However, some VPS providers (for example, DigitalOcean with custom OS images) **do not properly support IPv6 on custom images**.  
  If your provider breaks or silently ignores IPv6 on custom OpenWrt images, IPv6 parts of this setup will not work as intended.  
  👉 **Choose a sane VPS provider** that:
  - gives you real IPv6 addresses, and  
  - supports IPv6 correctly for your chosen image (including OpenWrt).

- **Outbound VPN with username/password authentication**  
  The script itself does not hard‑code any specific username/password for outbound VPNs.  
  If your upstream VPN **requires login/password authentication**, you’ll need to adjust the outbound OpenVPN / Passwall node configuration accordingly.  
  For a practical, step‑by‑step explanation on how to wire authentication correctly, **watch the training video on the YouTube channel _VectorT13_** and follow the recommended auth layout there.

- **beta quality**  
  - Configs, defaults and behaviour **may change** between versions.  
  - Do not rely on this for critical production infrastructure.  
  - Always test on a throwaway VPS before rolling it into anything serious.

---

## What this project is

AntiDetect Router is designed for **VPS installations of OpenWrt 24.10.x (x86_64)** – for example on DigitalOcean and similar providers. The script assumes:

- a publicly routable IPv4 address,  
- OpenWrt preinstalled on the VPS,  
- root access via SSH.

After running the script, you get:

- a **ready‑to‑use OpenVPN “road‑warrior” server** (`tun0`) for your devices,  
- a configurable **pass‑through / “double‑hop” pipeline** where:
  - clients connect _into_ your VPS via your OpenVPN server,  
  - their traffic exits _out_ via an **external VPN / proxy** (tunX or Passwall backend),  
- a **fixed management path**: the router itself (SSH / LuCI) always goes directly via the VPS’ public interface, never through the outbound VPN.

This makes the box behave more like an **“AntiDetect edge node”** than just a simple VPN server.

---

## Core components

The script wires up the following building blocks:

## Target OS / reference image

AntiDetect Router (beta) was developed and tested on:

- **OpenWrt 24.10.4 (x86/64)**
  - Official download tree: `https://downloads.openwrt.org/releases/24.10.4/targets/x86/64/`
  - Reference image: `generic-ext4-combined-efi.img.gz`

Other OpenWrt 24.10.x x86_64 builds may work, but the image above is the **reference environment** this script was built and verified against.

### Base system

- **OS:** OpenWrt 24.10.x (x86_64)  
- **Web UI:** LuCI + `uhttpd` (HTTPS enabled)  
- **Resolver:** `dnsmasq-full`  
- **Firewall:** built‑in `fw4` service is stopped; all NAT/PBR logic uses **raw nftables + iproute2** instead.

### VPN core

- **VPN server:** `openvpn-openssl` (road‑warrior style, `dev tun`)  
- **Topology:** `topology subnet` + IPv4/IPv6 server pools  
- **Crypto / data plane:**
  - `cipher none`
  - `auth none`
  - TLS 1.2+ with **TLS‑crypt** (`tc.key`) and a local CA
  - Encryption is handled at the TLS layer only; the data channel is intentionally “no‑cipher” for speed and simplicity.
- **Server features:**
  - Auto‑generated CA + server and client certificates
  - Auto‑generated client config file `<client>.ovpn`
  - `redirect-gateway def1` + `redirect-gateway ipv6` pushed to clients
  - DNS push: clients receive **VPN server’s tun0 IP** as DNS
  - Status + log files: `/tmp/openvpn-status.log`, `/tmp/openvpn.log`

### Outbound VPN / Proxy core

AntiDetect Router is designed to sit **between your devices and another exit‑node**:

- Optional **Passwall GUI**:
  - Feeds for `passwall_luci`, `passwall_packages`, `passwall2` are installed.
  - Installs **`luci-app-passwall`** or **`luci-app-passwall2`** (whichever succeeds).
- Proxy engines:
  - **`xray-core`** (preferred) _or_ **`sing-box`** as fallback.
- You can define:
  - Xray / sing‑box nodes,
  - Socks5/OpenVPN upstreams,
  - Access rules in **LuCI → Services → Passwall**.

The script does **not** create your proxy nodes for you; it simply ensures the stack is installed and ready.

---

## DNS behaviour

> **RWPATCH note (important):**  
> By default `RWPATCH_ENABLE=1`, so DNS “following the outbound VPN” is handled by the patch monitor:  
> **`/root/vpn-dns-monitor.sh`**.  
> In this mode the built-in OpenVPN hook **`/etc/openvpn/rw-dyn-dns.sh` is NOT used** (the script skips/removes it).  
>
> If you set `RWPATCH_ENABLE=0`, the script falls back to installing and using `rw-dyn-dns.sh` via OpenVPN `up/down` hooks.

AntiDetect Router includes a fairly advanced DNS setup so that **DNS follows the active outbound VPN**:

1. **Clients’ DNS:**
   - OpenVPN server pushes `dhcp-option DNS <server-tun-IP>` to connecting clients.
   - `dnsmasq` listens on `tun0` and answers DNS for the RW subnet.

2. **Router’s upstream DNS logic:**
   - By default, `dnsmasq` uses the VPS’ **system resolvers** (from `resolv.conf.auto`).
   - When an **outbound OpenVPN client** is connected, an `up/down` hook script  
     `/etc/openvpn/rw-dyn-dns.sh`:
     - parses `foreign_option_n` for `dhcp-option DNS` from the remote server,
     - rewrites `dhcp.@dnsmasq[0].server` to point to those DNS servers,
     - pins them (optionally) to the outbound interface (`dev`),
     - on `down`, restores normal system DNS.

Result:  
- If outbound VPN is **up** → router + RW clients resolve through **DNS of that outbound VPN**.  
- If outbound VPN is **down** → everything falls back to **VPS’ own resolvers**.

---

## Routing & NAT

- **IP forwarding:** enabled for IPv4 and IPv6.  
- **Reverse path filtering:** disabled on all interfaces (for asymmetric routing across tun devices).  
- **Management table (`mgmt`):**
  - A dedicated `ip rule` + `rt_tables` entry ensures all traffic **from** the VPS’ public IP goes out via the main interface and default gateway.
  - Prevents SSH / LuCI from being accidentally routed into or through tun*.
- **RW client PBR:**
  - A separate table `vpnout` is created.
  - Traffic **coming from the OpenVPN server interface** (RW subnet) can be policy‑routed out via an external tunX (e.g. outbound OpenVPN client or Passwall chain).
- **NAT:**
  - `nftables` table `inet rwfix` with `postrouting` chain:
    - Masquerades all traffic **originating from the RW interface** (`tun0` by default) when it leaves through any other interface.

---

## LuCI & language support

The script installs LuCI and several language packs so the web UI can be localized:

- **Base LuCI translations:**
  - `luci-i18n-base-ru` – Russian  
  - `luci-i18n-base-zh-cn` – Simplified Chinese  
  - `luci-i18n-base-vi` – Vietnamese  
  - `luci-i18n-base-es` – Spanish  
- **App‑specific translations:**
  - `luci-i18n-openvpn-ru` – OpenVPN app in Russian  
  - `luci-i18n-firewall-ru` – Firewall app in Russian  

The core script messages and README are in **English**, but once you log into LuCI you can switch the interface language (System → System → Language and Style) to any installed locale.

---

## Generated artifacts & helper tools

After running the script you get:

- `/root/<client>.ovpn` — road‑warrior client profile.  
- `/www/vpn/<client>.ovpn` — same profile, downloadable over HTTPS.  
- `/www/vpn/index.html` — minimal landing page with:
  - download link for the client config,
  - LuCI URL (`https://<VPS_IP>`),
  - direct VPN config (`https://<VPS_IP>/vpn`),
  - root username and password reminder.
- `/usr/sbin/rw-fix` — “panic button” to:
  - remove hijacked `/1` default routes on tun+,
  - reset IPv4/IPv6 defaults,
  - restart `dnsmasq` and OpenVPN.

---

## ⚠️ Installation ⚠️

### Prerequisites

> - A fresh **OpenWrt 24.10.4 x86_64** VPS  
> - Tested reference image: `generic-ext4-combined-efi.img.gz`  
> - Root SSH access (or at least provider console access to start with)

---

### 1. Connect to the VPS

Use your provider’s console or SSH.

If SSH is not yet available, use the VPS provider’s **Recovery/Console** access.

Once you have a shell on the VPS, configure the `lan` interface to use DHCP so the system can obtain network connectivity:

    uci set network.lan.proto='dhcp'
    uci commit network
    ifup lan

After a few seconds the VPS should obtain an IP address from the provider and have internet connectivity.

---

### 2. Set the root password

For security and for LuCI login later:

    passwd

Enter a strong password twice.  
This password will also be used for **LuCI** (`root` user).

---

### 3. Reconnect by SSH

If you were using the recovery console, now reconnect via SSH using the new password:

    ssh root@YOUR_VPS_IP

Replace `YOUR_VPS_IP` with the actual public IP address of your VPS.

---

### 4. Update package list and install tools

Update `opkg` and install `curl` (we’ll use it to download the script):

    opkg update
    opkg install curl

`wget` is usually present by default; if not, you can also run:

    opkg install wget

---

### 5. Download and run the AntiDetect Router script

Download the script into `/root` using the **raw** GitHub URL (not the `blob` page), make it executable and run it:

    cd /root

    wget -O antidetectrouter.sh \
      https://raw.githubusercontent.com/vektort13/AntidetectRouter/main/AntidetectRouter.sh

    chmod +x /root/antidetectrouter.sh
    sh /root/antidetectrouter.sh

💡 Make sure you run this as **root**.

---

### 6. Answer script prompts

During the first run, the script will ask you a few questions:

#### OpenVPN port (UDP)

Prompt:

    OpenVPN port (UDP) [1194]:

You can usually keep `1194`, or enter any other UDP port that is open on your VPS firewall/provider.

#### Client name (ovpn file)

Prompt:

    Client name (ovpn file) [client1]:

This name will be used for the generated profile, e.g.:

    /root/client1.ovpn

You can set something like `laptop`, `phone`, `home-pc`, etc.

#### VPN IPv4 subnet

Prompt:

    VPN IPv4 subnet [10.99.0.0/24]:

Internal IPv4 network for road‑warrior clients.

- Default `10.99.0.0/24` is fine in most cases.
- Make sure it does **not overlap** with networks on your local devices (e.g. home `192.168.x.x`).

#### VPN IPv6 subnet

Prompt:

    VPN IPv6 subnet [fd42:4242:4242:1::/64]:

Internal IPv6 network for road‑warrior clients.

- You can keep the default ULA prefix.
- IPv6 routing will only work correctly if your VPS provider properly supports IPv6 for your image.

---

### 7. What the script does next

After you answer these prompts, the script will:

- install all required packages:
  - **LuCI**
  - **OpenVPN**
  - **Passwall**
  - **xray-core / sing-box**
  - **dnsmasq-full**
  - LuCI language packs, etc.
- set up the **road‑warrior OpenVPN server** on `tun0`,
- configure **nftables NAT + policy‑based routing (PBR)**,
- wire the **DNS logic**:
  - router DNS follows the active outbound VPN,
  - clients use the VPN server itself as DNS,
- generate a client profile at:

      /root/<client>.ovpn

- publish it via HTTPS at:

      https://YOUR_VPS_IP/vpn/

- show final connection details and a quick rescue command:

      /usr/sbin/rw-fix

- (Default) installs and starts the RWPATCH runtime (`/root/start-all.sh` + monitors + `/usr/sbin/rw-fix`)
- ensures autostart via `/etc/rc.local`:
  ```sh
  sleep 10
  /root/start-all.sh &
  exit 0


You can then:

1. Download `<client>.ovpn` from `https://YOUR_VPS_IP/vpn/`  
2. Import it into your OpenVPN client  
3. Log into LuCI at `https://YOUR_VPS_IP` using:

       username: root
       password: <the password you set with passwd or via the script>



This is the **beta** foundation of AntiDetect Router: a scripted, reproducible OpenWrt setup that glues together OpenVPN, advanced DNS behaviour, nftables‑based PBR, and Passwall/Xray/sing‑box into a single VPS‑ready router.
