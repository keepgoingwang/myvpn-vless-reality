#!/usr/bin/env bash
# 中文说明：首次安装或迁移安装 MyVPN；读取仓库根目录 server.env 模板，生成独立的运行配置。
# 安全提示：运行配置包含 REALITY 私钥和订阅凭据，请勿提交到公开仓库。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${MYVPN_INSTALL_DIR:-/opt/my-vpn}"
ENV_FILE="${PROJECT_DIR}/server.env"
BACKUP_DIR=""
INSTALL_COMMITTED=false
INSTALLER_TMP=""

[[ "$(id -u)" -eq 0 ]] || { echo "ERROR: run as root: sudo bash install.sh" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/apply-config.sh" && -f "$SCRIPT_DIR/generate-config.sh" && -f "$SCRIPT_DIR/lib.sh" && -f "$SCRIPT_DIR/server.env" && -f "$SCRIPT_DIR/backup.sh" ]] || {
  echo "ERROR: incomplete project directory or missing server.env template: $SCRIPT_DIR" >&2
  exit 1
}

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

case "$SCRIPT_DIR/" in
  "$PROJECT_DIR/"*)
    echo "ERROR: run install.sh from a separate staging directory, not inside the installation directory ($PROJECT_DIR)." >&2
    exit 1
    ;;
esac

# 中文说明：先加载仓库模板，并把模板值保存到 TEMPLATE_* 变量。
# 之后清除原变量，避免运行环境中的旧变量意外覆盖安装目标目录配置。
# 模板只提供默认值；真实 UUID、REALITY 密钥和订阅 Token 会在后续生成。
# shellcheck disable=SC1090
source "$SCRIPT_DIR/server.env"
TEMPLATE_PROTOCOL="${PROTOCOL:-vless-reality}"
TEMPLATE_SERVER_PORT="${SERVER_PORT:-${server_port:-18388}}"
TEMPLATE_SNI="${REALITY_SNI:-www.microsoft.com}"
TEMPLATE_HANDSHAKE="${REALITY_HANDSHAKE_SERVER:-$TEMPLATE_SNI}"
TEMPLATE_HANDSHAKE_PORT="${REALITY_HANDSHAKE_PORT:-443}"
TEMPLATE_NODE_NAME="${NODE_NAME:-US-Aliyun}"
TEMPLATE_PUBLIC_IP="${PUBLIC_IP:-}"
TEMPLATE_ENABLE_SUB="${ENABLE_SUBSCRIPTION:-true}"
TEMPLATE_TOKEN="${SUBSCRIBE_TOKEN:-}"
TEMPLATE_DOMAIN="${DOMAIN:-}"
TEMPLATE_ENABLE_UFW="${ENABLE_UFW:-true}"
TEMPLATE_SSH_PORT="${SSH_PORT:-22}"
TEMPLATE_NGINX_PORT="${NGINX_HTTP_PORT:-80}"

# 清除由模板加载的变量，确保运行目录的 server.env 能明确覆盖模板默认值。
unset PROTOCOL SERVER_PORT server_port VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
unset REALITY_SNI REALITY_HANDSHAKE_SERVER REALITY_HANDSHAKE_PORT NODE_NAME PUBLIC_IP
unset ENABLE_SUBSCRIPTION SUBSCRIBE_TOKEN DOMAIN ENABLE_HTTPS NGINX_HTTP_PORT ENABLE_UFW SSH_PORT

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
    # 仅恢复本项目管理的订阅目录。
    if [[ -f "$BACKUP_DIR/.had-public-dir" ]]; then
      rm -rf /var/www/my-vpn
      cp -a "$BACKUP_DIR/var-www-my-vpn" /var/www/my-vpn
    elif [[ -f /var/www/my-vpn/.myvpn-managed ]]; then
      rm -f /var/www/my-vpn/subscribe.txt /var/www/my-vpn/subscribe.txt.new /var/www/my-vpn/.myvpn-managed
      rmdir /var/www/my-vpn 2>/dev/null || true
    fi
    # 恢复完整的旧项目目录，包括旧脚本和运行配置。
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

# 在修改软件、服务配置、Nginx 或防火墙之前创建 root-only 备份。
BACKUP_DIR="$(MYVPN_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/backup.sh" --path-only)"
echo "Pre-install backup: $BACKUP_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq openssl nginx ufw qrencode iproute2

