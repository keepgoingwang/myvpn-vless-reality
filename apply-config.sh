#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_PROJECT_DIR:-$SCRIPT_DIR}"
ENV_FILE="${PROJECT_DIR}/server.env"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found; run install.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

for key in SERVER_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI REALITY_HANDSHAKE_SERVER REALITY_HANDSHAKE_PORT; do
  [[ -n "${!key:-}" ]] || { echo "ERROR: $key is empty. Run install.sh to initialize keys." >&2; exit 1; }
done
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || { echo "ERROR: invalid SERVER_PORT." >&2; exit 1; }
[[ "$REALITY_HANDSHAKE_PORT" =~ ^[0-9]+$ ]] && (( REALITY_HANDSHAKE_PORT >= 1 && REALITY_HANDSHAKE_PORT <= 65535 )) || { echo "ERROR: invalid REALITY_HANDSHAKE_PORT." >&2; exit 1; }
[[ "$VLESS_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "ERROR: VLESS_UUID does not look like a UUID." >&2; exit 1; }
[[ "$REALITY_SHORT_ID" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] || { echo "ERROR: REALITY_SHORT_ID must be 2-16 hexadecimal characters." >&2; exit 1; }
[[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ && "$REALITY_HANDSHAKE_SERVER" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid SNI/handshake hostname." >&2; exit 1; }
[[ "$REALITY_SNI" == "$REALITY_HANDSHAKE_SERVER" ]] || { echo "ERROR: REALITY_SNI must match REALITY_HANDSHAKE_SERVER in this simple profile." >&2; exit 1; }

install -d -m 700 "$CONFIG_DIR"
TMP_CONFIG="$(mktemp "${CONFIG_DIR}/config.json.new.XXXXXX")"
OLD_CONFIG=""
if [[ -f "$CONFIG_FILE" ]]; then
  OLD_CONFIG="$(mktemp "${CONFIG_DIR}/config.json.rollback.XXXXXX")"
  cp -a "$CONFIG_FILE" "$OLD_CONFIG"
fi
cleanup() {
  rm -f "$TMP_CONFIG"
  [[ -z "$OLD_CONFIG" ]] || rm -f "$OLD_CONFIG"
}
trap cleanup EXIT

jq -n \
  --arg tag "myvpn-vless-reality-in" \
  --arg uuid "$VLESS_UUID" \
  --arg flow "xtls-rprx-vision" \
  --arg handshake "$REALITY_HANDSHAKE_SERVER" \
  --arg private_key "$REALITY_PRIVATE_KEY" \
  --arg short_id "$REALITY_SHORT_ID" \
  --argjson port "$SERVER_PORT" \
  --argjson handshake_port "$REALITY_HANDSHAKE_PORT" \
  '{
    log: {level: "info", timestamp: true},
    inbounds: [{
      type: "vless",
      tag: $tag,
      listen: "0.0.0.0",
      listen_port: $port,
      users: [{name: "myvpn-client", uuid: $uuid, flow: $flow}],
      tls: {
        enabled: true,
        reality: {
          enabled: true,
          handshake: {server: $handshake, server_port: $handshake_port},
          private_key: $private_key,
          short_id: [$short_id]
        }
      }
    }],
    outbounds: [{type: "direct", tag: "direct"}]
  }' > "$TMP_CONFIG"

sing-box format -w -c "$TMP_CONFIG"
sing-box check -c "$TMP_CONFIG"
chmod 600 "$TMP_CONFIG"

if [[ -f "$CONFIG_FILE" ]] && cmp -s "$TMP_CONFIG" "$CONFIG_FILE"; then
  echo "sing-box config unchanged; no restart needed."
  exit 0
fi

mv -f "$TMP_CONFIG" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
systemctl enable sing-box >/dev/null
if systemctl restart sing-box && systemctl is-active --quiet sing-box; then
  echo "Applied VLESS + REALITY configuration successfully."
  echo "Listening endpoint: ${PUBLIC_IP:-<set PUBLIC_IP>}:${SERVER_PORT}/tcp"
else
  echo "ERROR: new configuration failed to start; restoring previous configuration." >&2
  if [[ -n "$OLD_CONFIG" && -f "$OLD_CONFIG" ]]; then
    cp -a "$OLD_CONFIG" "$CONFIG_FILE"
    systemctl restart sing-box || true
  else
    rm -f "$CONFIG_FILE"
    systemctl stop sing-box || true
  fi
  systemctl status sing-box --no-pager || true
  exit 1
fi
