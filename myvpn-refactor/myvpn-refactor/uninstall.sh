#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
CONFIG_FILE="/etc/sing-box/config.json"
NGINX_CONFIG="/etc/nginx/sites-available/my-vpn-subscription"
NGINX_LINK="/etc/nginx/sites-enabled/my-vpn-subscription"
PUBLIC_DIR="/var/www/my-vpn"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
read -r -p "This removes the my-vpn VLESS config/site and only UFW rules marked myvpn-managed. Backup first. Continue? [y/N]: " confirm
[[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Cancelled."; exit 0; }

BACKUP_DIR="$("$PROJECT_DIR/backup.sh" --path-only)"
echo "Backup: $BACKUP_DIR"

if [[ -f "$CONFIG_FILE" ]] && grep -q 'myvpn-vless-reality-in' "$CONFIG_FILE"; then
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$CONFIG_FILE"
  echo "Removed project-owned sing-box config. Package and /etc/sing-box directory were preserved."
else
  echo "Skipped sing-box config/service: no project marker found."
fi

if [[ -f "$NGINX_CONFIG" ]] && grep -q 'managed-by-my-vpn' "$NGINX_CONFIG"; then
  if [[ -L "$NGINX_LINK" ]] && [[ "$(readlink -f "$NGINX_LINK" || true)" == "$NGINX_CONFIG" ]]; then rm -f "$NGINX_LINK"; fi
  rm -f "$NGINX_CONFIG"
  nginx -t && systemctl reload nginx || echo "WARNING: inspect Nginx after removing the project site." >&2
else
  echo "Skipped Nginx site: no project marker found."
fi

"$PROJECT_DIR/firewall.sh" remove || true
if [[ -f "$PUBLIC_DIR/.myvpn-managed" ]]; then
  rm -f "$PUBLIC_DIR/subscribe.txt" "$PUBLIC_DIR/.myvpn-managed"
  rmdir "$PUBLIC_DIR" 2>/dev/null || true
fi
rm -rf "$PROJECT_DIR"
echo "Uninstall complete. Nginx, UFW, sing-box packages and backups were retained."
