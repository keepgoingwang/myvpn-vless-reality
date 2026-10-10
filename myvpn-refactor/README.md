# MyVPN：VLESS + REALITY

适用 Ubuntu 24.04，服务端使用 sing-box，客户端输出包括 Shadowrocket 的 VLESS 链接、Base64 订阅、sing-box JSON 和 **Mihomo / Clash.Meta YAML**。

## 目录规则

除首次安装脚本外，脚本会自动把**脚本所在目录**识别为项目目录，不再依赖目录必须叫 `/opt/my-vpn`。你可以把已安装的项目目录改名或移动，随后从新目录执行脚本即可。客户端文件统一生成在项目目录下的 `client/`。

首次安装默认安装到 `/opt/my-vpn`。如需自定义安装目录，先进入解压后的暂存目录，然后指定目标目录：

```bash
sudo MYVPN_INSTALL_DIR=/opt/my-vpn-prod bash ./install.sh
```

安装脚本需要从**独立暂存目录**运行，不要从目标安装目录内部运行。若移动/改名项目目录，`server.env`、`client/` 和脚本应一起移动；系统服务配置仍位于 `/etc/sing-box/`，Nginx 订阅站点仍使用 `/var/www/my-vpn/`。

## 每个脚本的用途

| 脚本 | 用途 / 使用方式 |
|---|---|
| `install.sh` | 首次安装或迁移到 VLESS + REALITY；自动备份、安装依赖、生成服务端配置和客户端文件。需 root；默认目标 `/opt/my-vpn`，可用 `MYVPN_INSTALL_DIR` 自定义。 |
| `backup.sh` | 备份项目目录、sing-box 配置、Nginx 站点和网络规则快照。`sudo ./backup.sh`；仅输出备份路径可用 `sudo ./backup.sh --path-only`。 |
| `apply-config.sh` | 从当前目录的 `server.env` 生成并校验 `/etc/sing-box/config.json`，重启服务；失败时尝试回滚。`sudo ./apply-config.sh`。 |
| `generate-config.sh` | 更新 `client/vless.txt`、`client/subscribe.txt`、`client/sing-box.json`、`client/clash.yaml`，并按配置更新 HTTP 订阅文件。`sudo ./generate-config.sh`。 |
| `nginx-setup.sh` | 配置/更新项目专用的 Nginx 订阅站点，校验后重载；不删除默认站点。`sudo ./nginx-setup.sh`。 |
| `firewall.sh` | 管理项目标记的 UFW 规则。查看用法：`sudo ./firewall.sh`；`ensure SSH端口 代理端口 HTTP订阅端口` 添加缺失规则，`remove` 移除所有带项目标记的规则，`rollback 文件` 回滚指定 journal。`remove` 会移除该项目标记的全部规则，请谨慎使用。 |
| `healthcheck.sh` | 检查 sing-box 配置、服务、自启动、监听端口及订阅 HTTP 状态。`sudo ./healthcheck.sh`。 |
| `status.sh` | 显示服务状态、端口和订阅地址。`sudo ./status.sh`。 |
| `restart.sh` | 重新应用 sing-box 配置、重启 Nginx 并执行健康检查。`./restart.sh`。 |
| `uninstall.sh` | 二次确认后备份并移除项目管理的服务配置、Nginx 站点、标记过的 UFW 规则和当前项目目录；不会卸载软件包。`sudo ./uninstall.sh`。 |

## 安装后常用操作

```bash
cd /opt/my-vpn  # 如果自定义或改名了目录，改成实际路径
sudo ./status.sh
sudo ./healthcheck.sh
sudo ./generate-config.sh
```

服务端配置在 `server.env`，修改端口或 Reality 参数后执行：

```bash
sudo ./apply-config.sh
sudo ./generate-config.sh
sudo ./healthcheck.sh
```

更改代理端口前，先在阿里云安全组放行对应 TCP 端口；主机 UFW 与阿里云安全组相互独立。确认新端口工作后，再检查并手动清理不再使用的旧规则。

## 客户端文件

- `client/vless.txt`：复制整条 `vless://` 链接导入 Shadowrocket。
- `client/subscribe.txt`：Base64 编码的 VLESS 订阅内容。
- `client/sing-box.json`：sing-box 客户端配置。
- `client/clash.yaml`：兼容 **Mihomo / Clash.Meta** 的配置，支持 VLESS + REALITY；不保证旧版 Clash 内核兼容。

生成的客户端文件含认证信息，请勿公开分享。`server.env` 含 REALITY 私钥，同样需要保密。

## 重要限制

1. VLESS + REALITY 不能保证规避所有网络干扰；若链路本身丢包或被上游过滤，重新安装并不能保证解决。
2. 阿里云安全组需要手动放行代理端口、订阅 HTTP 端口以及 SSH 端口。脚本不会修改云安全组。
3. 默认订阅使用 HTTP；随机订阅 Token 不能加密订阅内容。不要在不可信网络中公开订阅地址，需 HTTPS 时应先配置域名和有效证书。
4. 脚本不会自动删除没有 `myvpn-managed` 标记的旧 UFW 规则，避免误删其他服务的规则。
