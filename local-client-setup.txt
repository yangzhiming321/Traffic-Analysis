#!/usr/bin/env bash
# OpenVPN client(s) on the COLLECTION box, each tunnelling to the VPS server(s)
# (vps-server-setup.sh). WORKERS clients; client k -> VPS port (base+k-1), each in
# its own netns + veth pair (same naming as the local lab's ovpn-setup.sh), so
# parallel sessions don't mix. WORKERS=1 (default) is the original single client.
#
#   client 1 : netns ovpncli   veth veth-root/veth-ns  subnet 10.9.0.0/24  -> VPS:base
#   client k : netns ovpncli$k veth vroot$k/vns$k      subnet 10.9.$((k-1)).0/24 -> VPS:base+k-1
#
# Plaintext + generator stay local (per netns, tun-ovpnc); the cipher is captured
# ON THE VPS by port (collect-parallel-vps.sh / ovpn-session.sh REMOTE mode).
#
#   sudo REMOTE=<vps ip> ./local-client-setup.sh [phys_iface] [base_port]
#   sudo REMOTE=<vps ip> WORKERS=12 ./local-client-setup.sh eth0 1194
set -euo pipefail

REMOTE="${REMOTE:?set REMOTE=<vps public ip>}"
PHYS="${1:-$(ip -4 route show default | awk '{print $5; exit}')}"
PORT="${2:-1194}"
WORKERS="${WORKERS:-1}"
[[ -n "$PHYS" ]] || { echo "ERROR: no default-route iface; pass one explicitly." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${BUNDLE:-$HERE/bundle}"
for f in ca.crt client.crt client.key tc.key; do
  [[ -f "$BUNDLE/$f" ]] || { echo "ERROR: $BUNDLE/$f missing -- scp it from the VPS first." >&2; exit 1; }
done

DIR=/etc/openvpn/vpslab-client
mkdir -p "$DIR"
cp -f "$BUNDLE"/{ca.crt,client.crt,client.key,tc.key} "$DIR/"
chmod 600 "$DIR/client.key" "$DIR/tc.key"

ns_name() { [[ "$1" == 1 ]] && echo "ovpncli"   || echo "ovpncli$1"; }
vr_name() { [[ "$1" == 1 ]] && echo "veth-root" || echo "vroot$1"; }
vn_name() { [[ "$1" == 1 ]] && echo "veth-ns"   || echo "vns$1"; }

# NAT so each netns's cipher reaches the VPS over the internet. WSL has no
# iptables -> nft fallback; both cover the whole 10.9.0.0/16 client pool at once.
sysctl -wq net.ipv4.ip_forward=1
USE_NFT=0; command -v iptables >/dev/null 2>&1 || USE_NFT=1
add_rule() { local t="$1"; shift; iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -A "$@"; }
if [[ "$USE_NFT" == 1 ]]; then
  nft list table ip ovpnvps >/dev/null 2>&1 || nft add table ip ovpnvps
  nft 'list chain ip ovpnvps postrouting' >/dev/null 2>&1 || \
    nft 'add chain ip ovpnvps postrouting { type nat hook postrouting priority srcnat ; }'
  nft flush chain ip ovpnvps postrouting
  nft add rule ip ovpnvps postrouting ip saddr 10.9.0.0/16 oif "$PHYS" masquerade
else
  add_rule nat POSTROUTING -s 10.9.0.0/16 -o "$PHYS" -j MASQUERADE
fi

for k in $(seq 1 "$WORKERS"); do
  NS="$(ns_name "$k")"; VR="$(vr_name "$k")"; VN="$(vn_name "$k")"
  N3="10.9.$(( k - 1 ))"; VR_IP="$N3.1"; VN_IP="$N3.2"
  p=$(( PORT + k - 1 ))

  ip netns add "$NS" 2>/dev/null || true
  ip link show "$VR" >/dev/null 2>&1 || ip link add "$VR" type veth peer name "$VN"
  ip link set "$VN" netns "$NS" 2>/dev/null || true
  ip addr replace "$VR_IP/24" dev "$VR"; ip link set "$VR" up
  ip netns exec "$NS" ip addr replace "$VN_IP/24" dev "$VN"
  ip netns exec "$NS" ip link set "$VN" up
  ip netns exec "$NS" ip link set lo up
  ip netns exec "$NS" ip route replace default via "$VR_IP"
  if [[ "$USE_NFT" != 1 ]]; then   # nft: default FORWARD policy is accept on WSL
    add_rule filter FORWARD -i "$VR" -o "$PHYS" -j ACCEPT
    add_rule filter FORWARD -i "$PHYS" -o "$VR" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  mkdir -p "/etc/netns/$NS"
  echo "nameserver 8.8.8.8" > "/etc/netns/$NS/resolv.conf"

  cat > "$DIR/client$k.conf" <<EOF
dev tun-ovpnc
proto udp
remote $REMOTE $p
nobind
client
ca $DIR/ca.crt
cert $DIR/client.crt
key $DIR/client.key
remote-cert-tls server
cipher AES-256-GCM
max-packet-size 1000
tls-crypt $DIR/tc.key
persist-tun
disable-dco
verb 3
EOF
  pkill -F "$DIR/client$k.pid" 2>/dev/null || true
  ip netns exec "$NS" openvpn --config "$DIR/client$k.conf" \
      --writepid "$DIR/client$k.pid" --daemon "ovpn-vpscli$k" --log "$DIR/client$k.log"
done

echo "[*] connecting $WORKERS client(s) to $REMOTE (ports $PORT..$(( PORT + WORKERS - 1 ))) ..."
for k in $(seq 1 "$WORKERS"); do
  NS="$(ns_name "$k")"; SRV_TUN="10.8.$(( k - 1 )).1"; up=0
  for _ in $(seq 1 40); do
    ip netns exec "$NS" ping -c1 -W1 "$SRV_TUN" >/dev/null 2>&1 && { up=1; break; }
    sleep 0.5
  done
  [[ "$up" == 1 ]] || { echo "ERROR: client $k ($NS) did not come up. Log:" >&2; tail -n 20 "$DIR/client$k.log" >&2; exit 1; }
done

echo "OpenVPN clients UP (server=$REMOTE):"
for k in $(seq 1 "$WORKERS"); do printf '  %-10s -> VPS:%s\n' "$(ns_name "$k")" "$(( PORT + k - 1 ))"; done
echo
echo "Collect in parallel (cipher captured on the VPS, per-worker port):"
echo "  sudo env REMOTE=$REMOTE PASS=... WORKERS=$WORKERS collection/env/openvpn-vps/collect-parallel-vps.sh"
echo "Teardown: sudo ./local-client-teardown.sh $PHYS $PORT"
