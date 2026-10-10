#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_PROJECT_DIR:-$SCRIPT_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="/var/backups/my-vpn"
DEST="${BACKUP_ROOT}/${STAMP}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

mkdir -p "$DEST"
chmod 700 "$BACKUP_ROOT" "$DEST"
mkdir -p "$DEST/opt-my-vpn" "$DEST/etc-sing-box" \
  "$DEST/etc-nginx-sites-available" "$DEST/etc-nginx-sites-enabled" "$DEST/var-www-my-vpn"

if [[ -d "$PROJECT_DIR" ]]; then
  touch "$DEST/.had-project"
  cp -a "$PROJECT_DIR/." "$DEST/opt-my-vpn/"
fi
if [[ -f /etc/sing-box/config.json ]]; then
  touch "$DEST/.had-sing-box-config"
  cp -a /etc/sing-box/config.json "$DEST/etc-sing-box/config.json"
fi
if [[ -e /etc/nginx/sites-available/my-vpn-subscription || -L /etc/nginx/sites-available/my-vpn-subscription ]]; then
  touch "$DEST/.had-nginx-available"
  cp -a /etc/nginx/sites-available/my-vpn-subscription "$DEST/etc-nginx-sites-available/"
fi
if [[ -e /etc/nginx/sites-enabled/my-vpn-subscription || -L /etc/nginx/sites-enabled/my-vpn-subscription ]]; then
  touch "$DEST/.had-nginx-enabled"
  cp -a /etc/nginx/sites-enabled/my-vpn-subscription "$DEST/etc-nginx-sites-enabled/"
fi
if [[ -d /var/www/my-vpn ]]; then
  touch "$DEST/.had-public-dir"
  cp -a /var/www/my-vpn/. "$DEST/var-www-my-vpn/"
fi

ufw status numbered > "$DEST/ufw-status-numbered.txt" 2>&1 || true
ufw status verbose > "$DEST/ufw-status-verbose.txt" 2>&1 || true
iptables-save > "$DEST/iptables-save.txt" 2>&1 || true
nft list ruleset > "$DEST/nft-ruleset.txt" 2>&1 || true
ss -lntup > "$DEST/listeners.txt" 2>&1 || true
systemctl status sing-box --no-pager > "$DEST/sing-box-status.txt" 2>&1 || true
nginx -T > "$DEST/nginx-config-dump.txt" 2>&1 || true
printf '%s\n' "$STAMP" > "$BACKUP_ROOT/latest"
chmod -R go-rwx "$DEST"

if [[ "${1:-}" == "--path-only" ]]; then
  printf '%s\n' "$DEST"
else
  echo "Backup completed: $DEST"
  echo "Contains the old project, sing-box config, the project Nginx site, firewall snapshots and service diagnostics."
fi
