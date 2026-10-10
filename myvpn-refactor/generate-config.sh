#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_PROJECT_DIR:-$SCRIPT_DIR}"
ENV_FILE="${PROJECT_DIR}/server.env"
CLIENT_DIR="${PROJECT_DIR}/client"
PUBLIC_DIR="/var/www/my-vpn"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
for key in SERVER_PORT PUBLIC_IP VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI NODE_NAME; do
  [[ -n "${!key:-}" ]] || { echo "ERROR: $key is empty." >&2; exit 1; }
done
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._\ -]+$ ]] || { echo "ERROR: NODE_NAME may contain only letters, numbers, space, dot, underscore and hyphen." >&2; exit 1; }
[[ "$PUBLIC_IP" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "ERROR: PUBLIC_IP contains unsupported characters." >&2; exit 1; }

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

# Mihomo / Clash.Meta format. NODE_NAME is restricted above to keep this YAML safe.
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

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "$CLIENT_DIR/vless.png" "$URI"
  chmod 600 "$CLIENT_DIR/vless.png"
fi

if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
  if [[ -n "${DOMAIN:-}" ]]; then host="$DOMAIN"; else host="$PUBLIC_IP"; fi
  if [[ "${NGINX_HTTP_PORT:-80}" == "80" ]]; then port_suffix=""; else port_suffix=":${NGINX_HTTP_PORT}"; fi
  echo "Client URI : $CLIENT_DIR/vless.txt"
  echo "Sing-box   : $CLIENT_DIR/sing-box.json"
  echo "Mihomo     : $CLIENT_DIR/clash.yaml"
  echo "Subscription URL: http://${host}${port_suffix}/${SUBSCRIBE_TOKEN}/subscribe.txt"
else
  echo "Subscription is disabled by ENABLE_SUBSCRIPTION=false."
fi
