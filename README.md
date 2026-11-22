# MyVPN：VLESS + REALITY + Hysteria2

适用 Ubuntu 24.04，服务端使用 sing-box，客户端输出包括 Shadowrocket 的 VLESS 链接、Base64 订阅、sing-box JSON 和 **Mihomo / Clash.Meta YAML**。

## 目录规则

除首次安装脚本外，脚本会自动把**脚本所在目录**识别为项目目录，不再依赖目录必须叫 `/opt/myvpn-production`。你可以把已安装的项目目录改名或移动，随后从新目录执行脚本即可。客户端文件统一生成在项目目录下的 `client/`。

首次安装默认安装到 `/opt/myvpn-production`。如需自定义安装目录，先进入解压后的暂存目录，然后指定目标目录：

```bash
sudo MYVPN_INSTALL_DIR=/opt/myvpn-production-prod bash ./install.sh
```

安装脚本需要从**独立暂存目录**运行，不要从目标安装目录内部运行。若移动/改名项目目录，`server.env`、`client/` 和脚本应一起移动；系统服务配置仍位于 `/etc/sing-box/`，Nginx 订阅站点仍使用 `/var/www/my-vpn/`。

## 每个脚本的用途

| 脚本 | 用途 / 使用方式 |
|---|---|
| `install.sh` | 首次安装或迁移到 VLESS + REALITY；自动备份、安装依赖、生成服务端配置和客户端文件。需 root；默认目标 `/opt/myvpn-production`，可用 `MYVPN_INSTALL_DIR` 自定义。 |
| `lib.sh` | 公共函数库，供安装和生成脚本调用；不需要手动执行。包含公网 IPv4 探测、地址校验和安全更新 `server.env` 的函数。 |
| `backup.sh` | 备份项目目录、sing-box 配置、Nginx 站点和网络规则快照。`sudo ./backup.sh`；仅输出备份路径可用 `sudo ./backup.sh --path-only`。 |
| `apply-config.sh` | 从当前目录的 `server.env` 生成并校验 `/etc/sing-box/config.json`，重启服务；失败时尝试回滚。`sudo ./apply-config.sh`。 |
| `generate-config.sh` | 自动刷新公网 IPv4，必要时补齐缺失的 UUID/REALITY 密钥并同步服务端配置，再生成 `client/vless.txt`、`client/subscribe.txt`、`client/sing-box.json`、`client/clash.yaml` 和可选二维码。`sudo ./generate-config.sh`。 |
| `nginx-setup.sh` | 配置/更新项目专用的 Nginx 订阅站点，校验后重载；不删除默认站点。`sudo ./nginx-setup.sh`。 |
| `firewall.sh` | 管理项目标记的 UFW 规则。查看用法：`sudo ./firewall.sh`；`ensure SSH端口 代理端口 HTTP订阅端口` 添加缺失规则，`remove` 移除所有带项目标记的规则，`rollback 文件` 回滚指定 journal。`remove` 会移除该项目标记的全部规则，请谨慎使用。 |
| `healthcheck.sh` | 检查 sing-box 配置、服务、自启动、监听端口及订阅 HTTP 状态。`sudo ./healthcheck.sh`。 |
| `status.sh` | 显示服务状态、端口和订阅地址。`sudo ./status.sh`。 |
| `restart.sh` | 重新应用 sing-box 配置、重启 Nginx 并执行健康检查。`./restart.sh`。 |
| `uninstall.sh` | 二次确认后备份并移除项目管理的服务配置、Nginx 站点、标记过的 UFW 规则和当前项目目录；不会卸载软件包。`sudo ./uninstall.sh`。 |

## 安装后常用操作

```bash
cd /opt/myvpn-production  # 如果自定义或改名了目录，改成实际路径
sudo ./status.sh
sudo ./healthcheck.sh
sudo ./generate-config.sh
```

服务端配置在 `server.env`。安装时和每次执行 `generate-config.sh` 时，脚本都会尝试自动获取 VPS 的公网 IPv4，并更新 `PUBLIC_IP`；如果外部探测服务不可用，会在已有地址有效时回退使用并给出警告。通常不需要手动填写 `PUBLIC_IP`。

如果 `VLESS_UUID` 为空，生成脚本会先尝试从现有 sing-box 配置恢复；无法恢复时才创建新的 UUID。缺失 REALITY 密钥时会生成完整密钥对，然后调用 `apply-config.sh` 同步服务端，避免客户端配置与服务端凭据不一致。

修改端口或 Reality 参数后执行：

```bash
sudo ./apply-config.sh
sudo ./generate-config.sh
sudo ./healthcheck.sh
```

更改代理端口前，先在阿里云安全组放行对应 TCP 端口；主机 UFW 与阿里云安全组相互独立。确认新端口工作后，再检查并手动清理不再使用的旧规则。


