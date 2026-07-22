#!/usr/bin/env bash
# Run on the COLLECTION box (root). Captures the CLIENT-SIDE view of one session,
# running the generator COMMAND inside the netns between two idle anchors:
#   plaintext : netns ovpncli, tun-ovpnc           -- generator's own traffic, pre-encryption
#   cipher    : root ns, veth-root 'udp port PORT'  -- encrypted, before it leaves to the VPS
#
# Requires the tunnel already up (local-client-setup.sh: netns ovpncli + tun-ovpnc + veth-root).
#
#   sudo ./ns-capture.sh <label> <generator command...>
#   sudo ./ns-capture.sh bilibili \
#       runuser -u master -- python3 collection/env/gen/gen-browser.py --kind browsing --duration 60
set -euo pipefail

LABEL="${1:?usage: ns-capture.sh <label> <generator cmd...>}"; shift
CMD=( "$@" ); [[ ${#CMD[@]} -gt 0 ]] || { echo "ERROR: no generator command." >&2; exit 1; }

NS="${NETNS:-ovpncli}"
PIF="${PLAIN_IF:-tun-ovpnc}"
CIF="${CIPHER_IF:-veth-root}"
PORT="${PORT:-1194}"
ANCHOR="${ANCHOR:-3}"
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }
ip netns exec "$NS" ip link show "$PIF" >/dev/null 2>&1 || { echo "ERROR: $PIF not up in netns $NS (tunnel running?)." >&2; exit 1; }
ip link show "$CIF" >/dev/null 2>&1 || { echo "ERROR: $CIF not up (tunnel running?)." >&2; exit 1; }

OUT="${OUTROOT:-/home/master/dataset}/$LABEL/$(date +%Y%m%dT%H%M%S)_${LABEL}"
mkdir -p "$OUT"
echo "[*] ns-side capture -> $OUT   (netns=$NS, plaintext=$PIF, cipher=$CIF udp/$PORT)"

ip netns exec "$NS" tcpdump -ni "$PIF" -w "$OUT/plaintext.pcap" -U 2>"$OUT/.p.err" & P=$!
tcpdump -ni "$CIF" "udp port $PORT"    -w "$OUT/cipher.pcap"    -U 2>"$OUT/.c.err" & C=$!
sleep 0.5

echo "[*] leading idle anchor (${ANCHOR}s) ..."; sleep "$ANCHOR"
echo "[*] running: ${CMD[*]}"
T0=$(date +%s.%N); set +e; ip netns exec "$NS" "${CMD[@]}"; RC=$?; set -e; T1=$(date +%s.%N)
echo "[*] generator rc=$RC; trailing idle anchor (${ANCHOR}s) ..."; sleep "$ANCHOR"

kill -INT "$P" "$C" 2>/dev/null || true
sleep 1
cat > "$OUT/meta.json" <<EOF
{
  "label": "$LABEL",
  "protocol": "openvpn-udp",
  "topology": "vps-ns-client",
  "cmd": "${CMD[*]}",
  "generator_rc": $RC,
  "t_active_start": $T0,
  "t_active_end": $T1,
  "anchor_gap_s": $ANCHOR,
  "plain_iface": "$PIF",
  "cipher_iface": "$CIF",
  "cipher_filter": "udp port $PORT"
}
EOF
_n(){ grep -oE '[0-9]+ packets captured' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }
echo "[*] done: plaintext=$(_n "$OUT/.p.err") pkts  cipher=$(_n "$OUT/.c.err") pkts  ($(du -sh "$OUT" | cut -f1))"
echo "[*] -> $OUT"
rm -f "$OUT/.p.err" "$OUT/.c.err"
