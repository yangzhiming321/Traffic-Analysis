#!/usr/bin/env bash
# PARALLEL website-fingerprinting over the VPS-exit lab. WORKERS clients
# (local-client-setup.sh WORKERS>=this), client w on VPS port (base+w-1). Per
# session the cipher is captured ON THE VPS (udp port = the worker's port) and
# scp'd back; plaintext + generator stay local. Output layout matches
# collect-parallel.sh: $OUTROOT/<site>/<sid>/{plaintext,cipher}.pcap + meta.json.
#
#   sudo REMOTE=<vps ip> PASS=<vps root pw> WORKERS=12 \
#     collection/env/openvpn-vps/collect-parallel-vps.sh
set -euo pipefail

REMOTE="${REMOTE:?set REMOTE=<vps ip>}"
PASS="${PASS:?set PASS=<vps root password>}"

# DEFAULT_SITES="bilibili baidu 163 sina sohu ifeng qq jd taobao thepaper 36kr csdn"
DEFAULT_SITES="youtube google yahoo nbcnews bbc cnn reddit amazon ebay techcrunch theverge stackoverflow"

SITES="${SITES:-$DEFAULT_SITES}"
N="${N:-12}"
MAXSEC="${MAXSEC:-60}"
WORKERS="${WORKERS:-12}"
SLEEP="${SLEEP:-1}"
PORT="${PORT:-1194}"
OUTROOT="${OUTROOT:-/home/master/dataset/VPS/openvpn}"
RUNAS="${RUNAS:-master}"
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SESSION="$HERE/../openvpn/ovpn-session.sh"
GEN="$HERE/../gen/gen-browser.py"
PY="${PY:-/home/${SUDO_USER:-$USER}/miniconda3/envs/3.10/bin/python3}"
[[ -x "$PY" ]] || { echo "ERROR: python '$PY' missing (set PY=)." >&2; exit 1; }

ns_name() { [[ "$1" == 1 ]] && echo "ovpncli" || echo "ovpncli$1"; }

for w in $(seq 1 "$WORKERS"); do
  ip netns list | grep -qw "$(ns_name "$w")" || {
    echo "ERROR: netns $(ns_name "$w") missing. Run: sudo REMOTE=$REMOTE WORKERS=$WORKERS local-client-setup.sh" >&2
    exit 1; }
done

# detect the VPS cipher iface once (saves an ssh per session) + early reachability check
RCIF="${RCIF:-$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -o ConnectionAttempts=4 root@"$REMOTE" "ip -4 route show default | awk '{print \$5; exit}'" 2>/dev/null | tr -d '\r')}"
[[ -n "$RCIF" ]] || { echo "ERROR: cannot reach root@$REMOTE (check REMOTE/PASS)." >&2; exit 1; }

read -r -a SITE_ARR <<< "$SITES"
TOTAL=$(( ${#SITE_ARR[@]} * N ))
declare -A WT
idx=0
for _ in $(seq 1 "$N"); do
  mapfile -t SHUF < <(printf '%s\n' "${SITE_ARR[@]}" | shuf)
  for site in "${SHUF[@]}"; do
    w=$(( idx % WORKERS + 1 )); WT[$w]+="$site "; idx=$(( idx + 1 ))
  done
done

mkdir -p "$OUTROOT/.logs"
echo "[*] $TOTAL visits over $WORKERS clients; cipher on $REMOTE:$RCIF ports $PORT..$(( PORT + WORKERS - 1 ))"
echo "[*] per-worker logs: $OUTROOT/.logs/worker<k>.log"

run_worker() {
  local w="$1" ns p log site i=0
  ns="$(ns_name "$w")"; p=$(( PORT + w - 1 )); log="$OUTROOT/.logs/worker$w.log"
  local sites=( ${WT[$w]} )
  : > "$log"
  for site in "${sites[@]}"; do
    i=$(( i + 1 ))
    echo "=== worker$w [$i/${#sites[@]}] site=$site port=$p $(date +%T) ===" >> "$log"
    REMOTE="$REMOTE" PASS="$PASS" RCIF="$RCIF" NETNS="$ns" PORT="$p" \
    OUTROOT="$OUTROOT" KIND=browsing SIDSFX="w$w" \
      "$SESSION" "$site" \
        runuser -u "$RUNAS" -- "$PY" "$GEN" --site "$site" --max-seconds "$MAXSEC" \
        >> "$log" 2>&1 || echo "  [warn] $site failed (continuing)" >> "$log"
    [[ $i -lt ${#sites[@]} ]] && sleep "$SLEEP"
  done
  echo "=== worker$w DONE $(date +%T) ===" >> "$log"
}

pids=()
for w in $(seq 1 "$WORKERS"); do run_worker "$w" & pids+=("$!"); done
echo "[*] launched workers: ${pids[*]}  (monitor: tail -f $OUTROOT/.logs/worker*.log)"
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done

echo "[*] all workers finished (fail=$fail). Sessions per site:"
for s in "${SITE_ARR[@]}"; do
  printf '  %-10s %s\n' "$s" "$(find "$OUTROOT/$s" -name plaintext.pcap 2>/dev/null | wc -l)"
done
echo "[*] next: $PY $REPO/collection/process/build_dataset.py $OUTROOT --outdir $OUTROOT/processed"
