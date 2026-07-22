# OpenVPN over a real VPS (remote exit endpoint)

Same OpenVPN-UDP / AES-256-GCM lab as `../openvpn/`, but the **server lives on a
remote VPS** so ciphertext crosses the public internet (realistic jitter, real
exit IP, non-degenerate graph). The **client + both captures stay on the
collection box**, so the same-clock alignment invariant is preserved
(`plaintext.pcap` on `tun-ovpnc`, `cipher.pcap` on `veth-root`).

```
[gen in netns ovpncli] -> tun-ovpnc (plaintext) -> OpenVPN encrypt
   -> veth-ns -> veth-root (cipher) -> NAT -> phys -> INTERNET -> VPS server
       ^ plaintext.pcap                ^ cipher.pcap (both LOCAL, one clock)
```

The VPS server never captures; alignment uses only the two local pcaps. (The
contrastive model doesn't use the alignment matrix anyway — this remote-exit
setup would be valid even if it did, because the cipher is captured locally on
`veth-root` *before* it hits the internet.)

## Run

1. **VPS (root):** deploy the server.
   ```bash
   sudo ./vps-server-setup.sh enp1s0 1194
   ```
2. **Collection box:** scp the client materials down (once).
   ```bash
   scp 'root@<VPS_IP>:/etc/openvpn/vpslab/client-bundle/*' \
       collection/env/openvpn-vps/bundle/
   ```
   `bundle/` is gitignored — it holds the client **private key**, never commit it.
3. **Collection box (root):** bring up the client.
   ```bash
   sudo REMOTE=<VPS_IP> ./local-client-setup.sh eth0 1194
   ```
   Confirms the tunnel and prints the exit IP (should equal the VPS public IP).
4. **Collect** (the existing session orchestrator, unchanged):
   ```bash
   sudo NETNS=ovpncli CIPHER_IF=veth-root PORT=1194 OUTROOT=/home/master/dataset \
     ../openvpn/ovpn-session.sh browsing \
     runuser -u master -- python3 ../gen/gen-browser.py --kind browsing --duration 120
   ```
5. **Build dataset** with the usual `collection/process/build_dataset.py` — no
   changes; it sees the same per-session `{plaintext,cipher}.pcap + meta.json`.

## Teardown
```bash
sudo ./local-client-teardown.sh eth0 1194     # collection box
sudo ./vps-server-teardown.sh enp1s0 1194     # VPS
```

## If the tunnel won't come up
Stuck at the TLS handshake almost always means the **VPS cloud firewall /
security group is blocking inbound udp/1194** — open it in the provider panel
(Vultr: Settings → Firewall). The VPS host firewall (iptables/ufw) is already
opened by `vps-server-setup.sh`.
