#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="/opt/my-vpn"
ENV_FILE="${PROJECT_DIR}/server.env"
[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
failed=0
check() { local label="$1"; shift; if "$@"; then printf '[OK]   %s\n' "$label"; else printf '[FAIL] %s\n' "$label"; failed=1; fi; }
check "sing-box config syntax" sing-box check -c /etc/sing-box/config.json
check "sing-box service enabled" systemctl is-enabled --quiet sing-box
check "sing-box service active" systemctl is-active --quiet sing-box
check "proxy TCP listener ${SERVER_PORT}" bash -c "ss -lntH 'sport = :${SERVER_PORT}' | grep -q ."

if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
  check "Nginx service active" systemctl is-active --quiet nginx
  if command -v curl >/dev/null 2>&1; then
    host="${DOMAIN:-$PUBLIC_IP}"
    base="http://127.0.0.1:${NGINX_HTTP_PORT}"
    check_file="$(mktemp)"
    http_code="$(curl -sS --max-time 5 -o "$check_file" -w '%{http_code}' -H "Host: ${host}" "${base}/${SUBSCRIBE_TOKEN}/subscribe.txt" || true)"
    if [[ "$http_code" == "200" ]] && [[ -s "$check_file" ]] && cmp -s "$check_file" /var/www/my-vpn/subscribe.txt; then
      echo "[OK]   subscription HTTP endpoint (200; content matches generated file)"
    else
      echo "[FAIL] subscription HTTP endpoint/content (status ${http_code:-unknown})"
      failed=1
    fi
    rm -f "$check_file"
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  echo
  echo "Diagnostics: systemctl status sing-box --no-pager; journalctl -u sing-box -n 100 --no-pager; nginx -t" >&2
  exit 1
fi
echo "Health check passed. This verifies local configuration/services, not reachability through every ISP or network path."
