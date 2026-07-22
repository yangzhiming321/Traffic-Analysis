#!/usr/bin/env bash
# Reverse local-client-setup.sh on the collection box. Run as root.
#   sudo ./local-client-teardown.sh [phys_iface] [port]
set -uo pipefail
PHYS="${1:-$(ip -4 route show default | awk '{print $5; exit}')}"
PORT="${2:-1194}"
NS=ovpncli
DIR=/etc/openvpn/vpslab-client

pkill -F "$DIR/client.pid" 2>/dev/null || true
ip netns del "$NS" 2>/dev/null || true          # also drops veth-ns + tun-ovpnc
ip link del veth-root 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o "$PHYS" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i veth-root -o "$PHYS" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$PHYS" -o veth-root -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi
nft delete table ip ovpnvps 2>/dev/null || true
rm -rf "/etc/netns/$NS"

echo "[*] local client torn down."
