#!/usr/bin/env bash
#
# v2ray-deploy.sh
# 一键部署 V2Ray (VMess + WebSocket + TLS) 并使用真实静态网站进行伪装。
#
# 特性：
#   - 交互式输入域名
#   - 自动检测本机公网 IP，并校验域名解析是否指向本机（不一致时给出警告并可选择中止）
#   - 通过 acme.sh 自动签发 Let's Encrypt 证书并配置每周自动续期
#   - Nginx 前置：普通访问展示伪装博客，仅暗道路径走 WebSocket 进入 V2Ray
#   - 自动生成 UUID、随机 WebSocket 路径，并输出 vmess:// 链接
#
# 支持系统：Debian 10+ / Ubuntu 20.04+
# 使用方法：sudo bash deploy.sh

set -euo pipefail

# ---------- 终端颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
error() { echo -e "${RED}[错误]${PLAIN} $*" >&2; }
ask()   { echo -ne "${BLUE}[输入]${PLAIN} $*"; }

# ---------- 全局变量 ----------
DOMAIN=""
EMAIL=""
V2RAY_PORT=36649                  # V2Ray 本地监听端口（仅 127.0.0.1）
WS_PATH=""                        # 暗道 WebSocket 路径，自动随机生成
UUID=""                           # VMess 用户 ID，自动生成
CERT_DIR="/data"                  # 证书存放目录
CERT_FILE="${CERT_DIR}/v2ray.crt"
KEY_FILE="${CERT_DIR}/v2ray.key"
WEBROOT="/home/wwwroot/blog"      # 伪装站点根目录
V2RAY_CONFIG="/etc/v2ray/config.json"
NGINX_CONF="/etc/nginx/conf.d/v2ray.conf"
QR_CONFIG="/usr/local/vmess_qr.json"
ACME_HOME="${HOME}/.acme.sh"

# ---------- 基础检查 ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行本脚本（sudo bash deploy.sh）。"
        exit 1
    fi
}

check_os() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error "本脚本仅支持基于 apt 的系统（Debian / Ubuntu）。"
        exit 1
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    info "更新软件源并安装依赖（curl socat unzip git nginx dnsutils qrencode）..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl socat unzip git nginx dnsutils qrencode ca-certificates >/dev/null
    info "依赖安装完成。"
}

# ---------- 获取本机公网 IP ----------
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip" "https://4.ipw.cn"; do
        ip=$(curl -s4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# ---------- 解析域名 A 记录 ----------
resolve_domain() {
    local domain="$1" ip=""
    # 优先使用公共 DNS，避免本地 hosts/缓存干扰
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
        [[ -z "$ip" ]] && ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    fi
    if [[ -z "$ip" ]] && command -v getent >/dev/null 2>&1; then
        ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    echo "$ip"
}

# ---------- 交互：输入域名并校验解析 ----------
input_and_verify_domain() {
    local server_ip
    if ! server_ip=$(get_public_ip); then
        warn "无法自动获取本机公网 IP，将跳过自动比对（请自行确认域名已指向本机）。"
        server_ip=""
    else
        info "检测到本机公网 IP：${GREEN}${server_ip}${PLAIN}"
    fi

    while true; do
        ask "请输入已解析到本机的域名（例如 jp-cst2.dynip.org）："
        read -r DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')

        if [[ -z "$DOMAIN" ]]; then
            error "域名不能为空，请重新输入。"
            continue
        fi
        if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            error "域名格式不正确：$DOMAIN"
            continue
        fi

        info "正在解析域名 ${DOMAIN} 的 A 记录 ..."
        local domain_ip
        domain_ip=$(resolve_domain "$DOMAIN")

        if [[ -z "$domain_ip" ]]; then
            warn "未能解析到 ${DOMAIN} 的 A 记录（可能尚未生效或解析失败）。"
        else
            info "域名解析结果：${GREEN}${domain_ip}${PLAIN}"
        fi

        # 核心校验：域名解析 IP 是否与本机公网 IP 一致
        if [[ -n "$server_ip" && -n "$domain_ip" ]]; then
            if [[ "$domain_ip" == "$server_ip" ]]; then
                info "校验通过：域名已正确指向本机 (${server_ip})。"
                break
            else
                error "域名解析 IP (${domain_ip}) 与本机公网 IP (${server_ip}) 不一致！"
                warn  "请先在 DNS 服务商处把 ${DOMAIN} 的 A 记录指向 ${server_ip}，等待生效后再继续。"
                ask "是否仍要强制继续？(y/N)："
                read -r force
                [[ "${force,,}" == "y" ]] && { warn "已选择强制继续。"; break; }
                continue
            fi
        else
            # 无法完整比对时，让用户确认
            ask "无法完成自动比对，确认域名已指向本机并继续？(y/N)："
            read -r confirm
            [[ "${confirm,,}" == "y" ]] && break
        fi
    done

    ask "请输入用于申请证书的邮箱（直接回车则使用 admin@${DOMAIN}）："
    read -r EMAIL
    EMAIL=${EMAIL:-admin@${DOMAIN}}
}

# ---------- 安装 V2Ray ----------
install_v2ray() {
    if [[ -x /usr/local/bin/v2ray ]]; then
        info "检测到已安装 V2Ray，跳过安装。"
        return
    fi
    info "安装 V2Ray（官方 v2fly 安装脚本）..."
    bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) >/dev/null
    info "V2Ray 安装完成。"
}

