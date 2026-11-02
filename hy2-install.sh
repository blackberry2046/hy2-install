#!/usr/bin/env bash
# ============================================================
# Hysteria2 一键安装脚本
# ------------------------------------------------------------
# 配方要点（多台机器实测验收的定版配方）：
#   官方 Hysteria v2.13.0 二进制 / UDP 443
#   obfs = salamander（混淆密码与登录密码分开，服务器本地随机生成）
#   masquerade 代理 https://www.bing.com（rewriteHost）
#   congestion bbr standard / ignoreClientBandwidth true
#   quic maxIdleTimeout 30s / maxIncomingStreams 1024
#   真证书 acme.sh 自动续期，续期后自动修私钥权限并重启服务
#   不动内核参数（HY2 用自带 BBR，内核 BBR 对 UDP 无效，也避免波及同机其他服务）
#
# 用法（任选其一）：
#   1) 全交互：  bash hy2-install.sh           然后按提示一步步输入
#   2) 全参数：  DOMAIN=node.example.com CERT_MODE=dns_cf CF_Token=xxxx bash hy2-install.sh
#   3) 位置参数：bash hy2-install.sh node.example.com standalone
#
# 参数（环境变量或交互输入）：
#   DOMAIN     节点域名，须有一条直指本机的 A 记录（Cloudflare 用户须关代理/灰云）
#   CERT_MODE  dns_cf     = Cloudflare DNS-01 签 Let's Encrypt（需 CF_Token）
#              standalone = HTTP 80 口验证（机器上不留任何 DNS 凭证；签发方见 EMAIL）
#   CF_Token   仅 dns_cf 模式需要；用 Edit zone DNS 模板、只授权目标 zone
#   NODE_NAME  客户端里显示的节点名，默认由子域名生成（如 node → NODE-HY2）
#   EMAIL      acme.sh 账户邮箱（可跳过：填了 standalone 走 ZeroSSL 签发，
#              acme.sh 靠它自动换取 EAB 凭证并记在本机；跳过则 standalone 自动改走
#              Let's Encrypt，dns_cf 模式本来就是 Let's Encrypt）
#   HY2_VERSION 默认 2.13.0
#
# 产物：
#   /usr/local/bin/hysteria            二进制
#   /etc/hysteria/config.yaml          配置（640 root:hysteria）
#   /opt/hy2/tls/fullchain.pem / privkey.pem
#   /opt/hy2/passwords.txt             两组密码（600，只有这里有明文）
#   systemd 服务 hysteria-server（User=hysteria）
#   结尾打印 hysteria2:// 导入链接 + Clash/mihomo 配置行（终端本地输出）
# ============================================================
set -euo pipefail

VERSION="${HY2_VERSION:-2.13.0}"
PORT=443
DOMAIN="${DOMAIN:-${1:-}}"
CERT_MODE="${CERT_MODE:-${2:-}}"
EMAIL="${EMAIL:-}"
INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "✗ $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"
command -v curl >/dev/null || die "缺 curl，先装：apt-get update && apt-get install -y curl"

PUBIP="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBIP" ] || PUBIP="(没查到，请手动确认)"

# ---------- 第一步：域名绑定（对话式） ----------
if [ -z "$DOMAIN" ] && [ "$INTERACTIVE" = "1" ]; then
  echo "第一步：绑定域名"
  echo "  请先到你的 DNS 服务商处，为节点域名添加一条 A 记录："
  echo "    类型 A ｜ 主机记录 = 你想用的子域名 ｜ 记录值 = 本机公网 IP：${PUBIP}"
  echo "    若用 Cloudflare：代理状态必须关（灰云 / DNS only），橙云不转发 UDP，节点会连不通。"
  echo "  添加好后，在下面输入完整域名（解析生效可能要等几分钟）。"
  read -rp "节点域名（如 node.example.com）: " DOMAIN
fi
[ -n "$DOMAIN" ] || die "域名不能为空（交互运行或用 DOMAIN=... 传入）"

