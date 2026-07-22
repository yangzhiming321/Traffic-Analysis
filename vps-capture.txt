#!/usr/bin/env bash
# Run ON THE VPS (root). Captures the SERVER-SIDE view of one session for DUR seconds:
#   cipher    : eth0  'udp port <PORT>'   -- encrypted tunnel as it ARRIVES from the internet
#   plaintext : tun-ovpns                 -- decrypted traffic, before NAT out to the internet
#
# The generator runs on the collection box, so this side just captures for a fixed
# window. Start this FIRST, then start ns-capture.sh locally inside the window.
#
#   sudo ./vps-capture.sh <label> [duration_s] [cipher_iface] [plain_iface] [port]
#   sudo OUTROOT=/root/dataset-vps ./vps-capture.sh bilibili 90
set -euo pipefail

LABEL="${1:?usage: vps-capture.sh <label> [duration_s]}"
DUR="${2:-60}"
CIF="${3:-eth0}"
PIF="${4:-tun-ovpns}"
PORT="${5:-1194}"
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

OUT="${OUTROOT:-/root/dataset-vps}/$LABEL/$(date +%Y%m%dT%H%M%S)_${LABEL}"
mkdir -p "$OUT"
echo "[*] VPS-side capture -> $OUT   (${DUR}s, cipher=$CIF udp/$PORT, plaintext=$PIF)"

tcpdump -ni "$CIF" "udp port $PORT" -w "$OUT/cipher_server.pcap"    -U 2>"$OUT/.c.err" & C=$!
tcpdump -ni "$PIF"                  -w "$OUT/plaintext_server.pcap" -U 2>"$OUT/.p.err" & P=$!
sleep 0.5
echo "[*] capturing for ${DUR}s ... (Ctrl-C stops early)"
sleep "$DUR"

kill -INT "$C" "$P" 2>/dev/null || true
sleep 1
_n(){ grep -oE '[0-9]+ packets captured' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -1; }
echo "[*] done: cipher=$(_n "$OUT/.c.err") pkts  plaintext=$(_n "$OUT/.p.err") pkts  ($(du -sh "$OUT" | cut -f1))"
echo "[*] -> $OUT"
rm -f "$OUT/.c.err" "$OUT/.p.err"