# ---------- 生成 UUID 与随机路径 ----------
gen_identifiers() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
    else
        UUID=$(/usr/local/bin/v2ray uuid 2>/dev/null || cat /dev/urandom | tr -dc 'a-f0-9' | head -c32)
    fi
    WS_PATH="/$(head /dev/urandom | tr -dc 'a-f0-9' | head -c8)/"
    info "已生成 UUID：${UUID}"
    info "已生成 WebSocket 暗道路径：${WS_PATH}"
}

# ---------- 申请 TLS 证书 ----------
issue_cert() {
    mkdir -p "$CERT_DIR"
    if [[ ! -f "${ACME_HOME}/acme.sh" ]]; then
        info "安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
    fi
    info "设置默认 CA 为 Let's Encrypt ..."
    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "${ACME_HOME}/acme.sh" --register-account -m "$EMAIL" >/dev/null 2>&1 || true

    info "通过 standalone 模式签发证书（临时占用 80 端口）..."
    systemctl stop nginx >/dev/null 2>&1 || true
    if ! "${ACME_HOME}/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 >/dev/null 2>&1; then
        error "证书签发失败。请确认 80 端口未被占用、域名已正确解析、防火墙已放行 80/443。"
        systemctl start nginx >/dev/null 2>&1 || true
        exit 1
    fi
    info "安装证书到 ${CERT_DIR} ..."
    "${ACME_HOME}/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" \
        --key-file "$KEY_FILE" >/dev/null
    info "证书签发完成。"
}

