#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/opt/my-vpn"
ENV_FILE="${PROJECT_DIR}/server.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
echo "=== My VPN status ==="
printf 'Protocol : %s\n' "${PROTOCOL:-unknown}"
printf 'Endpoint : %s:%s/tcp\n' "${PUBLIC_IP:-unknown}" "${SERVER_PORT:-unknown}"
printf 'Service  : '; systemctl is-active sing-box || true
printf 'Enabled  : '; systemctl is-enabled sing-box || true
printf 'Nginx    : '; systemctl is-active nginx || true
printf 'Listener :\n'; ss -lntp "sport = :${SERVER_PORT:-0}" || true
if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
  host="${DOMAIN:-$PUBLIC_IP}"
  suffix=""; [[ "${NGINX_HTTP_PORT:-80}" == "80" ]] || suffix=":${NGINX_HTTP_PORT}"
  echo "Subscription URL: http://${host}${suffix}/${SUBSCRIBE_TOKEN}/subscribe.txt"
fi
echo "Client files are under ${PROJECT_DIR}/clients (root-only permissions)."