# 解析核验：不对就给修改指引，交互模式下循环等用户改完再复查
while :; do
  DIP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -n1 || true)"
  if [ -n "$DIP" ] && [ "$DIP" = "$PUBIP" ]; then
    grn "✓ ${DOMAIN} 已正确解析到本机（${PUBIP}）"
    break
  fi
  if [ "$INTERACTIVE" != "1" ]; then
    if [ "${CERT_MODE}" = "standalone" ]; then
      die "域名解析 ${DIP:-无} ≠ 本机公网 IP ${PUBIP}，standalone 验证必然失败。先把 A 记录直指本机再跑"
    fi
    red "⚠ 域名解析 ${DIP:-无} ≠ 本机公网 IP ${PUBIP}：节点多半连不通，确认 A 记录直指本机（Cloudflare 须灰云）"
    break
  fi
  red "✗ ${DOMAIN} 当前解析到 ${DIP:-（查不到）}，本机公网 IP 是 ${PUBIP}，对不上。"
  echo "  请去 DNS 服务商处确认：A 记录值 = ${PUBIP}，且代理/橙云已关。改完等一两分钟再复查。"
  read -rp "  [回车] 重新检测 ｜ [c] 不管了继续（standalone 模式不可）｜ [q] 退出: " _a
  case "$_a" in
    q|Q) die "已退出。改好解析后重新运行脚本即可" ;;
    c|C)
      [ "${CERT_MODE}" = "standalone" ] && die "standalone 靠域名验证证书，解析不对签不下来。先改好解析"
      red "  已按你的选择继续，但节点大概率连不通，装完请先修解析"
      break ;;
    *) continue ;;
  esac
done

# ---------- 其余参数 ----------
if [ -z "$CERT_MODE" ]; then
  echo "证书方式： 1) dns_cf（Cloudflare DNS 验证，Let's Encrypt）"
  echo "           2) standalone（HTTP 80 口验证，ZeroSSL，机器上不留 DNS 凭证）"
  read -rp "选择 [1/2，默认 1]: " _c
  case "$_c" in 2) CERT_MODE=standalone ;; *) CERT_MODE=dns_cf ;; esac
fi
case "$CERT_MODE" in dns_cf|standalone) ;; *) die "CERT_MODE 只能是 dns_cf 或 standalone" ;; esac

if [ "$CERT_MODE" = "dns_cf" ] && [ -z "${CF_Token:-}" ]; then
  read -rsp "粘贴 Cloudflare API Token（输入不回显）: " CF_Token; echo
fi
if [ "$CERT_MODE" = "dns_cf" ]; then
  # 防终端粘贴把不可见转义字符混进 token，先清洗再用
  CF_Token="$(printf '%s' "$CF_Token" | tr -cd 'A-Za-z0-9_-')"
  [ -n "$CF_Token" ] || die "CF_Token 清洗后为空，粘贴可能出了问题"
  export CF_Token
fi

if [ -z "$EMAIL" ] && [ "$INTERACTIVE" = "1" ]; then
  read -rp "acme.sh 账户邮箱（可回车跳过；填了 standalone 走 ZeroSSL，跳过则走 Let's Encrypt）: " EMAIL
fi
# standalone 的 CA 选择：有邮箱走 ZeroSSL（acme 靠邮箱自动换 EAB 凭证）；没邮箱自动改走
# Let's Encrypt——同为 80 口验证、同样不在机器上留 DNS 凭证，只是换个签发方。
CA_SERVER=""
if [ "$CERT_MODE" = "standalone" ]; then
  if [ -n "$EMAIL" ]; then
    CA_SERVER="zerossl"
  else
    CA_SERVER="letsencrypt"
    echo "→ 未填邮箱，standalone 改走 Let's Encrypt 签发（80 口验证不变）"
  fi
fi

_DEFAULT_NODE="$(printf '%s' "${DOMAIN%%.*}" | tr 'a-z' 'A-Z')-HY2"
if [ -z "${NODE_NAME:-}" ] && [ "$INTERACTIVE" = "1" ]; then
  read -rp "节点名（客户端里显示，回车用默认 ${_DEFAULT_NODE}）: " NODE_NAME
fi
NODE_NAME="${NODE_NAME:-$_DEFAULT_NODE}"

# ---------- 预检 ----------
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac

if ss -uln 2>/dev/null | grep -q ":${PORT} "; then
  die "UDP ${PORT} 已被占用（可能已有 HY2 在跑），先停掉旧的再运行"
fi
if [ "$CERT_MODE" = "standalone" ] && ss -tln 2>/dev/null | grep -q ":80 "; then
  die "TCP 80 已被占用，standalone 验证没法用 80 口；腾空 80 或改用 dns_cf"
fi

# ---------- 密码（重跑不轮换） ----------
install -d -m 755 /opt/hy2 /opt/hy2/tls /etc/hysteria
if [ -f /opt/hy2/passwords.txt ]; then
  AUTH_PW="$(grep '^AUTH=' /opt/hy2/passwords.txt | cut -d= -f2-)"
  OBFS_PW="$(grep '^OBFS=' /opt/hy2/passwords.txt | cut -d= -f2-)"
  echo "→ 沿用 /opt/hy2/passwords.txt 里已有的密码（不轮换）"
else
  AUTH_PW="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
  OBFS_PW="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
  printf 'AUTH=%s\nOBFS=%s\n' "$AUTH_PW" "$OBFS_PW" > /opt/hy2/passwords.txt
  chmod 600 /opt/hy2/passwords.txt
  echo "→ 已生成两组随机密码，存 /opt/hy2/passwords.txt"
