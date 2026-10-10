#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_PROJECT_DIR:-$SCRIPT_DIR}"
ENV_FILE="${PROJECT_DIR}/server.env"
CLIENT_DIR="${PROJECT_DIR}/client"
PUBLIC_DIR="/var/www/my-vpn"
CONFIG_FILE="/etc/sing-box/config.json"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root: sudo ./generate-config.sh" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Run install.sh first; do not use server.env.example as server.env." >&2; exit 1; }
[[ -f "$PROJECT_DIR/lib.sh" ]] || { echo "ERROR: $PROJECT_DIR/lib.sh not found. Replace the project files with the complete package." >&2; exit 1; }
# shellcheck source=lib.sh
source "$PROJECT_DIR/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is missing; run install.sh first." >&2; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo "ERROR: sing-box is missing; run install.sh first." >&2; exit 1; }

# Load saved settings. Credentials are repaired only when missing. In particular,
# try to recover a missing UUID from the active server config before creating a new one.
# shellcheck disable=SC1090
source "$ENV_FILE"
SERVER_PORT="${SERVER_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_HANDSHAKE_SERVER="${REALITY_HANDSHAKE_SERVER:-$REALITY_SNI}"
REALITY_HANDSHAKE_PORT="${REALITY_HANDSHAKE_PORT:-443}"
NODE_NAME="${NODE_NAME:-US-Aliyun}"
ENABLE_SUBSCRIPTION="${ENABLE_SUBSCRIPTION:-true}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
SUBSCRIBE_TOKEN="${SUBSCRIBE_TOKEN:-}"
VLESS_UUID="${VLESS_UUID:-}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
SAVED_PUBLIC_IP="${PUBLIC_IP:-}"

# Always try to refresh PUBLIC_IP so the client profile does not keep advertising an old IP.
PUBLIC_IP="$(myvpn_detect_public_ipv4 || true)"
if [[ -z "$PUBLIC_IP" ]]; then
  if myvpn_is_ipv4 "$SAVED_PUBLIC_IP"; then
    PUBLIC_IP="$SAVED_PUBLIC_IP"
    echo "WARNING: public IPv4 auto-detection failed; using the saved PUBLIC_IP=$PUBLIC_IP." >&2
  else
    echo "ERROR: cannot detect the VPS public IPv4 address and no valid saved PUBLIC_IP exists. Check outbound HTTPS, then rerun." >&2
    exit 1
  fi
fi

if [[ -z "$VLESS_UUID" && -f "$CONFIG_FILE" ]]; then
  VLESS_UUID="$(jq -r '.inbounds[]? | select(.tag == "myvpn-vless-reality-in") | .users[0].uuid // empty' "$CONFIG_FILE" 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$VLESS_UUID" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  echo "Initialized missing VLESS_UUID."
fi

# If either half of the REALITY key pair is missing, create a complete new pair.
# apply-config.sh below applies it to the server before client files are generated.
if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  keypair="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
fi
if [[ -z "$REALITY_SHORT_ID" ]]; then REALITY_SHORT_ID="$(openssl rand -hex 8)"; fi
if [[ -z "$SUBSCRIBE_TOKEN" ]]; then SUBSCRIBE_TOKEN="$(openssl rand -hex 24)"; fi

# Persist the refreshed IP and any repaired settings without overwriting other server.env fields.
myvpn_set_env_value "$ENV_FILE" PUBLIC_IP "$PUBLIC_IP"
myvpn_set_env_value "$ENV_FILE" SERVER_PORT "$SERVER_PORT"
myvpn_set_env_value "$ENV_FILE" VLESS_UUID "$VLESS_UUID"
myvpn_set_env_value "$ENV_FILE" REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
myvpn_set_env_value "$ENV_FILE" REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
myvpn_set_env_value "$ENV_FILE" REALITY_SHORT_ID "$REALITY_SHORT_ID"
myvpn_set_env_value "$ENV_FILE" REALITY_SNI "$REALITY_SNI"
myvpn_set_env_value "$ENV_FILE" REALITY_HANDSHAKE_SERVER "$REALITY_HANDSHAKE_SERVER"
myvpn_set_env_value "$ENV_FILE" REALITY_HANDSHAKE_PORT "$REALITY_HANDSHAKE_PORT"
myvpn_set_env_value "$ENV_FILE" NODE_NAME "$NODE_NAME"
myvpn_set_env_value "$ENV_FILE" ENABLE_SUBSCRIPTION "$ENABLE_SUBSCRIPTION"
myvpn_set_env_value "$ENV_FILE" NGINX_HTTP_PORT "$NGINX_HTTP_PORT"
myvpn_set_env_value "$ENV_FILE" SUBSCRIBE_TOKEN "$SUBSCRIBE_TOKEN"

# Re-apply the server-side config before publishing client credentials. If UUID or
# the key pair was repaired above, this keeps the server and generated client in sync.
"$PROJECT_DIR/apply-config.sh"
# Reload normalized env after the apply step.
# shellcheck disable=SC1090
source "$ENV_FILE"

