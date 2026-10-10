# My VPN — VLESS + REALITY edition

Ubuntu 24.04 deployment using **sing-box VLESS + REALITY**, with an Nginx HTTP subscription endpoint. The subscription file contains a Base64-encoded `vless://` URI and is importable in clients that support VLESS + REALITY, including current Shadowrocket versions.

## What changed from the original Shadowsocks edition

- Server config and client config now share one `VLESS_UUID`, `REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, SNI and port, all stored in root-only `/opt/my-vpn/server.env`.
- The default proxy port is TCP 443. The old Shadowsocks port is intentionally not carried forward during protocol migration. Nginx subscription remains on TCP 80 by default.
- Old pre-refactor UFW rules were created without ownership comments. They are deliberately left untouched because the script cannot reliably distinguish those old rules from unrelated manual rules. Review the backup and remove known stale old ports manually only after confirming no other service needs them.
- `backup.sh` snapshots the old project/config/Nginx/UFW state before any install changes.
- `apply-config.sh` stages and validates `config.json`, applies it atomically and restores the previous config if sing-box cannot start.
- `nginx-setup.sh` uses a project-specific site file, validates `nginx -t`, rolls back on failure, and does **not** remove the default Nginx site.
- `firewall.sh` labels only rules it adds with `myvpn-managed`, leaves broad existing allows untouched, and removes only rules carrying that marker.
- `uninstall.sh` retains package installations and `/etc/sing-box`; it removes a sing-box config only when the expected project marker exists.
- Subscription content is served from `/var/www/my-vpn/subscribe.txt` with the required directory/file permissions. Runtime keys and client files remain root-only.

## Important limits

1. REALITY changes the transport protocol and traffic characteristics; it does **not** guarantee access from every network or prevent all future interference. A server reinstall cannot fix SYN-ACK loss occurring in an upstream or client-side network.
2. Alibaba Cloud security groups are separate from UFW. You must allow TCP 443 and TCP 80 (plus your actual SSH port) in the security group.
3. The subscription site is HTTP by default because this project does not automatically provision or renew TLS certificates. The random token makes the path hard to guess but does not encrypt the subscription response. If you need HTTPS, configure a domain and a working certificate separately before distributing the subscription URL.
4. If UFW is currently inactive, the installer deliberately does not enable it or alter its inactive ruleset. This avoids unexpectedly changing the default policy for unrelated host services. Manage the cloud security group separately, then decide whether to enable UFW after reviewing all existing services.
5. The REALITY handshake target defaults to `www.microsoft.com:443`. Change it only to a stable TLS host reachable from the VPS and consistent with the SNI; avoid using a target behind a shared CDN as a careless fallback target.
6. Client import is supported through a `vless://` link and a Base64 subscription. The generated `clash.yaml` targets Mihomo/Clash.Meta-compatible clients.

## Reinstall / migrate existing VPS (Ubuntu 24.04)

Do this from an SSH session with a second session available. Keep the original session open until the final health check passes. The installer never edits the Alibaba Cloud security group.

### 1. Confirm SSH and take an explicit backup

Keep your current SSH session open and, ideally, have a second session ready. On the VPS:

```bash
sudo -i
ufw status numbered
ss -lntp
BKP="/root/myvpn-migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BKP"
cp -a /opt/my-vpn "$BKP/" 2>/dev/null || true
cp -a /etc/sing-box "$BKP/" 2>/dev/null || true
cp -a /etc/ufw "$BKP/" 2>/dev/null || true
for f in /etc/nginx/sites-available/my-vpn-subscription /etc/nginx/sites-enabled/my-vpn-subscription; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  cp -a --parents "$f" "$BKP/"
done
ufw status numbered > "$BKP/ufw-status-numbered.txt" 2>&1 || true
iptables-save > "$BKP/iptables-save.txt" 2>&1 || true
nft list ruleset > "$BKP/nft-ruleset.txt" 2>&1 || true
echo "Manual backup: $BKP"
```

The installer independently takes a second timestamped backup under `/var/backups/my-vpn/` before making changes. Do not delete either backup until the new node and subscription have been tested.

### 2. Upload and unpack the refactored bundle in a separate staging directory

Do not clone or unzip directly over `/opt/my-vpn`; it contains the live runtime environment and credentials. Download `myvpn-vless-reality-refactor.zip` from the conversation to your PC, then upload it to the server (WinSCP works, or use `scp`):

```powershell
scp .\myvpn-vless-reality-refactor.zip root@68.166.252.25:/root/
```

On the server:

```bash
apt-get update && apt-get install -y unzip
mkdir -p /opt/my-vpn-refactor-src
unzip -oq /root/myvpn-vless-reality-refactor.zip -d /opt/my-vpn-refactor-src
cd /opt/my-vpn-refactor-src
bash ./install.sh
```

The script takes another timestamped backup before changing live paths, migrates stable subscription settings (token/domain), creates a new UUID and REALITY keypair for the protocol migration, validates the service config, generates client artifacts, tests/reloads Nginx and checks service status. The refactor bundle can also be copied into a checkout and committed to GitHub after reviewing/testing it; it does not modify the remote repository by itself.

### 3. Open cloud security-group ports

In Alibaba Cloud ECS security group, allow inbound TCP 443 and TCP 80 from the source ranges you actually need. Keep TCP 22 (or your customized SSH port) available. This is separate from UFW.

### 4. Verify the host locally

```bash
sudo /opt/my-vpn/healthcheck.sh
sudo /opt/my-vpn/status.sh
sudo journalctl -u sing-box -n 100 --no-pager
sudo nginx -t
sudo ufw status numbered
```

Expect:
- sing-box enabled and active;
- TCP 443 listening;
- Nginx active and subscription URL returning HTTP 200;
- new firewall permits marked `# myvpn-managed`, except ports already broadly allowed by an unrelated rule.

### 5. Import into Shadowrocket

Copy the one-line contents of `/opt/my-vpn/clients/vless.txt` to the iPhone and import from clipboard, or add the printed subscription URL. Inspect the imported server fields if necessary:

- Type: VLESS
- Address: this server's public IPv4
- Port: 443
- Flow: `xtls-rprx-vision`
- TLS/Reality: enabled
- SNI: `www.microsoft.com`
- Fingerprint: `chrome`
- Public key and short ID: imported from the generated link

Do not disclose `server.env` or `clients/vless.txt`: they contain credentials.

### 6. Re-apply configuration or inspect status later

```bash
sudo /opt/my-vpn/apply-config.sh
sudo /opt/my-vpn/generate-config.sh
sudo /opt/my-vpn/healthcheck.sh
sudo /opt/my-vpn/status.sh
```

These scripts are intended to be idempotent: re-running them with unchanged settings should not rotate UUIDs/keys or add duplicate managed firewall rules.

### 7. Rollback

`apply-config.sh` restores its prior sing-box config when the new service fails to start. `nginx-setup.sh` restores its previous site when validation/reload fails. To manually restore a full pre-migration backup, inspect the latest backup first:

```bash
sudo cat /var/backups/my-vpn/latest
sudo find /var/backups/my-vpn -maxdepth 2 -type f -printf '%p\n' | sort
```

Do not blindly extract a whole backup over `/`; restore only the specific project-owned paths required. The pre-migration config and project files are retained in the timestamped backup.

## Uninstall

```bash
sudo /opt/my-vpn/uninstall.sh
```

This requires confirmation, takes another backup, removes only the expected project-owned config/site and UFW rules carrying `myvpn-managed`, and does not uninstall Nginx/UFW/sing-box packages. The project directory is removed only after backup.