# ---------- 部署伪装站点 ----------
deploy_camouflage() {
    info "部署伪装站点到 ${WEBROOT} ..."
    mkdir -p "$WEBROOT"
    local tmp="/tmp/clean-blog-$$"
    if git clone --depth 1 https://github.com/StartBootstrap/startbootstrap-clean-blog.git "$tmp" >/dev/null 2>&1 \
       && [[ -d "$tmp/dist" ]]; then
        cp -r "$tmp/dist/." "$WEBROOT/"
        # 本地化 Bootstrap JS，去除外部强依赖
        curl -fsSL --max-time 20 -o "$WEBROOT/js/bootstrap.bundle.min.js" \
            https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js 2>/dev/null || true
        if [[ -s "$WEBROOT/js/bootstrap.bundle.min.js" ]]; then
            sed -i 's#https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js#js/bootstrap.bundle.min.js#g' "$WEBROOT"/*.html
        fi
        rm -rf "$tmp"
        info "伪装博客模板部署完成。"
    else
        warn "拉取模板失败，写入一个简单的占位页面作为伪装站。"
        cat > "$WEBROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DevNotes</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:720px;margin:60px auto;padding:0 20px;color:#222;line-height:1.7}h1{font-weight:700}small{color:#888}</style>
</head><body>
<h1>DevNotes</h1>
<p>Notes on software, systems and the web.</p>
<hr>
<h2>A reproducible dev environment with Docker Compose</h2>
<p><small>Posted on May 28, 2026</small></p>
<p>Stop saying "works on my machine" — pin everything and commit your toolchain.</p>
<h2>Understanding TCP congestion control</h2>
<p><small>Posted on April 14, 2026</small></p>
<p>From Reno to BBR: how the internet decides how fast to send.</p>
</body></html>
HTML
    fi
}

# ---------- 写入 V2Ray 配置 ----------
write_v2ray_config() {
    info "写入 V2Ray 配置 ${V2RAY_CONFIG} ..."
    mkdir -p "$(dirname "$V2RAY_CONFIG")" /var/log/v2ray
    cat > "$V2RAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "listen": "127.0.0.1",
      "tag": "vmess-in",
      "protocol": "vmess",
      "settings": {
        "clients": [
          { "id": "${UUID}", "alterId": 0 }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "blackhole", "settings": {}, "tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["vmess-in"], "outboundTag": "direct" }
    ]
  }
}
EOF
}

# ---------- 写入 Nginx 配置 ----------
write_nginx_config() {
    info "写入 Nginx 配置 ${NGINX_CONF} ..."
    # 移除可能冲突的默认站点
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    mkdir -p "$(dirname "$NGINX_CONF")"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://${DOMAIN}\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate       ${CERT_FILE};
    ssl_certificate_key   ${KEY_FILE};
    ssl_protocols         TLSv1.2 TLSv1.3;
    ssl_ciphers           ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout   1d;
    ssl_session_cache     shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000";

    root  ${WEBROOT};
    index index.html index.htm;

    location ${WS_PATH} {
        proxy_redirect off;
        proxy_read_timeout 1200s;
        proxy_pass http://127.0.0.1:${V2RAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
    }
}
EOF
}

# ---------- 配置证书自动续期 ----------
setup_renew() {
    info "配置证书自动续期脚本 ..."
    cat > /usr/bin/ssl_update.sh <<EOF
#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH
systemctl stop nginx >/dev/null 2>&1
sleep 1
"${ACME_HOME}/acme.sh" --cron --home "${ACME_HOME}" >/dev/null 2>&1
"${ACME_HOME}/acme.sh" --install-cert -d "${DOMAIN}" --ecc --fullchain-file "${CERT_FILE}" --key-file "${KEY_FILE}" >/dev/null 2>&1
sleep 1
systemctl start nginx >/dev/null 2>&1
EOF
    chmod +x /usr/bin/ssl_update.sh
    # 每周日 03:00 续期
    ( crontab -l 2>/dev/null | grep -v 'ssl_update.sh'; echo "0 3 * * 0 bash /usr/bin/ssl_update.sh" ) | crontab -
}

# ---------- 生成客户端配置与链接 ----------
generate_client() {
    cat > "$QR_CONFIG" <<EOF
{
  "v": "2",
  "ps": "v2ray_${DOMAIN}",
  "add": "${DOMAIN}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "${WS_PATH}",
  "tls": "tls"
}
EOF
    VMESS_LINK="vmess://$(base64 -w0 "$QR_CONFIG")"
}

# ---------- 启动服务 ----------
start_services() {
    info "校验并启动服务 ..."
    /usr/local/bin/v2ray test -c "$V2RAY_CONFIG" >/dev/null
    nginx -t >/dev/null
    systemctl enable v2ray >/dev/null 2>&1 || true
    systemctl restart v2ray
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
}

# ---------- 输出结果 ----------
print_result() {
    echo
    echo -e "${GREEN}=================== 部署完成 ===================${PLAIN}"
    echo -e " 伪装网站  : https://${DOMAIN}/"
    echo -e " 协议      : VMess + WebSocket + TLS"
    echo -e " 地址(add) : ${DOMAIN}"
    echo -e " 端口(port): 443"
    echo -e " UUID(id)  : ${UUID}"
    echo -e " alterId   : 0"
    echo -e " 传输(net) : ws"
    echo -e " 路径(path): ${WS_PATH}"
    echo -e " Host/SNI  : ${DOMAIN}"
    echo -e " TLS       : 开启"
    echo
    echo -e "${BLUE}vmess:// 链接（复制到客户端导入）：${PLAIN}"
    echo "${VMESS_LINK}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE}二维码（手机扫码导入）：${PLAIN}"
        qrencode -t ANSIUTF8 "${VMESS_LINK}"
    fi
    echo -e "${GREEN}===============================================${PLAIN}"
}

main() {
    check_root
    check_os
    install_deps
    input_and_verify_domain
    install_v2ray
    gen_identifiers
    issue_cert
    deploy_camouflage
    write_v2ray_config
    write_nginx_config
    setup_renew
    generate_client
    start_services
    print_result
}

main "$@"
