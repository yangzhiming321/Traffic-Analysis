#!/usr/bin/env bash
# Reverse vps-server-setup.sh on the VPS. Run as root.
#   sudo ./vps-server-teardown.sh [public_iface] [port]
set -uo pipefail
PHYS="${1:-$(ip -4 route show default | awk '{print $5; exit}')}"
PORT="${2:-1194}"
DIR=/etc/openvpn/vpslab

pkill -F "$DIR/server.pid" 2>/dev/null || true
ip link del tun-ovpns 2>/dev/null || true

iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "$PHYS" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i tun-ovpns -o "$PHYS" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$PHYS" -o tun-ovpns -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true

echo "[*] VPS server torn down (PKI kept under $DIR/pki; rm -rf $DIR to wipe certs)."