## 升级前备份与回退

### 1. 升级前创建备份

每次更新脚本、重新安装或调整服务端配置前，先在当前项目目录执行：

```bash
cd /opt/my-vpn  # 如果项目目录改过名，替换成实际路径
sudo ./backup.sh
```

如需保存备份路径，使用：

```bash
BACKUP_DIR="$(sudo ./backup.sh --path-only)"
echo "$BACKUP_DIR"
```

备份默认保存在 `/var/backups/my-vpn/YYYYMMDD-HHMMSS/`，目录权限仅允许 root 访问。备份内容包括：

- 当前项目目录完整副本，包含 `server.env`、脚本和 `client/`。
- `/etc/sing-box/config.json`。
- 项目管理的 Nginx 站点配置及订阅文件目录。
- UFW、iptables、nftables 规则快照，以及服务状态和监听端口诊断信息。

请记录本次备份目录。不要把备份目录上传到 GitHub 或公开分享，其中包含私钥和订阅凭据。

### 2. 安装过程失败时

`install.sh` 在修改系统配置前会自动调用 `backup.sh`。如果安装中途失败，退出处理函数会尝试恢复原项目目录、sing-box 配置、项目 Nginx 站点和订阅目录，并撤销本次安装新增且记录在 journal 中的 UFW 规则。

自动回退完成后，仍应检查：

```bash
sudo systemctl status sing-box --no-pager
sudo systemctl status nginx --no-pager
sudo ./healthcheck.sh
```

自动回退是尽力恢复，不代表所有系统状态都已恢复。

### 3. 安装成功后需要手动回退

如果升级已经成功，但新版本运行异常，可使用升级前的备份恢复。先确认备份目录和实际项目目录，再执行以下命令。**请把示例中的路径替换为本机实际值，不要直接照抄占位路径。**

```bash
sudo -i

# 改成当前项目实际安装目录
PROJECT_DIR="/opt/my-vpn"

# 改成升级前创建的备份目录
BACKUP_DIR="/var/backups/my-vpn/YYYYMMDD-HHMMSS"

test -d "$BACKUP_DIR/opt-my-vpn" || {
  echo "项目备份不存在，停止回退"
  exit 1
}

systemctl stop sing-box

# 保留当前故障版本，避免回退后无法排查
if [ -d "$PROJECT_DIR" ]; then
  mv "$PROJECT_DIR" "${PROJECT_DIR}.failed.$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$PROJECT_DIR"
cp -a "$BACKUP_DIR/opt-my-vpn/." "$PROJECT_DIR/"

# 恢复 sing-box 配置；如果备份前不存在该配置，则移除本次新增的项目配置
if [ -f "$BACKUP_DIR/.had-sing-box-config" ]; then
  install -d -m 700 /etc/sing-box
  cp -a "$BACKUP_DIR/etc-sing-box/config.json" /etc/sing-box/config.json
elif [ -f /etc/sing-box/config.json ] && grep -q 'myvpn-vless-reality-in' /etc/sing-box/config.json; then
  rm -f /etc/sing-box/config.json
fi

# 恢复项目管理的 Nginx 站点
if [ -f "$BACKUP_DIR/.had-nginx-available" ]; then
  cp -a "$BACKUP_DIR/etc-nginx-sites-available/my-vpn-subscription" /etc/nginx/sites-available/my-vpn-subscription
elif [ -f /etc/nginx/sites-available/my-vpn-subscription ] && grep -q 'managed-by-my-vpn' /etc/nginx/sites-available/my-vpn-subscription; then
  rm -f /etc/nginx/sites-available/my-vpn-subscription
fi

if [ -f "$BACKUP_DIR/.had-nginx-enabled" ]; then
  cp -a "$BACKUP_DIR/etc-nginx-sites-enabled/my-vpn-subscription" /etc/nginx/sites-enabled/my-vpn-subscription
elif [ -L /etc/nginx/sites-enabled/my-vpn-subscription ] && [ "$(readlink -f /etc/nginx/sites-enabled/my-vpn-subscription || true)" = "/etc/nginx/sites-available/my-vpn-subscription" ]; then
  rm -f /etc/nginx/sites-enabled/my-vpn-subscription
fi

# 恢复订阅文件目录
if [ -f "$BACKUP_DIR/.had-public-dir" ]; then
  rm -rf /var/www/my-vpn
  mkdir -p /var/www/my-vpn
  cp -a "$BACKUP_DIR/var-www-my-vpn/." /var/www/my-vpn/
elif [ -f /var/www/my-vpn/.myvpn-managed ]; then
  rm -f /var/www/my-vpn/subscribe.txt /var/www/my-vpn/subscribe.txt.new /var/www/my-vpn/.myvpn-managed
  rmdir /var/www/my-vpn 2>/dev/null || true
fi

# 校验并启动服务
nginx -t && systemctl reload nginx
systemctl enable sing-box
systemctl restart sing-box
"$PROJECT_DIR/healthcheck.sh"
```

