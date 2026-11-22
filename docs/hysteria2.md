# Hysteria2 使用说明

## 默认参数

| 参数 | 值 |
|---|---|
| 监听 | 0.0.0.0:2096/udp |
| SNI | hy2.local |
| TLS | 自签证书 |
| 密码 | 安装时随机生成 |

密码保存在安装目录的 `server.env` 中。不要将该文件或生成的客户端配置提交到公开仓库。

## 生成客户端配置

```bash
cd /opt/myvpn-production
sudo ./generate-config.sh
```

输出：`client/hy2.txt`（URI）、`client/hy2-sing-box.json`（sing-box）、`client/clash.yaml`（VLESS + HY2 合并配置）。

## Clash.Meta / Mihomo

1. 使用支持 Hysteria2 的 Mihomo / Clash.Meta 内核。
2. 导入 `client/clash.yaml`。
3. 在 `PROXY` 策略组中选择以 `-HY2` 结尾的节点。
4. 开启系统代理或 TUN 模式测试。

旧版 Clash 内核不一定支持 Hysteria2。

## Shadowrocket（小火箭）

1. 确认客户端版本支持 Hysteria2。
2. 复制 `client/hy2.txt` 中完整的 `hysteria2://` URI。
3. 在 Shadowrocket 中从剪贴板导入节点。
4. 检查服务器地址、UDP 端口、密码和 SNI 后连接。

“SS”在这里指 Shadowrocket 客户端简称，不是 Shadowsocks 协议。HY2 URI 不能导入仅支持 Shadowsocks 的客户端。

## sing-box

1. 将 `client/hy2-sing-box.json` 传输到设备。
2. 在 sing-box 中导入配置并启动 VPN。
3. 自签证书配置启用跳过证书验证；换用受信任 CA 证书后应关闭 `insecure`。

## 防火墙

主机 UFW（手动放行时）：

```bash
sudo ufw allow 2096/udp
sudo ufw status
```

云安全组仍需单独添加入方向 UDP 2096 规则。UFW 不会修改云安全组。

## 开关

`server.env`：

```bash
HY2_ENABLED=true
HY2_PORT=2096
```

关闭 HY2 时设置 `HY2_ENABLED=false` 并执行 `sudo ./generate-config.sh`。VLESS + REALITY 不受影响。

## 检查

```bash
sudo sing-box check -c /etc/sing-box/config.json
sudo systemctl status sing-box --no-pager
sudo ss -lunp | grep ':2096'
```
