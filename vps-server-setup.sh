#!/usr/bin/env bash
# OpenVPN server(s) on a REMOTE VPS exit endpoint. SERVERS instances, one per port
# (base, base+1, ...), each its own tun + tunnel subnet, so parallel clients each
# get a DISTINCT port -> the VPS can demux their ciphertext by port (capture on the
# public iface 'udp port <p>'). SERVERS=1 (default) = the original single-server lab.
# Shared EC PKI + tls-crypt. Client materials land in $BUNDLE for the box to scp down.
#
#   sudo ./vps-server-setup.sh [public_iface] [base_port]
#   sudo SERVERS=12 ./vps-server-setup.sh enp1s0 1194
set -euo pipefail

PHYS="${1:-$(ip -4 route show default | awk '{print $5; exit}')}"
PORT="${2:-1194}"
SERVERS="${SERVERS:-1}"
[[ -n "$PHYS" ]] || { echo "ERROR: no default-route iface; pass one explicitly." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

DIR=/etc/openvpn/vpslab
PKI="$DIR/pki"
BUNDLE="$DIR/client-bundle"
TC="$DIR/tc.key"
EASYRSA="$(command -v easyrsa || echo /usr/share/easy-rsa/easyrsa)"
mkdir -p "$DIR" "$BUNDLE"

# --- PKI + tls-crypt key (once) ---------------------------------------------
if [[ ! -f "$PKI/pki/issued/server.crt" ]]; then
  echo "[*] building EC PKI ..."
  rm -rf "$PKI"; mkdir -p "$PKI"
  export EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=secp384r1 EASYRSA_PKI="$PKI/pki"
  "$EASYRSA" init-pki >/dev/null
  EASYRSA_REQ_CN="ovpn-vps-ca" "$EASYRSA" build-ca nopass >/dev/null
  "$EASYRSA" build-server-full server nopass >/dev/null
  "$EASYRSA" build-client-full client nopass >/dev/null
fi
CA="$PKI/pki/ca.crt"
SRV_CRT="$PKI/pki/issued/server.crt"; SRV_KEY="$PKI/pki/private/server.key"
[[ -f "$TC" ]] || openvpn --genkey secret "$TC"

cp -f "$CA" "$BUNDLE/ca.crt"
cp -f "$PKI/pki/issued/client.crt" "$BUNDLE/client.crt"
cp -f "$PKI/pki/private/client.key" "$BUNDLE/client.key"
cp -f "$TC" "$BUNDLE/tc.key"
chmod 644 "$BUNDLE/"*.crt; chmod 600 "$BUNDLE/client.key" "$BUNDLE/tc.key"

sysctl -wq net.ipv4.ip_forward=1
add_rule() { local t="$1"; shift; iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -A "$@"; }

# --- one server instance per port -------------------------------------------
for k in $(seq 1 "$SERVERS"); do
  p=$(( PORT + k - 1 ))
  cat > "$DIR/server$k.conf" <<EOF
dev tun-ovpns$k
proto udp
port $p
topology subnet
server 10.8.$(( k - 1 )).0 255.255.255.0
duplicate-cn
ca $CA
cert $SRV_CRT
key $SRV_KEY
dh none
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
cipher AES-256-GCM
max-packet-size 1000
tls-crypt $TC
keepalive 10 120
persist-tun
disable-dco
verb 3
EOF
  add_rule nat POSTROUTING -s 10.8.$(( k - 1 )).0/24 -o "$PHYS" -j MASQUERADE
  add_rule filter FORWARD -i "tun-ovpns$k" -o "$PHYS" -j ACCEPT
  add_rule filter FORWARD -i "$PHYS" -o "tun-ovpns$k" -m state --state RELATED,ESTABLISHED -j ACCEPT
  add_rule filter INPUT -p udp --dport "$p" -j ACCEPT
  pkill -F "$DIR/server$k.pid" 2>/dev/null || true
  sleep 0.2
  openvpn --config "$DIR/server$k.conf" --writepid "$DIR/server$k.pid" \
          --daemon "ovpn-vpssrv$k" --log "$DIR/server$k.log"
done
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT:$(( PORT + SERVERS - 1 ))"/udp >/dev/null 2>&1 || true
fi
sleep 1.5

for k in $(seq 1 "$SERVERS"); do
  ip -o addr show "tun-ovpns$k" 2>/dev/null | grep -q "10.8.$(( k - 1 )).1" || {
    echo "ERROR: server$k tun did not come up. Log:" >&2; tail -n 15 "$DIR/server$k.log" >&2; exit 1; }
done

PUBIP="$(ip -4 -o addr show dev "$PHYS" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
echo
echo "OpenVPN VPS up: $SERVERS server(s), ports $PORT..$(( PORT + SERVERS - 1 )) on $PHYS (${PUBIP:-?})."
echo "Bundle: $BUNDLE/{ca.crt,client.crt,client.key,tc.key}"
echo "scp 'root@${PUBIP:-VPS_IP}:$BUNDLE/*' <local>/collection/env/openvpn-vps/bundle/"
echo "Teardown: ./vps-server-teardown.sh $PHYS $PORT   (per-instance pids: $DIR/server*.pid)"