如果恢复命令中途失败，不要继续删除故障版本目录；先检查报错和备份内容。

### 4. 回退范围与限制

- 上述流程恢复的是项目文件、运行配置、sing-box 配置、项目 Nginx 站点和订阅文件。
- `backup.sh` 保存的 UFW、iptables、nftables 内容是**诊断快照，不是自动恢复脚本**。不要直接用快照覆盖整台机器的防火墙规则，以免影响其他服务。
- 安装失败时，`install.sh` 会通过本次运行的 firewall journal 撤销本次新增的项目 UFW 规则；安装成功后的手动回退，需要根据实际规则谨慎处理。
- 云厂商安全组不由脚本管理，端口规则需要在云控制台单独检查和调整。
- 备份不包含系统软件包、sing-box 二进制文件、完整系统服务定义或整台 VPS 镜像。如果系统软件或系统环境本身损坏，应使用 VPS 快照或云盘快照恢复。
- `uninstall.sh` 会先自动备份再删除项目管理的配置和项目目录；卸载后仍可按本节恢复，但需要先重新准备必要的软件和服务环境。


## 客户端文件

- `client/vless.txt`：复制整条 `vless://` 链接导入 Shadowrocket。
- `client/subscribe.txt`：Base64 编码的 VLESS 订阅内容。
- `client/sing-box.json`：sing-box 客户端配置。
- `client/clash.yaml`：兼容 **Mihomo / Clash.Meta** 的配置，支持 VLESS + REALITY；不保证旧版 Clash 内核兼容。

生成的客户端文件含认证信息，请勿公开分享。`server.env` 含 REALITY 私钥和 HY2 密码，同样需要保密。

## Hysteria2 使用说明

HY2 默认启用 UDP 2096。`generate-config.sh` 会自动生成密码和自签 TLS 证书，并输出 `client/hy2.txt`、`client/hy2-sing-box.json`；`client/clash.yaml` 同时包含 VLESS + REALITY 与 HY2。

### Clash.Meta / Mihomo

1. 使用支持 Hysteria2 的 Mihomo / Clash.Meta 内核。
2. 导入 `client/clash.yaml`。
3. 在 `PROXY` 策略组中选择 HY2 节点。

### Shadowrocket（小火箭）

1. 确认客户端版本支持 Hysteria2。
2. 复制 `client/hy2.txt` 中的完整 URI。
3. 在 Shadowrocket 中从剪贴板导入节点。

这里的 SS 指 Shadowrocket 客户端简称，不是 Shadowsocks 协议。HY2 URI 不能导入仅支持 Shadowsocks 的客户端。

### sing-box

1. 将 `client/hy2-sing-box.json` 传输到设备。
2. 在 sing-box 中导入配置并启动 VPN。

### 网络放行

云厂商安全组必须额外放行 **UDP 2096 入方向**。安装器会在 UFW 已启用时管理 UDP 规则，但不会修改云安全组。

修改 `HY2_ENABLED` 或 `HY2_PORT` 后，执行 `sudo ./generate-config.sh`。关闭 HY2 不影响 VLESS。

## 首次安装与目录改名提醒

- 请运行安装目录中的 `install.sh` 完成首次安装，不要把 `server.env.example` 直接复制成运行配置后只执行生成脚本。生成脚本能修复空凭据，但运行环境仍需先安装 `sing-box`、`jq` 等依赖。
- 自动获取公网 IPv4 需要 VPS 可以访问外部 HTTPS 地址。如果探测失败且 `server.env` 也没有有效的已保存地址，脚本会明确报错，不会生成带空 IP 的客户端文件。
- `generate-config.sh` 会在必要时应用服务端配置并可能重启 sing-box；如果此前缺失的是服务器正在使用的 UUID/密钥，恢复/初始化后旧客户端凭据可能失效，需要重新导入新生成的客户端文件。

## 重要限制

1. VLESS + REALITY 不能保证规避所有网络干扰；若链路本身丢包或被上游过滤，重新安装并不能保证解决。
2. 阿里云安全组需要手动放行代理端口、订阅 HTTP 端口以及 SSH 端口。脚本不会修改云安全组。
3. 默认订阅使用 HTTP；随机订阅 Token 不能加密订阅内容。不要在不可信网络中公开订阅地址，需 HTTPS 时应先配置域名和有效证书。
4. 脚本不会自动删除没有 `myvpn-managed` 标记的旧 UFW 规则，避免误删其他服务的规则。
