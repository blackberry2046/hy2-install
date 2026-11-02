# Hysteria2 一键安装脚本

官方 Hysteria2 的定版配方一键部署：交互式绑定域名、自动签发真证书、装完直接打印客户端导入链接。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blackberry2046/hy2-install/main/hy2-install.sh)
```

自动化部署：支持参数预先用环境变量传入。

```bash
DOMAIN=node.example.com CERT_MODE=standalone bash <(curl -fsSL https://raw.githubusercontent.com/blackberry2046/hy2-install/main/hy2-install.sh)
```

## 它会做什么

- 引导你添加 A 记录并当场验证解析（Cloudflare 须关代理/灰云，橙云不转发 UDP）
- 安装官方 Hysteria v2.13.0 二进制（x86_64 / arm64 自动识别），systemd 服务以低权限用户 `hysteria` 运行
- 本地随机生成两组密码：salamander 混淆密码与登录密码分开，存 `/opt/hy2/passwords.txt`（600）
- 配置：UDP 443、masquerade 代理 bing（rewriteHost）、congestion bbr standard、ignoreClientBandwidth、QUIC 保活参数
- acme.sh 签发真证书并设好自动续期（续期自动修私钥权限并重启服务）：
  - `dns_cf`：Cloudflare DNS-01 签 Let's Encrypt，需要一个只授权目标 zone 的 API Token
  - `standalone`：HTTP 80 口验证，机器上不留任何 DNS 凭证（适合与他人共用的机器）；填了邮箱签 ZeroSSL，跳过邮箱自动签 Let's Encrypt
- 不改任何内核参数（HY2 用自带 BBR；内核 BBR 对 UDP 无效）
- 结束时在终端打印 `hysteria2://` 导入链接（v2rayN / sing-box）和 Clash / mihomo 配置行

## 参数

| 变量 | 说明 |
|---|---|
| `DOMAIN` | 节点域名（交互模式会引导输入并验证解析） |
| `CERT_MODE` | `dns_cf` 或 `standalone` |
| `CF_Token` | 仅 `dns_cf` 需要 |
| `NODE_NAME` | 客户端显示名，默认由子域名生成，如 `NODE-HY2` |
| `EMAIL` | acme.sh 账户邮箱（可跳过；填了 standalone 走 ZeroSSL，跳过走 Let's Encrypt） |
| `HY2_VERSION` | 默认 `2.13.0` |

## 注意

- 服务商面板若有防火墙，需另行放行 UDP 443（standalone 模式另需 TCP 80）
- 重复运行不会轮换已有密码；旧配置会先备份到 `/opt/hy2/`
- 验收标准：客户端实测通过，服务端 `active` 不算数
