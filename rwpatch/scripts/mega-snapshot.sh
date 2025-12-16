#!/bin/sh
# mega-snapshot.sh - МАКСИМАЛЬНАЯ диагностика
# Собирает ВСЁ для анализа
# Usage: ./mega-snapshot.sh <name>

if [ -z "$1" ]; then
    echo "Usage: $0 <snapshot-name>"
    echo "Example: $0 working-passwall"
    exit 1
fi

NAME="$1"
DIR="/root/snapshots/$NAME"
TIME=$(date '+%Y-%m-%d_%H-%M-%S')

echo "========================================"
echo "MEGA SNAPSHOT: $NAME"
echo "========================================"
echo "Time: $TIME"
echo ""

mkdir -p "$DIR"
cd "$DIR" || exit 1

# ==================== SYSTEM INFO ====================
echo "[1/40] System info..."
cat > system-info.txt << EOF
=== SYSTEM INFO ===
Time: $TIME
Hostname: $(hostname)
Uptime: $(uptime)
Kernel: $(uname -a)
Load: $(cat /proc/loadavg)
Memory: $(free)
EOF

# ==================== NETWORK INTERFACES ====================
echo "[2/40] Network interfaces..."
ip link show > ip-link.txt 2>&1
ip -4 addr show > ip-addr-ipv4.txt 2>&1
ip -d link show > ip-link-detailed.txt 2>&1

# Stats for ALL interfaces
ip -s link show > ip-link-stats.txt 2>&1

# ==================== ROUTING ====================
echo "[3/40] Routing tables..."
ip route show > ip-route-main.txt 2>&1
ip route show table all > ip-route-all.txt 2>&1

# All specific tables
for table in mgmt vpnout 100 101 102; do
    ip route show table $table > ip-route-$table.txt 2>&1
done

# ==================== IP RULES ====================
echo "[4/40] IP rules..."
ip rule show > ip-rule.txt 2>&1
ip -d rule show > ip-rule-detailed.txt 2>&1

# ==================== RT_TABLES ====================
echo "[5/40] Routing tables config..."
cat /etc/iproute2/rt_tables > rt_tables.txt 2>&1

# ==================== NFTABLES FULL ====================
echo "[6/40] nftables FULL dump..."
nft list ruleset > nftables-ruleset-full.txt 2>&1
nft list tables > nftables-tables.txt 2>&1

# Each table separately
for table in fw4 passwall passwall2 rwfix; do
    if nft list table inet $table >/dev/null 2>&1; then
        nft list table inet $table > nftables-table-$table.txt 2>&1
    fi
done

# ==================== NFTABLES SETS (CRITICAL!) ====================
echo "[7/40] nftables sets..."
cat > nftables-sets-passwall.txt << 'EOF'
=== PASSWALL NFTABLES SETS ===

EOF

if nft list table inet passwall >/dev/null 2>&1; then
    echo "=== passwall_lan (LOCAL - NOT PROXIED) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_lan >> nftables-sets-passwall.txt 2>&1
    echo "" >> nftables-sets-passwall.txt
    
    echo "=== passwall_vps (VPS - NOT PROXIED) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_vps >> nftables-sets-passwall.txt 2>&1
    echo "" >> nftables-sets-passwall.txt
    
    echo "=== passwall_white (WHITELIST) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_white >> nftables-sets-passwall.txt 2>&1
    echo "" >> nftables-sets-passwall.txt
    
    echo "=== passwall_black (BLACKLIST - ALWAYS PROXY) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_black >> nftables-sets-passwall.txt 2>&1
    echo "" >> nftables-sets-passwall.txt
    
    echo "=== passwall_gfw (GFW - ALWAYS PROXY) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_gfw >> nftables-sets-passwall.txt 2>&1
    echo "" >> nftables-sets-passwall.txt
    
    echo "=== passwall_chn (CHINA - DIRECT) ===" >> nftables-sets-passwall.txt
    nft list set inet passwall passwall_chn >> nftables-sets-passwall.txt 2>&1
