#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_PROJECT_DIR:-$SCRIPT_DIR}"
ENV_FILE="${PROJECT_DIR}/server.env"
NGINX_CONFIG="/etc/nginx/sites-available/my-vpn-subscription"
NGINX_LINK="/etc/nginx/sites-enabled/my-vpn-subscription"
PUBLIC_FILE="/var/www/my-vpn/subscribe.txt"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ "${ENABLE_SUBSCRIPTION:-true}" != "true" ]]; then
  if [[ -f "$NGINX_CONFIG" ]] && grep -q 'managed-by-my-vpn' "$NGINX_CONFIG"; then
    if [[ -L "$NGINX_LINK" ]] && [[ "$(readlink -f "$NGINX_LINK" || true)" == "$NGINX_CONFIG" ]]; then rm -f "$NGINX_LINK"; fi
    rm -f "$NGINX_CONFIG"
    nginx -t && systemctl reload nginx
    echo "Removed the project-owned Nginx subscription site (subscription disabled)."
  else
    echo "Subscription disabled; no project-owned Nginx site to remove."
  fi
  exit 0
fi
[[ -s "$PUBLIC_FILE" ]] || { echo "ERROR: generated subscription file missing: $PUBLIC_FILE" >&2; exit 1; }
[[ -n "${SUBSCRIBE_TOKEN:-}" && "$SUBSCRIBE_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || { echo "ERROR: invalid SUBSCRIBE_TOKEN." >&2; exit 1; }
[[ "${NGINX_HTTP_PORT:-80}" =~ ^[0-9]+$ ]] && (( NGINX_HTTP_PORT >= 1 && NGINX_HTTP_PORT <= 65535 )) || { echo "ERROR: invalid NGINX_HTTP_PORT." >&2; exit 1; }
[[ "${DOMAIN:-${PUBLIC_IP:-}}" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "ERROR: invalid DOMAIN/PUBLIC_IP for Nginx server_name." >&2; exit 1; }
if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
  echo "ERROR: This version preserves the HTTP subscription path only; it does not provision/manage TLS certificates. Set ENABLE_HTTPS=false unless you configure HTTPS separately." >&2
  exit 1
fi

if [[ -e "$NGINX_LINK" || -L "$NGINX_LINK" ]]; then
  target="$(readlink -f "$NGINX_LINK" || true)"
  if [[ "$target" != "$NGINX_CONFIG" ]]; then
    echo "ERROR: $NGINX_LINK points to another site ($target); refusing to overwrite it." >&2
    exit 1
  fi
fi

install -d -m 755 /etc/nginx/sites-available /etc/nginx/sites-enabled
TMP_CONFIG="$(mktemp /etc/nginx/sites-available/.my-vpn-subscription.XXXXXX)"
OLD_CONFIG=""
LINK_WAS_OWNED=false
if [[ -f "$NGINX_CONFIG" ]]; then
  OLD_CONFIG="$(mktemp /etc/nginx/sites-available/.my-vpn-rollback.XXXXXX)"
  cp -a "$NGINX_CONFIG" "$OLD_CONFIG"
fi
if [[ -L "$NGINX_LINK" && "$(readlink "$NGINX_LINK")" == "$NGINX_CONFIG" ]]; then LINK_WAS_OWNED=true; fi

server_name="${DOMAIN:-$PUBLIC_IP}"
cat > "$TMP_CONFIG" <<NGINX
# managed-by-my-vpn; do not edit by hand
server {
    listen ${NGINX_HTTP_PORT};
    listen [::]:${NGINX_HTTP_PORT};
    server_name ${server_name};

    location = /${SUBSCRIBE_TOKEN}/subscribe.txt {
        alias ${PUBLIC_FILE};
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Access-Control-Allow-Origin "*" always;
    }

    location / {
        return 404;
    }
}
NGINX
chmod 644 "$TMP_CONFIG"
cp -f "$TMP_CONFIG" "$NGINX_CONFIG"
ln -sfn "$NGINX_CONFIG" "$NGINX_LINK"

if nginx -t; then
  if systemctl enable nginx >/dev/null && systemctl reload nginx; then
    rm -f "$TMP_CONFIG"
    [[ -z "$OLD_CONFIG" ]] || rm -f "$OLD_CONFIG"
  else
    echo "ERROR: Nginx reload failed; restoring old project site." >&2
    if [[ -n "$OLD_CONFIG" && -f "$OLD_CONFIG" ]]; then cp -a "$OLD_CONFIG" "$NGINX_CONFIG"; else rm -f "$NGINX_CONFIG"; fi
    if [[ "$LINK_WAS_OWNED" != true ]]; then rm -f "$NGINX_LINK"; fi
    nginx -t && systemctl reload nginx || true
    rm -f "$TMP_CONFIG"
    [[ -z "$OLD_CONFIG" ]] || rm -f "$OLD_CONFIG"
    exit 1
  fi
else
  echo "ERROR: Nginx config test failed; restoring old project site." >&2
  if [[ -n "$OLD_CONFIG" && -f "$OLD_CONFIG" ]]; then cp -a "$OLD_CONFIG" "$NGINX_CONFIG"; else rm -f "$NGINX_CONFIG"; fi
  if [[ "$LINK_WAS_OWNED" != true ]]; then rm -f "$NGINX_LINK"; fi
  nginx -t && systemctl reload nginx || true
  rm -f "$TMP_CONFIG"
    [[ -z "$OLD_CONFIG" ]] || rm -f "$OLD_CONFIG"
  exit 1
fi

echo "Nginx subscription site configured."
