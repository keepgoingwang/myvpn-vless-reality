#!/usr/bin/env bash
# 中文说明：读取当前项目目录的 server.env，生成、检查并应用 sing-box 服务端配置。
# 修改配置后只有校验通过且服务成功启动，才算应用成功。
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
# 中文说明：兼容历史配置中的小写 server_port；大写 SERVER_PORT 优先。
SERVER_PORT="${SERVER_PORT:-${server_port:-18388}}"
HY2_ENABLED="${HY2_ENABLED:-true}"
HY2_PORT="${HY2_PORT:-2096}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
HY2_SERVER_NAME="${HY2_SERVER_NAME:-hy2.local}"
HY2_CERT_PATH="${HY2_CERT_PATH:-/etc/sing-box/hy2-cert.pem}"
HY2_KEY_PATH="${HY2_KEY_PATH:-/etc/sing-box/hy2-key.pem}"

for key in SERVER_PORT VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI REALITY_HANDSHAKE_SERVER REALITY_HANDSHAKE_PORT; do
  [[ -n "${!key:-}" ]] || { echo "ERROR: $key is empty. Run install.sh to initialize keys." >&2; exit 1; }
done
[[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || { echo "ERROR: invalid SERVER_PORT; expected 1-65535." >&2; exit 1; }
[[ "$REALITY_HANDSHAKE_PORT" =~ ^[0-9]+$ ]] && (( REALITY_HANDSHAKE_PORT >= 1 && REALITY_HANDSHAKE_PORT <= 65535 )) || { echo "ERROR: invalid REALITY_HANDSHAKE_PORT; expected 1-65535." >&2; exit 1; }
[[ "$VLESS_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "ERROR: VLESS_UUID does not look like a UUID." >&2; exit 1; }
[[ "$REALITY_SHORT_ID" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] || { echo "ERROR: REALITY_SHORT_ID must be 2-16 hexadecimal characters." >&2; exit 1; }
[[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ && "$REALITY_HANDSHAKE_SERVER" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid SNI/handshake hostname." >&2; exit 1; }
[[ "$REALITY_SNI" == "$REALITY_HANDSHAKE_SERVER" ]] || { echo "ERROR: REALITY_SNI must match REALITY_HANDSHAKE_SERVER in this simple profile." >&2; exit 1; }
if [[ "$HY2_ENABLED" == "true" ]]; then
  [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && (( HY2_PORT >= 1 && HY2_PORT <= 65535 )) || { echo "ERROR: invalid HY2_PORT." >&2; exit 1; }
  [[ -n "$HY2_PASSWORD" ]] || { echo "ERROR: HY2_PASSWORD is empty; run generate-config.sh first." >&2; exit 1; }
  [[ "$HY2_SERVER_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: invalid HY2_SERVER_NAME." >&2; exit 1; }
  if [[ ! -s "$HY2_CERT_PATH" || ! -s "$HY2_KEY_PATH" ]]; then
    install -d -m 700 "$(dirname "$HY2_CERT_PATH")"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$HY2_KEY_PATH" -out "$HY2_CERT_PATH" -subj "/CN=${HY2_SERVER_NAME}" -addext "subjectAltName=DNS:${HY2_SERVER_NAME}" -days 3650
    chmod 600 "$HY2_KEY_PATH"; chmod 644 "$HY2_CERT_PATH"
  fi
fi

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

# 使用 jq 安全生成 JSON，避免手工拼接导致转义或格式错误。
jq -n \
  --arg uuid "$VLESS_UUID" --arg handshake "$REALITY_HANDSHAKE_SERVER" \
  --arg private_key "$REALITY_PRIVATE_KEY" --arg short_id "$REALITY_SHORT_ID" \
  --arg hy2_password "$HY2_PASSWORD" --arg hy2_cert "$HY2_CERT_PATH" --arg hy2_key "$HY2_KEY_PATH" \
  --arg hy2_server_name "$HY2_SERVER_NAME" \
  --argjson port "$SERVER_PORT" --argjson handshake_port "$REALITY_HANDSHAKE_PORT" \
  --argjson hy2_port "$HY2_PORT" \
  --argjson hy2_enabled "$([[ "$HY2_ENABLED" == "true" ]] && echo true || echo false)" \
  '{
    log: {level: "info", timestamp: true},
    inbounds: ([{
      type: "vless", tag: "myvpn-vless-reality-in", listen: "0.0.0.0",
      listen_port: $port,
      users: [{name: "myvpn-client", uuid: $uuid, flow: "xtls-rprx-vision"}],
      tls: {enabled: true, reality: {
        enabled: true, handshake: {server: $handshake, server_port: $handshake_port},
        private_key: $private_key, short_id: [$short_id]
      }}
    }] + (if $hy2_enabled then [{
      type: "hysteria2", tag: "myvpn-hy2-in", listen: "0.0.0.0",
      listen_port: $hy2_port, users: [{name: "myvpn-client", password: $hy2_password}],
      tls: {enabled: true, certificate_path: $hy2_cert, key_path: $hy2_key}
    }] else [] end)),
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
  [[ "$HY2_ENABLED" != "true" ]] || echo "HY2 endpoint: ${PUBLIC_IP:-<set PUBLIC_IP>}:${HY2_PORT}/udp"
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