fi

# ==================== NFTABLES CHAINS ====================
echo "[8/40] nftables chains..."
cat > nftables-chains-passwall.txt << 'EOF'
=== PASSWALL NFTABLES CHAINS ===

EOF

if nft list table inet passwall >/dev/null 2>&1; then
    for chain in PSW_MANGLE PSW_NAT PSW_REDIRECT dstnat mangle_prerouting mangle_output nat_output; do
        echo "=== CHAIN: $chain ===" >> nftables-chains-passwall.txt
        nft list chain inet passwall $chain >> nftables-chains-passwall.txt 2>&1
        echo "" >> nftables-chains-passwall.txt
    done
fi

# ==================== SYSCTL ====================
echo "[9/40] Sysctl..."
sysctl -a > sysctl-all.txt 2>&1
cat > sysctl-key.txt << 'EOF'
=== KEY SYSCTL ===
EOF
sysctl net.ipv4.ip_forward >> sysctl-key.txt 2>&1
sysctl net.ipv4.conf.all.forwarding >> sysctl-key.txt 2>&1
sysctl net.ipv4.conf.all.rp_filter >> sysctl-key.txt 2>&1
sysctl net.ipv4.conf.default.rp_filter >> sysctl-key.txt 2>&1

# ==================== DNS ====================
echo "[10/40] DNS configuration..."
cat /etc/resolv.conf > resolv.conf.txt 2>&1
cat /tmp/resolv.conf.auto > resolv.conf.auto.txt 2>&1
cat /tmp/resolv.conf.d/resolv.conf.auto > resolv.conf.d.txt 2>&1

# ==================== DNSMASQ ====================
echo "[11/40] dnsmasq..."
cat /etc/dnsmasq.conf > dnsmasq.conf.txt 2>&1
cat /tmp/dnsmasq.conf > dnsmasq.tmp.txt 2>&1
ps | grep dnsmasq | grep -v grep > dnsmasq-processes.txt 2>&1

# ==================== UCI FULL ====================
echo "[12/40] UCI configuration..."
uci show > uci-all.txt 2>&1
uci show network > uci-network.txt 2>&1
uci show firewall > uci-firewall.txt 2>&1
uci show dhcp > uci-dhcp.txt 2>&1
uci show openvpn > uci-openvpn.txt 2>&1
uci show passwall > uci-passwall.txt 2>&1
uci show system > uci-system.txt 2>&1

# ==================== PASSWALL DEEP ====================
echo "[13/40] Passwall processes..."
ps | grep -E 'xray|v2ray|sing-box|passwall|chinadns' | grep -v grep > passwall-processes.txt 2>&1
ps w | grep -E 'xray|v2ray|sing-box|passwall|chinadns' | grep -v grep > passwall-processes-wide.txt 2>&1

echo "[14/40] Passwall ports..."
netstat -tlnp 2>/dev/null | grep -E 'xray|v2ray|chinadns|passwall' > passwall-ports.txt 2>&1
netstat -ulnp 2>/dev/null | grep -E 'xray|v2ray|chinadns|passwall' >> passwall-ports.txt 2>&1

echo "[15/40] Passwall configs..."
ls -laR /tmp/etc/passwall/ > passwall-configs-list.txt 2>&1

echo "[16/40] Passwall logs..."
logread | grep -i passwall > passwall-logs.txt 2>&1
logread | grep -i passwall | tail -100 > passwall-logs-last100.txt 2>&1

# ==================== OPENVPN ====================
echo "[17/40] OpenVPN..."
ps | grep openvpn | grep -v grep > openvpn-processes.txt 2>&1
cat /tmp/openvpn-status.log > openvpn-status.txt 2>&1
if [ -f /tmp/openvpn.log ]; then
    tail -200 /tmp/openvpn.log > openvpn.log.txt 2>&1
fi

# ==================== PROCESSES ====================
echo "[18/40] All processes..."
ps > processes.txt 2>&1
ps w > processes-wide.txt 2>&1
ps aux 2>/dev/null > processes-aux.txt 2>&1

