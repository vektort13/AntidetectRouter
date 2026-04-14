#!/bin/sh

detect_upstream() {
  # Prefer first enabled OpenVPN client section != rw
  for s in $(uci show openvpn 2>/dev/null | sed -n 's/^openvpn\.\([^.]*\)=openvpn.*/\1/p'); do
    [ "$s" = "rw" ] && continue
    [ "$(uci -q get openvpn.$s.client || echo 0)" = "1" ] || continue
    en="$(uci -q get openvpn.$s.enabled || echo 1)"
    [ "$en" = "0" ] && continue
    echo "$s"
    return 0
  done
  return 1
}

UP="$(detect_upstream || true)"

# If found: pass as BOTH args (config name + upstream log name)
if [ -n "$UP" ]; then
  exec /root/dual-vpn-switcher.sh "$UP" "$UP"
else
  # fallback to original defaults inside dual-vpn-switcher.sh
  exec /root/dual-vpn-switcher.sh
fi