fi

# ---------- 二进制 ----------
if [ ! -x /usr/local/bin/hysteria ] || ! /usr/local/bin/hysteria version 2>/dev/null | grep -q "v${VERSION}"; then
  echo "→ 下载官方 Hysteria v${VERSION}（linux-${ARCH}）"
  curl -fL --retry 3 -o /usr/local/bin/hysteria \
    "https://github.com/apernet/hysteria/releases/download/app/v${VERSION}/hysteria-linux-${ARCH}"
  chmod +x /usr/local/bin/hysteria
fi
/usr/local/bin/hysteria version | head -n 2

# ---------- 服务用户 ----------
id hysteria >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hysteria

# ---------- 配置 ----------
[ -f /etc/hysteria/config.yaml ] && cp /etc/hysteria/config.yaml "/opt/hy2/config.yaml.bak-$(date +%Y%m%d%H%M%S)"
cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

tls:
  cert: /opt/hy2/tls/fullchain.pem
  key: /opt/hy2/tls/privkey.pem

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PW}

auth:
  type: password
  password: ${AUTH_PW}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

ignoreClientBandwidth: true

congestion:
  type: bbr
  profile: standard

quic:
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
EOF
chown root:hysteria /etc/hysteria/config.yaml
chmod 640 /etc/hysteria/config.yaml

# ---------- systemd ----------
cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria Server
After=network.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ---------- 证书（acme.sh） ----------
if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
  echo "→ 安装 acme.sh"
  if [ -n "$EMAIL" ]; then
    curl -fsSL https://get.acme.sh | sh -s "email=${EMAIL}"
  else
    curl -fsSL https://get.acme.sh | sh
  fi
fi
ACME="$HOME/.acme.sh/acme.sh"

if [ "$CERT_MODE" = "dns_cf" ]; then
  "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  echo "→ DNS-01 签发 ${DOMAIN}（Let's Encrypt）"
  "$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
elif [ "$CA_SERVER" = "zerossl" ]; then
  "$ACME" --register-account -m "$EMAIL" --server zerossl >/dev/null 2>&1 || true
  echo "→ standalone 签发 ${DOMAIN}（ZeroSSL，80 口验证）"
  "$ACME" --issue --standalone --server zerossl -d "$DOMAIN" --keylength ec-256
else
  echo "→ standalone 签发 ${DOMAIN}（Let's Encrypt，80 口验证）"
  "$ACME" --issue --standalone --server letsencrypt -d "$DOMAIN" --keylength ec-256
fi

# reloadcmd 会写进 acme 配置：今后续期自动修私钥权限并重启服务
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file /opt/hy2/tls/fullchain.pem \
  --key-file /opt/hy2/tls/privkey.pem \
  --reloadcmd "chgrp hysteria /opt/hy2/tls/privkey.pem; chmod 640 /opt/hy2/tls/privkey.pem; systemctl restart hysteria-server"
chmod 644 /opt/hy2/tls/fullchain.pem
chgrp hysteria /opt/hy2/tls/privkey.pem; chmod 640 /opt/hy2/tls/privkey.pem

# ---------- 防火墙（只处理本机 ufw；云厂商面板的墙需另开 UDP 443） ----------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/udp" >/dev/null || true
  [ "$CERT_MODE" = "standalone" ] && ufw allow 80/tcp >/dev/null || true
  echo "→ ufw 已放行 ${PORT}/udp"
fi

# ---------- 启动与验收 ----------
systemctl enable --now hysteria-server
sleep 2
systemctl is-active --quiet hysteria-server || { journalctl -u hysteria-server -n 30 --no-pager; die "服务没起来，看上面的日志"; }
ss -ulnp 2>/dev/null | grep -q ":${PORT} " || die "服务在跑但 UDP ${PORT} 没监听，异常"

grn "✓ HY2 已上线：${NODE_NAME}（${DOMAIN}:${PORT}/udp）"
echo
echo "导入链接（v2rayN / sing-box 直接粘贴）："
echo "hysteria2://${AUTH_PW}@${DOMAIN}:${PORT}?obfs=salamander&obfs-password=${OBFS_PW}&sni=${DOMAIN}#${NODE_NAME}"
echo
echo "Clash / mihomo 配置行："
echo "- {name: ${NODE_NAME}, type: hysteria2, server: ${DOMAIN}, port: ${PORT}, password: ${AUTH_PW}, obfs: salamander, obfs-password: ${OBFS_PW}, sni: ${DOMAIN}, skip-cert-verify: false}"
echo
echo "提醒：① 服务商面板防火墙若存在，须另行放行 UDP ${PORT}；"
echo "      ② 验收标准只有一个——客户端实测通过，服务端 active 不算数。"