# ==================== NETSTAT ====================
echo "[19/40] Network connections..."
netstat -tuln > netstat-listening.txt 2>&1
netstat -tun > netstat-connections.txt 2>&1
netstat -rn > netstat-routes.txt 2>&1
netstat -s > netstat-stats.txt 2>&1

# ==================== SS (socket stats) ====================
echo "[20/40] Socket statistics..."
ss -tuln > ss-listening.txt 2>&1
ss -tun > ss-connections.txt 2>&1

# ==================== ARP ====================
echo "[21/40] ARP table..."
ip neigh show > arp-table.txt 2>&1
arp -n > arp-legacy.txt 2>&1

# ==================== FIREWALL ====================
echo "[22/40] Firewall..."
/etc/init.d/firewall status > firewall-status.txt 2>&1
if command -v fw4 >/dev/null 2>&1; then
    fw4 print > fw4-print.txt 2>&1
fi

# ==================== SERVICES ====================
echo "[23/40] Services..."
ls -la /etc/init.d/ > services-list.txt 2>&1
ls -la /etc/rc.d/ > services-rclinks.txt 2>&1

for service in passwall openvpn dnsmasq firewall network; do
    /etc/init.d/$service status > service-$service-status.txt 2>&1
done

# ==================== MOUNTS ====================
echo "[24/40] Filesystems..."
mount > mount.txt 2>&1
df -h > df.txt 2>&1
cat /proc/mounts > proc-mounts.txt 2>&1

# ==================== KERNEL ====================
echo "[25/40] Kernel modules..."
lsmod > lsmod.txt 2>&1
cat /proc/modules > proc-modules.txt 2>&1

# ==================== LOGS ====================
echo "[26/40] System logs..."
logread > logread-full.txt 2>&1
logread | tail -1000 > logread-last1000.txt 2>&1
dmesg > dmesg.txt 2>&1

