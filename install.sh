#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/my-vpn"
ENV_FILE="${PROJECT_DIR}/server.env"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR=""
INSTALL_COMMITTED=false
INSTALLER_TMP=""

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root: sudo bash install.sh" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/apply-config.sh" && -f "$SCRIPT_DIR/generate-config.sh" ]] || { echo "ERROR: incomplete project directory: $SCRIPT_DIR" >&2; exit 1; }
case "$SCRIPT_DIR/" in "$PROJECT_DIR/"*) echo "ERROR: run from a separate staging directory, not $PROJECT_DIR." >&2; exit 1 ;; esac

rollback_install() {
  local rc=$?
  trap - EXIT ERR INT TERM
  [[ -z "$INSTALLER_TMP" ]] || rm -f "$INSTALLER_TMP"
  if [[ "$rc" -ne 0 && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" && "$INSTALL_COMMITTED" != true ]]; then
    if [[ -s "$BACKUP_DIR/firewall-added-this-run.txt" && -x "$PROJECT_DIR/firewall.sh" ]]; then
      "$PROJECT_DIR/firewall.sh" rollback "$BACKUP_DIR/firewall-added-this-run.txt" || true
    fi
    echo >&2
    echo "Installation failed; attempting to restore prior service/Nginx state from $BACKUP_DIR" >&2
    if [[ -f "$BACKUP_DIR/etc-sing-box/config.json" ]]; then
      install -d -m 700 /etc/sing-box
      cp -a "$BACKUP_DIR/etc-sing-box/config.json" /etc/sing-box/config.json
      systemctl restart sing-box || true
    elif [[ -f /etc/sing-box/config.json ]] && grep -q 'myvpn-vless-reality-in' /etc/sing-box/config.json; then
      rm -f /etc/sing-box/config.json
      systemctl stop sing-box || true
    fi
    if [[ -f "$BACKUP_DIR/.had-nginx-available" ]]; then
      cp -a "$BACKUP_DIR/etc-nginx-sites-available/my-vpn-subscription" /etc/nginx/sites-available/my-vpn-subscription
    elif [[ -f /etc/nginx/sites-available/my-vpn-subscription ]] && grep -q 'managed-by-my-vpn' /etc/nginx/sites-available/my-vpn-subscription; then
      rm -f /etc/nginx/sites-available/my-vpn-subscription
    fi
    if [[ -f "$BACKUP_DIR/.had-nginx-enabled" ]]; then
      cp -a "$BACKUP_DIR/etc-nginx-sites-enabled/my-vpn-subscription" /etc/nginx/sites-enabled/my-vpn-subscription
    elif [[ -L /etc/nginx/sites-enabled/my-vpn-subscription ]] && [[ "$(readlink -f /etc/nginx/sites-enabled/my-vpn-subscription || true)" == "/etc/nginx/sites-available/my-vpn-subscription" ]]; then
      rm -f /etc/nginx/sites-enabled/my-vpn-subscription
    fi
    nginx -t && systemctl reload nginx || true
    # Restore only the subscription directory owned by this project.
    if [[ -f "$BACKUP_DIR/.had-public-dir" ]]; then
      rm -rf /var/www/my-vpn
      cp -a "$BACKUP_DIR/var-www-my-vpn" /var/www/my-vpn
    elif [[ -f /var/www/my-vpn/.myvpn-managed ]]; then
      rm -f /var/www/my-vpn/subscribe.txt /var/www/my-vpn/subscribe.txt.new /var/www/my-vpn/.myvpn-managed
      rmdir /var/www/my-vpn 2>/dev/null || true
    fi
    # Restore the complete former project (including its scripts and env), not just server.env.
    if [[ -f "$BACKUP_DIR/.had-project" ]]; then
      rm -rf "$PROJECT_DIR"
      cp -a "$BACKUP_DIR/opt-my-vpn" "$PROJECT_DIR"
    else
      rm -rf "$PROJECT_DIR"
    fi
  fi
  exit "$rc"
}
trap rollback_install EXIT

# A root-only snapshot is created before apt, code, config, Nginx or firewall changes.
BACKUP_DIR="$(bash "$SCRIPT_DIR/backup.sh" --path-only)"
echo "Pre-install backup: $BACKUP_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq openssl nginx ufw qrencode iproute2

# REALITY support requires a current sing-box version. Upgrade only when absent/too old.
need_singbox_install=true
if command -v sing-box >/dev/null 2>&1; then
  current="$(sing-box version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -n "$current" ]] && [[ "$(printf '%s\n' 1.11.0 "$current" | sort -V | head -n1)" == "1.11.0" ]]; then
    need_singbox_install=false
  fi
fi
if [[ "$need_singbox_install" == true ]]; then
  INSTALLER_TMP="$(mktemp)"
  curl -fsSL https://sing-box.app/install.sh -o "$INSTALLER_TMP"
  bash "$INSTALLER_TMP"
  rm -f "$INSTALLER_TMP"
  INSTALLER_TMP=""
fi
command -v sing-box >/dev/null 2>&1 || { echo "ERROR: sing-box installation failed." >&2; exit 1; }

install -d -m 700 "$PROJECT_DIR"
# Do not copy .git, runtime env or generated client credentials over the live directory.
tar --exclude=.git --exclude=server.env --exclude=clients -cf - -C "$SCRIPT_DIR" . | tar -xf - -C "$PROJECT_DIR"
chmod 700 "$PROJECT_DIR"
install -d -m 700 "$PROJECT_DIR/clients"
chmod +x "$PROJECT_DIR"/*.sh

# Load the previous env only to migrate stable subscription settings. The old Shadowsocks
# port/password are intentionally not reused; new VLESS+REALITY defaults to TCP/443.
OLD_PUBLIC_IP=""; OLD_TOKEN=""; OLD_DOMAIN=""; OLD_ENABLE_SUB="true"
OLD_ENABLE_UFW="true"; OLD_SSH_PORT="22"; OLD_NGINX_PORT="80"; OLD_NODE_NAME="US-Aliyun"
OLD_REALITY_UUID=""; OLD_REALITY_PRIVATE=""; OLD_REALITY_PUBLIC=""; OLD_REALITY_SHORT=""
OLD_SERVER_PORT="443"; OLD_SNI="www.microsoft.com"; OLD_HANDSHAKE="www.microsoft.com"; OLD_HANDSHAKE_PORT="443"
OLD_PROTOCOL=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  OLD_PROTOCOL="${PROTOCOL:-}"
  OLD_PUBLIC_IP="${PUBLIC_IP:-}"
  OLD_TOKEN="${SUBSCRIBE_TOKEN:-}"
  OLD_DOMAIN="${DOMAIN:-}"
  OLD_ENABLE_SUB="${ENABLE_SUBSCRIPTION:-true}"
  OLD_ENABLE_UFW="${ENABLE_UFW:-true}"
  OLD_SSH_PORT="${SSH_PORT:-22}"
  OLD_NGINX_PORT="${NGINX_HTTP_PORT:-80}"
  OLD_NODE_NAME="${NODE_NAME:-US-Aliyun}"
  OLD_REALITY_UUID="${VLESS_UUID:-}"
  OLD_REALITY_PRIVATE="${REALITY_PRIVATE_KEY:-}"
  OLD_REALITY_PUBLIC="${REALITY_PUBLIC_KEY:-}"
  OLD_REALITY_SHORT="${REALITY_SHORT_ID:-}"
  OLD_SNI="${REALITY_SNI:-www.microsoft.com}"
  OLD_HANDSHAKE="${REALITY_HANDSHAKE_SERVER:-${REALITY_SNI:-www.microsoft.com}}"
  OLD_HANDSHAKE_PORT="${REALITY_HANDSHAKE_PORT:-443}"
  if [[ "$OLD_PROTOCOL" == "vless-reality" ]]; then OLD_SERVER_PORT="${SERVER_PORT:-443}"; fi
fi

PUBLIC_IP="$OLD_PUBLIC_IP"
if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(curl -4 -fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org || true)"
fi
[[ -n "$PUBLIC_IP" ]] || { echo "ERROR: could not detect public IPv4; set PUBLIC_IP in $ENV_FILE and rerun." >&2; exit 1; }
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "ERROR: PUBLIC_IP must be an IPv4 address for this profile." >&2; exit 1; }

VLESS_UUID="$OLD_REALITY_UUID"
REALITY_PRIVATE_KEY="$OLD_REALITY_PRIVATE"
REALITY_PUBLIC_KEY="$OLD_REALITY_PUBLIC"
REALITY_SHORT_ID="$OLD_REALITY_SHORT"
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$VLESS_UUID" ]]; then VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"; fi
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  keypair="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
fi
if [[ -z "$VLESS_UUID" || -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  echo "ERROR: failed to generate VLESS UUID / REALITY key pair. Check 'sing-box generate reality-keypair'." >&2
  exit 1
fi
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$REALITY_SHORT_ID" ]]; then REALITY_SHORT_ID="$(openssl rand -hex 8)"; fi
SUBSCRIBE_TOKEN="$OLD_TOKEN"; [[ -n "$SUBSCRIBE_TOKEN" ]] || SUBSCRIBE_TOKEN="$(openssl rand -hex 24)"

# Old scripts advertised an HTTPS toggle but generated an HTTP-only Nginx server block.
# Preserve a domain but make the actual supported transport explicit and safe.
if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
  echo "NOTE: old ENABLE_HTTPS=true is not migrated: the previous Nginx script did not configure certificate/key paths. This deployment keeps HTTP subscription on port $OLD_NGINX_PORT; configure TLS separately before exposing subscription credentials." >&2
fi

TMP_ENV="$(mktemp "${PROJECT_DIR}/server.env.XXXXXX")"
{
  printf '# Generated by myvpn installer. Root-only; contains private keys.\n'
  printf 'PROTOCOL=%q\n' 'vless-reality'
  printf 'SERVER_PORT=%q\n' "$OLD_SERVER_PORT"
  printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
  printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
  printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
  printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
  printf 'REALITY_SNI=%q\n' "$OLD_SNI"
  printf 'REALITY_HANDSHAKE_SERVER=%q\n' "$OLD_HANDSHAKE"
  printf 'REALITY_HANDSHAKE_PORT=%q\n' "$OLD_HANDSHAKE_PORT"
  printf 'NODE_NAME=%q\n' "$OLD_NODE_NAME"
  printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP"
  printf 'ENABLE_SUBSCRIPTION=%q\n' "$OLD_ENABLE_SUB"
  printf 'SUBSCRIBE_TOKEN=%q\n' "$SUBSCRIBE_TOKEN"
  printf 'DOMAIN=%q\n' "$OLD_DOMAIN"
  printf 'ENABLE_HTTPS=%q\n' 'false'
  printf 'NGINX_HTTP_PORT=%q\n' "$OLD_NGINX_PORT"
  printf 'ENABLE_UFW=%q\n' "$OLD_ENABLE_UFW"
  printf 'SSH_PORT=%q\n' "$OLD_SSH_PORT"
} > "$TMP_ENV"
chmod 600 "$TMP_ENV"
mv -f "$TMP_ENV" "$ENV_FILE"

"$PROJECT_DIR/apply-config.sh"
"$PROJECT_DIR/generate-config.sh"
"$PROJECT_DIR/nginx-setup.sh"

if [[ "${OLD_ENABLE_UFW}" == "true" ]]; then
  : > "$BACKUP_DIR/firewall-added-this-run.txt"
  MYVPN_FIREWALL_JOURNAL="$BACKUP_DIR/firewall-added-this-run.txt" \
    "$PROJECT_DIR/firewall.sh" ensure "$OLD_SSH_PORT" "$OLD_SERVER_PORT" "$OLD_NGINX_PORT"
else
  echo "ENABLE_UFW=false: no firewall rules were changed."
fi

"$PROJECT_DIR/healthcheck.sh"
INSTALL_COMMITTED=true
trap - EXIT

echo
echo "Install succeeded."
echo "Backup: $BACKUP_DIR"
echo "Endpoint: ${PUBLIC_IP}:${OLD_SERVER_PORT}/tcp (VLESS + REALITY)"
echo "Config: ${PROJECT_DIR}/server.env"
echo "Client URI: ${PROJECT_DIR}/clients/vless.txt"
echo "Subscription: use the URL printed by generate-config.sh"
echo "Remember: also allow TCP ${OLD_SERVER_PORT} and TCP ${OLD_NGINX_PORT} in the Alibaba Cloud security group."