for key in SERVER_PORT PUBLIC_IP VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI NODE_NAME; do
  [[ -n "${!key:-}" ]] || { echo "ERROR: $key is still empty after initialization; inspect $ENV_FILE." >&2; exit 1; }
done
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || { echo "ERROR: invalid SERVER_PORT." >&2; exit 1; }
myvpn_is_ipv4 "$PUBLIC_IP" || { echo "ERROR: PUBLIC_IP is not a valid IPv4 address: $PUBLIC_IP" >&2; exit 1; }
[[ "$VLESS_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "ERROR: VLESS_UUID is not a valid UUID after initialization." >&2; exit 1; }
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._\ -]+$ ]] || { echo "ERROR: NODE_NAME may contain only letters, numbers, space, dot, underscore and hyphen." >&2; exit 1; }
[[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid REALITY_SNI." >&2; exit 1; }
[[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]+$ && "$REALITY_SHORT_ID" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] || { echo "ERROR: invalid REALITY_PUBLIC_KEY or REALITY_SHORT_ID." >&2; exit 1; }

install -d -m 700 "$CLIENT_DIR"
NAME_ENC="$(jq -rn --arg value "$NODE_NAME" '$value|@uri')"
URI="vless://${VLESS_UUID}@${PUBLIC_IP}:${SERVER_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${NAME_ENC}"
printf '%s\n' "$URI" > "$CLIENT_DIR/vless.txt"
chmod 600 "$CLIENT_DIR/vless.txt"
printf '%s' "$URI" | base64 -w 0 > "$CLIENT_DIR/subscribe.txt"
printf '\n' >> "$CLIENT_DIR/subscribe.txt"
chmod 600 "$CLIENT_DIR/subscribe.txt"

if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
  install -d -m 755 "$PUBLIC_DIR"
  touch "$PUBLIC_DIR/.myvpn-managed"
  chmod 644 "$PUBLIC_DIR/.myvpn-managed"
  install -m 644 "$CLIENT_DIR/subscribe.txt" "$PUBLIC_DIR/subscribe.txt.new"
  mv -f "$PUBLIC_DIR/subscribe.txt.new" "$PUBLIC_DIR/subscribe.txt"
else
  if [[ -f "$PUBLIC_DIR/.myvpn-managed" ]]; then
    rm -f "$PUBLIC_DIR/subscribe.txt" "$PUBLIC_DIR/.myvpn-managed"
    rmdir "$PUBLIC_DIR" 2>/dev/null || true
  fi
fi

jq -n \
  --arg server "$PUBLIC_IP" \
  --argjson port "$SERVER_PORT" \
  --arg uuid "$VLESS_UUID" \
  --arg sni "$REALITY_SNI" \
  --arg public_key "$REALITY_PUBLIC_KEY" \
  --arg short_id "$REALITY_SHORT_ID" \
  '{log:{level:"info"},inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],outbounds:[{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$public_key,short_id:$short_id}}},{type:"direct",tag:"direct"}],route:{final:"proxy"}}' \
  > "$CLIENT_DIR/sing-box.json"
chmod 600 "$CLIENT_DIR/sing-box.json"
sing-box check -c "$CLIENT_DIR/sing-box.json"

cat > "$CLIENT_DIR/clash.yaml" <<YAML
proxies:
  - name: "${NODE_NAME}"
    type: vless
    server: ${PUBLIC_IP}
    port: ${SERVER_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${NODE_NAME}"
      - DIRECT
rules:
  - MATCH,PROXY
YAML
chmod 600 "$CLIENT_DIR/clash.yaml"

# If the public IPv4 changed and Nginx is advertising that IP (no DOMAIN configured),
# refresh only this project's existing Nginx site so the subscription URL keeps working.
if [[ "$SAVED_PUBLIC_IP" != "$PUBLIC_IP" && -z "${DOMAIN:-}" && -f /etc/nginx/sites-available/my-vpn-subscription ]] \
  && grep -q 'managed-by-my-vpn' /etc/nginx/sites-available/my-vpn-subscription; then
  "$PROJECT_DIR/nginx-setup.sh"
fi

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$CLIENT_DIR/vless.png" "$URI"
  chmod 600 "$CLIENT_DIR/vless.png"
fi

if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
  if [[ -n "${DOMAIN:-}" ]]; then host="$DOMAIN"; else host="$PUBLIC_IP"; fi
  if [[ "${NGINX_HTTP_PORT:-80}" == "80" ]]; then port_suffix=""; else port_suffix=":${NGINX_HTTP_PORT}"; fi
  echo "Public IPv4 : $PUBLIC_IP (auto-detected)"
  echo "Client URI  : $CLIENT_DIR/vless.txt"
  echo "Sing-box    : $CLIENT_DIR/sing-box.json"
  echo "Mihomo      : $CLIENT_DIR/clash.yaml"
  echo "Subscription URL: http://${host}${port_suffix}/${SUBSCRIBE_TOKEN}/subscribe.txt"
else
  echo "Public IPv4 : $PUBLIC_IP (auto-detected)"
  echo "Client files: $CLIENT_DIR"
  echo "Subscription is disabled by ENABLE_SUBSCRIPTION=false."
fi