# REALITY 需要较新的 sing-box；未安装或版本低于 1.11.0 时才运行官方安装器。
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
# 不覆盖已有运行配置 server.env，也不复制 Git 元数据和已生成的客户端凭据。
tar --exclude=.git --exclude=server.env --exclude=client -cf - -C "$SCRIPT_DIR" . | tar -xf - -C "$PROJECT_DIR"
chmod 700 "$PROJECT_DIR"
install -d -m 700 "$PROJECT_DIR/client"
chmod +x "$PROJECT_DIR"/*.sh

# 中文说明：仓库模板提供默认值；已有安装目录的 server.env 优先。
# 读取运行配置前，确保模板变量已清空，避免把模板内容误认为已有运行凭据。
OLD_PUBLIC_IP="$TEMPLATE_PUBLIC_IP"
OLD_TOKEN="$TEMPLATE_TOKEN"
OLD_DOMAIN="$TEMPLATE_DOMAIN"
OLD_ENABLE_SUB="$TEMPLATE_ENABLE_SUB"
OLD_ENABLE_UFW="$TEMPLATE_ENABLE_UFW"
OLD_SSH_PORT="$TEMPLATE_SSH_PORT"
OLD_NGINX_PORT="$TEMPLATE_NGINX_PORT"
OLD_NODE_NAME="$TEMPLATE_NODE_NAME"
OLD_REALITY_UUID=""
OLD_REALITY_PRIVATE=""
OLD_REALITY_PUBLIC=""
OLD_REALITY_SHORT=""
OLD_SERVER_PORT="$TEMPLATE_SERVER_PORT"
OLD_SNI="$TEMPLATE_SNI"
OLD_HANDSHAKE="$TEMPLATE_HANDSHAKE"
OLD_HANDSHAKE_PORT="$TEMPLATE_HANDSHAKE_PORT"
OLD_PROTOCOL=""

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  OLD_PROTOCOL="${PROTOCOL:-}"
  OLD_PUBLIC_IP="${PUBLIC_IP:-$TEMPLATE_PUBLIC_IP}"
  OLD_TOKEN="${SUBSCRIBE_TOKEN:-$TEMPLATE_TOKEN}"
  OLD_DOMAIN="${DOMAIN:-$TEMPLATE_DOMAIN}"
  OLD_ENABLE_SUB="${ENABLE_SUBSCRIPTION:-$TEMPLATE_ENABLE_SUB}"
  OLD_ENABLE_UFW="${ENABLE_UFW:-$TEMPLATE_ENABLE_UFW}"
  OLD_SSH_PORT="${SSH_PORT:-$TEMPLATE_SSH_PORT}"
  OLD_NGINX_PORT="${NGINX_HTTP_PORT:-$TEMPLATE_NGINX_PORT}"
  OLD_NODE_NAME="${NODE_NAME:-$TEMPLATE_NODE_NAME}"
  OLD_REALITY_UUID="${VLESS_UUID:-}"
  OLD_REALITY_PRIVATE="${REALITY_PRIVATE_KEY:-}"
  OLD_REALITY_PUBLIC="${REALITY_PUBLIC_KEY:-}"
  OLD_REALITY_SHORT="${REALITY_SHORT_ID:-}"
  OLD_SNI="${REALITY_SNI:-$TEMPLATE_SNI}"
  OLD_HANDSHAKE="${REALITY_HANDSHAKE_SERVER:-${REALITY_SNI:-$TEMPLATE_HANDSHAKE}}"
  OLD_HANDSHAKE_PORT="${REALITY_HANDSHAKE_PORT:-$TEMPLATE_HANDSHAKE_PORT}"
  # VLESS 旧配置可以沿用端口；旧 Shadowsocks 端口不沿用，改用模板端口。
  if [[ "$OLD_PROTOCOL" == "vless-reality" ]]; then
    OLD_SERVER_PORT="${SERVER_PORT:-${server_port:-$TEMPLATE_SERVER_PORT}}"
  fi
fi

# 自动探测公网 IPv4；探测失败时仅回退到已保存且格式有效的公网地址。
PUBLIC_IP="$(myvpn_detect_public_ipv4 || true)"
if [[ -z "$PUBLIC_IP" ]] && myvpn_is_ipv4 "$OLD_PUBLIC_IP"; then
  PUBLIC_IP="$OLD_PUBLIC_IP"
  echo "WARNING: public IPv4 auto-detection failed; reusing saved PUBLIC_IP=$PUBLIC_IP." >&2
fi
myvpn_is_ipv4 "$PUBLIC_IP" || { echo "ERROR: could not detect a valid public IPv4 address. Check outbound HTTPS from the VPS and rerun install.sh." >&2; exit 1; }

VLESS_UUID="$OLD_REALITY_UUID"
REALITY_PRIVATE_KEY="$OLD_REALITY_PRIVATE"
REALITY_PUBLIC_KEY="$OLD_REALITY_PUBLIC"
REALITY_SHORT_ID="$OLD_REALITY_SHORT"
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$VLESS_UUID" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  keypair="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$keypair" | sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*([^[:space:]]+).*/\1/p' | head -n1)"
fi
if [[ -z "$VLESS_UUID" || -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
  echo "ERROR: failed to generate VLESS UUID / REALITY key pair. Check 'sing-box generate reality-keypair'." >&2
  exit 1
fi
if [[ "$OLD_PROTOCOL" != "vless-reality" || -z "$OLD_REALITY_SHORT" ]]; then
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
else
  REALITY_SHORT_ID="$OLD_REALITY_SHORT"
fi
SUBSCRIBE_TOKEN="$OLD_TOKEN"
[[ -n "$SUBSCRIBE_TOKEN" ]] || SUBSCRIBE_TOKEN="$(openssl rand -hex 24)"

# 旧配置中的 ENABLE_HTTPS 不会自动迁移：当前 Nginx 脚本只配置 HTTP，不自动申请证书。
if [[ "${ENABLE_HTTPS:-false}" == "true" ]]; then
  echo "NOTE: old ENABLE_HTTPS=true is not migrated: the Nginx script does not configure certificate/key paths. This deployment keeps HTTP subscription on port $OLD_NGINX_PORT; configure TLS separately before exposing subscription credentials." >&2
fi

# 写入安装目录的运行配置，并为每个参数保留中文解释。此文件含私钥，权限必须为 600。
TMP_ENV="$(mktemp "${PROJECT_DIR}/server.env.XXXXXX")"
{
  printf '# MyVPN 运行配置：由 install.sh 初始化；包含 REALITY 私钥，请勿公开分享。\n'
  printf '# 协议类型：当前脚本使用 vless-reality。\nPROTOCOL=%q\n' 'vless-reality'
  printf '# VLESS 服务端 TCP 监听端口；需同步放行云安全组和主机防火墙。\nSERVER_PORT=%q\n' "$OLD_SERVER_PORT"
  printf '# VLESS 客户端身份 UUID。\nVLESS_UUID=%q\n' "$VLESS_UUID"
  printf '# REALITY 服务端私钥，严禁公开。\nREALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
  printf '# REALITY 服务端公钥，用于生成客户端配置。\nREALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
  printf '# REALITY Short ID，需为偶数长度的十六进制字符串。\nREALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
  printf '# REALITY SNI 伪装域名。\nREALITY_SNI=%q\n' "$OLD_SNI"
  printf '# REALITY 握手目标服务器；当前配置要求与 SNI 一致。\nREALITY_HANDSHAKE_SERVER=%q\n' "$OLD_HANDSHAKE"
  printf '# REALITY 握手目标端口，不是本机代理监听端口。\nREALITY_HANDSHAKE_PORT=%q\n' "$OLD_HANDSHAKE_PORT"
  printf '# 客户端显示的节点名称。\nNODE_NAME=%q\n' "$OLD_NODE_NAME"
  printf '# VPS 公网 IPv4，由安装器探测并写入。\nPUBLIC_IP=%q\n' "$PUBLIC_IP"
  printf '# 是否开启 HTTP 订阅文件：true/false。\nENABLE_SUBSCRIPTION=%q\n' "$OLD_ENABLE_SUB"
  printf '# 订阅 URL 的随机 Token；并不加密订阅内容。\nSUBSCRIBE_TOKEN=%q\n' "$SUBSCRIBE_TOKEN"
  printf '# 可选订阅域名；为空时使用公网 IPv4。\nDOMAIN=%q\n' "$OLD_DOMAIN"
  printf '# 当前脚本暂不自动配置 HTTPS，因此固定为 false。\nENABLE_HTTPS=%q\n' 'false'
  printf '# Nginx HTTP 订阅端口。\nNGINX_HTTP_PORT=%q\n' "$OLD_NGINX_PORT"
  printf '# 是否由脚本管理 UFW 规则，不影响云厂商安全组。\nENABLE_UFW=%q\n' "$OLD_ENABLE_UFW"
  printf '# SSH 服务端口；仅用于 UFW 放行规则。\nSSH_PORT=%q\n' "$OLD_SSH_PORT"
} > "$TMP_ENV"
chmod 600 "$TMP_ENV"
mv -f "$TMP_ENV" "$ENV_FILE"

"$PROJECT_DIR/apply-config.sh"
"$PROJECT_DIR/generate-config.sh"
"$PROJECT_DIR/nginx-setup.sh"

if [[ "$OLD_ENABLE_UFW" == "true" ]]; then
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
echo "Client URI: ${PROJECT_DIR}/client/vless.txt"
echo "Subscription: use the URL printed by generate-config.sh"
echo "Remember: also allow TCP ${OLD_SERVER_PORT} and TCP ${OLD_NGINX_PORT} in the Alibaba Cloud security group."