# ==================== CUSTOM SCRIPTS ====================
echo "[27/40] Custom scripts..."
ls -la /root/*.sh > custom-scripts.txt 2>&1
ls -la /usr/sbin/rw-fix* >> custom-scripts.txt 2>&1

if [ -f /etc/rc.local ]; then
    cat /etc/rc.local > rc.local.txt 2>&1
fi

# ==================== ENVIRONMENT ====================
echo "[28/40] Environment..."
env > environment.txt 2>&1
cat /proc/cmdline > kernel-cmdline.txt 2>&1

# ==================== PASSWALL STATUS CHECK ====================
echo "[29/40] Passwall detailed status..."
cat > passwall-status-check.txt << 'EOF'
=== PASSWALL STATUS CHECK ===

EOF

echo "Main switch: $(uci get passwall.@global[0].enabled 2>/dev/null)" >> passwall-status-check.txt
echo "TCP node: $(uci get passwall.@global[0].tcp_node 2>/dev/null)" >> passwall-status-check.txt
echo "UDP node: $(uci get passwall.@global[0].udp_node 2>/dev/null)" >> passwall-status-check.txt
echo "TCP proxy mode: $(uci get passwall.@global[0].tcp_proxy_mode 2>/dev/null)" >> passwall-status-check.txt
echo "UDP proxy mode: $(uci get passwall.@global[0].udp_proxy_mode 2>/dev/null)" >> passwall-status-check.txt
echo "DNS shunt: $(uci get passwall.@global[0].dns_shunt 2>/dev/null)" >> passwall-status-check.txt
echo "" >> passwall-status-check.txt
echo "Xray running: $(pgrep xray >/dev/null 2>&1 && echo 'YES' || echo 'NO')" >> passwall-status-check.txt
echo "ChinaDNS running: $(pgrep chinadns >/dev/null 2>&1 && echo 'YES' || echo 'NO')" >> passwall-status-check.txt
echo "Passwall nftables: $(nft list table inet passwall >/dev/null 2>&1 && echo 'YES' || echo 'NO')" >> passwall-status-check.txt

# ==================== CONNECTION TEST FROM ROUTER ====================
echo "[30/40] Connection test from router..."
cat > connection-test-router.txt << 'EOF'
=== CONNECTION TEST FROM ROUTER ===

EOF

echo "DNS test (google.com):" >> connection-test-router.txt
nslookup google.com 2>&1 | head -10 >> connection-test-router.txt
echo "" >> connection-test-router.txt

echo "Ping test (8.8.8.8):" >> connection-test-router.txt
ping -c 3 8.8.8.8 >> connection-test-router.txt 2>&1
echo "" >> connection-test-router.txt

echo "Exit IP test:" >> connection-test-router.txt
curl -s --max-time 10 https://api.ipify.org >> connection-test-router.txt 2>&1
echo "" >> connection-test-router.txt
curl -s --max-time 10 https://ifconfig.me >> connection-test-router.txt 2>&1
echo "" >> connection-test-router.txt

# ==================== TRAFFIC STATS ====================
echo "[31/40] Traffic statistics..."
cat > traffic-stats.txt << 'EOF'
=== TRAFFIC STATS ===

EOF

echo "=== TUN0 (RW) ===" >> traffic-stats.txt
ip -s link show tun0 >> traffic-stats.txt 2>&1
echo "" >> traffic-stats.txt

echo "=== BR-LAN (WAN) ===" >> traffic-stats.txt
ip -s link show br-lan >> traffic-stats.txt 2>&1
echo "" >> traffic-stats.txt

# ==================== NFTABLES COUNTERS ====================
echo "[32/40] nftables counters..."
if nft list table inet passwall >/dev/null 2>&1; then
    nft list table inet passwall | grep -E "counter|packets|bytes" > nftables-counters-passwall.txt 2>&1
fi

if nft list table inet fw4 >/dev/null 2>&1; then
    nft list table inet fw4 | grep -E "counter|packets|bytes" > nftables-counters-fw4.txt 2>&1
fi

# ==================== CRITICAL ANALYSIS ====================
echo "[33/40] Critical analysis..."
cat > critical-analysis.txt << 'EOF'
=== CRITICAL ANALYSIS ===

EOF

echo "1. IP Forwarding:" >> critical-analysis.txt
cat /proc/sys/net/ipv4/ip_forward >> critical-analysis.txt
echo "" >> critical-analysis.txt

echo "2. TUN interfaces:" >> critical-analysis.txt
ip link show | grep tun >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

echo "3. Default route:" >> critical-analysis.txt
ip route show default >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

echo "4. IP rules priority order:" >> critical-analysis.txt
ip rule show | head -20 >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

echo "5. Passwall_lan set (check 10.x):" >> critical-analysis.txt
if nft list set inet passwall passwall_lan 2>/dev/null | grep -q "10\."; then
    echo "  ⚠ Contains 10.x ranges:" >> critical-analysis.txt
    nft list set inet passwall passwall_lan 2>/dev/null | grep "10\." >> critical-analysis.txt
else
    echo "  ✓ No 10.x ranges found" >> critical-analysis.txt
fi
echo "" >> critical-analysis.txt

echo "6. fwmark routing:" >> critical-analysis.txt
ip rule show | grep "fwmark 0x1" >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

echo "7. mgmt routing:" >> critical-analysis.txt
ip rule show | grep "mgmt" >> critical-analysis.txt 2>&1
ip route show table mgmt >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

echo "8. vpnout routing:" >> critical-analysis.txt
ip route show table vpnout >> critical-analysis.txt 2>&1
echo "" >> critical-analysis.txt

# ==================== RW SERVER CHECK ====================
echo "[34/40] RW server check..."
cat > rw-server-check.txt << 'EOF'
=== RW SERVER CHECK ===

EOF

echo "RW process:" >> rw-server-check.txt
ps | grep "openvpn.*rw" | grep -v grep >> rw-server-check.txt 2>&1
echo "" >> rw-server-check.txt

echo "RW config:" >> rw-server-check.txt
uci show openvpn.rw >> rw-server-check.txt 2>&1
echo "" >> rw-server-check.txt

echo "RW push options:" >> rw-server-check.txt
uci show openvpn.rw.push >> rw-server-check.txt 2>&1
echo "" >> rw-server-check.txt

# ==================== CLIENT ROUTES ====================
echo "[35/40] Client /32 routes..."
ip route | grep "/32" > client-routes.txt 2>&1

# ==================== TCPDUMP SAMPLE ====================
echo "[36/40] Quick tcpdump sample (5 sec)..."
timeout 5 tcpdump -i tun0 -n -c 20 > tcpdump-tun0-sample.txt 2>&1 &
timeout 5 tcpdump -i br-lan -n -c 20 > tcpdump-brlan-sample.txt 2>&1 &
wait

# ==================== PROC INFO ====================
echo "[37/40] /proc info..."
cat /proc/sys/net/ipv4/conf/all/forwarding > proc-forwarding-all.txt 2>&1
cat /proc/sys/net/ipv4/conf/tun0/forwarding > proc-forwarding-tun0.txt 2>&1
cat /proc/sys/net/ipv4/conf/br-lan/forwarding > proc-forwarding-brlan.txt 2>&1

# ==================== CONNTRACK ====================
echo "[38/40] Connection tracking..."
cat /proc/net/nf_conntrack | head -100 > nf_conntrack-sample.txt 2>&1
cat /proc/sys/net/netfilter/nf_conntrack_count > nf_conntrack-count.txt 2>&1
cat /proc/sys/net/netfilter/nf_conntrack_max > nf_conntrack-max.txt 2>&1

# ==================== FILES LIST ====================
echo "[39/40] Important files list..."
ls -la /etc/openvpn/ > files-openvpn.txt 2>&1
ls -la /tmp/etc/passwall/ > files-passwall.txt 2>&1 2>/dev/null
ls -la /root/ > files-root.txt 2>&1

# ==================== SUMMARY ====================
echo "[40/40] Creating summary..."

TUN_COUNT=$(ip link show | grep -c tun)
OVPN_COUNT=$(ps | grep openvpn | grep -v grep | wc -l)
PASSWALL_PROC=$(pgrep xray >/dev/null 2>&1 && echo "YES" || echo "NO")
PASSWALL_NFT=$(nft list table inet passwall >/dev/null 2>&1 && echo "YES" || echo "NO")
FILE_COUNT=$(ls -1 | wc -l)
DIR_SIZE=$(du -sh . | awk '{print $1}')

cat > snapshot-summary.txt << EOF
=== MEGA SNAPSHOT SUMMARY ===
Name: $NAME
Time: $TIME
Files: $FILE_COUNT
Size: $DIR_SIZE

=== SYSTEM STATUS ===
TUN interfaces: $TUN_COUNT
OpenVPN processes: $OVPN_COUNT
Passwall process: $PASSWALL_PROC
Passwall nftables: $PASSWALL_NFT

=== IP ROUTING ===
EOF

ip rule show | head -10 >> snapshot-summary.txt

cat >> snapshot-summary.txt << 'EOF'

=== CRITICAL FILES TO CHECK ===
1. critical-analysis.txt (MOST IMPORTANT!)
2. passwall-status-check.txt
3. nftables-sets-passwall.txt (check passwall_lan!)
4. ip-rule.txt
5. connection-test-router.txt
6. passwall-logs-last100.txt
EOF

echo ""
echo "========================================"
echo "MEGA SNAPSHOT COMPLETE!"
echo "========================================"
echo ""
echo "Location: $DIR"
echo "Files: $FILE_COUNT"
echo "Size: $DIR_SIZE"
echo ""
echo "Most important files:"
echo "  1. critical-analysis.txt"
echo "  2. passwall-status-check.txt"
echo "  3. nftables-sets-passwall.txt"
echo "  4. connection-test-router.txt"
echo ""
cat snapshot-summary.txt
echo ""
