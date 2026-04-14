# Changelog

## v0.6.0 - Security Hardening

Status: security-focused update

### CGI hardening

- audited and hardened CGI endpoints against common injection and parsing failures
- `cgi-common.sh`: `read_post_data()` now reads the full POST body with `dd bs=$CONTENT_LENGTH`
- `passwall-node-config.sh`: added UCI field sanitization plus address and port validation
- `openvpn-upload.sh`: replaced heredoc-based auth-file writes with `printf '%s\n%s\n'`
- `openvpn-upload.sh`: added `trap ... EXIT` cleanup for temporary files
- `exec.sh`: added package-name whitelist, LuCI port bounds checks, and safer password extraction
- `admin-control.sh`: received the same LuCI-port and password-extraction hardening as `exec.sh`
- `openvpn-control.sh`: now JSON-escapes user-facing output and validates config names in `delete` and `get_logs`
- `connection-history.sh`: now strips pipe delimiters and newlines from stored history fields
- `openvpn-save-content.sh`: config-name validation now allows hyphens, matching the other OpenVPN handlers

### Firewall safety net

- `dual-vpn-switcher.sh` in all three copies now re-enables `fw4` automatically if Passwall fails to start
- this prevents the system from being left without firewall protection after a Passwall startup failure

### DNS resilience

- `passwall-settings.sh`: `sync_dns_to_dnsmasq()` now adds `8.8.8.8` as a fallback resolver in addition to the Passwall DNS server

### Code quality fixes

- `vpn-dns-monitor.sh`: added `VERSION="2.1"`
- `vpn-dns-monitor.sh`: removed dead `count` logic lost in a pipeline subshell
- `router13.sh`: localized `cidr2mask()` variables `bits`, `m`, and `i`

### Verification

- modified shell scripts passed syntax checks
- external package-feed and IP-detection URLs were re-verified
- changes are backward-compatible and do not change the stored config format

## v0.5.1 - Patch Update

- runtime patch update for the older RWPATCH-based flow
- kill-switch rework for better isolation and routing safety
- DNS handling consolidated around runtime monitors
- SSH and LuCI lockout prevention improved in the Web UI integration path

## v0.3.0 - Initial Runtime Integration

- initial RWPATCH runtime integration
- added helper scripts for dual VPN switching, upstream monitoring, DNS following, snapshots, and `rw-fix`

Historical versions mostly describe the older runtime and update stack under `RouterUpdate/` and the legacy installer variants.