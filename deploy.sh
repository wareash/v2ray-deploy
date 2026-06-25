#!/usr/bin/env bash
#
# deploy.sh
# 一键部署 V2Ray (VMess + WebSocket + TLS)，使用真实静态网站伪装。
# 支持：交互式部署 / 域名与IP校验 / BBR 加速 / 多用户管理 / 卸载。
#
# 支持系统：Debian 10+ / Ubuntu 20.04+
#
# 用法：
#   sudo bash deploy.sh                # 进入交互菜单
#   sudo bash deploy.sh install        # 直接部署
#   sudo bash deploy.sh adduser [备注] # 添加用户
#   sudo bash deploy.sh deluser        # 删除用户
#   sudo bash deploy.sh users          # 查看所有用户及链接
#   sudo bash deploy.sh bbr            # 开启 BBR 加速
#   sudo bash deploy.sh uninstall      # 卸载

set -euo pipefail

# ---------- 终端颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;36m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[信息]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[警告]${PLAIN} $*"; }
error() { echo -e "${RED}[错误]${PLAIN} $*" >&2; }
ask()   { echo -ne "${BLUE}[输入]${PLAIN} $*"; }

# ---------- 路径与默认值 ----------
DOMAIN=""
EMAIL=""
V2RAY_PORT=36649
WS_PATH=""
UUID=""
CERT_DIR="/data"
CERT_FILE="${CERT_DIR}/v2ray.crt"
KEY_FILE="${CERT_DIR}/v2ray.key"
WEBROOT="/home/wwwroot/blog"
# 官方 v2fly 安装脚本默认配置路径；实际路径会通过 detect_v2ray_config_path() 从 systemd 探测
V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
NGINX_CONF="/etc/nginx/conf.d/v2ray.conf"
META_DIR="/usr/local/etc/v2ray-deploy"
META_FILE="${META_DIR}/deploy.conf"
ACME_HOME="${HOME}/.acme.sh"

# ---------- 基础检查 ----------
check_root() {
    [[ $EUID -eq 0 ]] || { error "请使用 root 权限运行（sudo bash deploy.sh）。"; exit 1; }
}
check_os() {
    command -v apt-get >/dev/null 2>&1 || { error "本脚本仅支持基于 apt 的系统（Debian / Ubuntu）。"; exit 1; }
}
need_jq() {
    command -v jq >/dev/null 2>&1 || { info "安装 jq ..."; apt-get update -y >/dev/null; apt-get install -y jq >/dev/null; }
}

# ---------- 元数据 持久化 / 读取 ----------
save_meta() {
    mkdir -p "$META_DIR"
    cat > "$META_FILE" <<EOF
DOMAIN="${DOMAIN}"
WS_PATH="${WS_PATH}"
V2RAY_PORT="${V2RAY_PORT}"
WEBROOT="${WEBROOT}"
EOF
}

# 读取元数据；若元数据缺失（如旧脚本部署），尝试从现有配置回退推断
load_meta() {
    if [[ -f "$META_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$META_FILE"
        return 0
    fi
    [[ -f "$V2RAY_CONFIG" ]] || return 1
    need_jq
    WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // empty' "$V2RAY_CONFIG" 2>/dev/null)
    V2RAY_PORT=$(jq -r '.inbounds[0].port // 36649' "$V2RAY_CONFIG" 2>/dev/null)
    if [[ -f "$NGINX_CONF" ]]; then
        DOMAIN=$(grep -m1 -E '^\s*server_name' "$NGINX_CONF" | awk '{print $2}' | tr -d ';')
    fi
    [[ -n "$DOMAIN" && -n "$WS_PATH" ]] || return 1
    save_meta
    return 0
}

require_installed() {
    detect_v2ray_config_path
    if [[ ! -f "$V2RAY_CONFIG" ]]; then
        error "未检测到已部署的 V2Ray，请先执行：sudo bash deploy.sh install"
        exit 1
    fi
    load_meta || { error "无法读取部署信息（缺少 ${META_FILE} 且无法从现有配置推断）。"; exit 1; }
}

# ---------- 依赖 ----------
install_deps() {
    info "更新软件源并安装依赖 ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl socat unzip git nginx dnsutils qrencode jq iproute2 ca-certificates >/dev/null
    info "依赖安装完成。"
}

# ---------- 公网 IP / 域名解析 ----------
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip" "https://4.ipw.cn"; do
        ip=$(curl -s4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}
resolve_domain() {
    local domain="$1" ip=""
    if command -v dig >/dev/null 2>&1; then
        ip=$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
        [[ -z "$ip" ]] && ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    fi
    [[ -z "$ip" ]] && command -v getent >/dev/null 2>&1 && ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    echo "$ip"
}

# ---------- 交互：域名输入与校验 ----------
input_and_verify_domain() {
    local server_ip
    if server_ip=$(get_public_ip); then
        info "检测到本机公网 IP：${GREEN}${server_ip}${PLAIN}"
    else
        warn "无法自动获取本机公网 IP，将跳过自动比对。"; server_ip=""
    fi

    while true; do
        ask "请输入已解析到本机的域名（例如 jp-cst2.dynip.org）："
        read -r DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
        [[ -z "$DOMAIN" ]] && { error "域名不能为空。"; continue; }
        if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            error "域名格式不正确：$DOMAIN"; continue
        fi

        info "正在解析 ${DOMAIN} 的 A 记录 ..."
        local domain_ip; domain_ip=$(resolve_domain "$DOMAIN")
        [[ -n "$domain_ip" ]] && info "域名解析结果：${GREEN}${domain_ip}${PLAIN}" || warn "未能解析到 ${DOMAIN} 的 A 记录。"

        if [[ -n "$server_ip" && -n "$domain_ip" ]]; then
            if [[ "$domain_ip" == "$server_ip" ]]; then
                info "校验通过：域名已正确指向本机 (${server_ip})。"; break
            else
                error "域名解析 IP (${domain_ip}) 与本机公网 IP (${server_ip}) 不一致！"
                warn  "请先把 ${DOMAIN} 的 A 记录指向 ${server_ip} 并等待生效。"
                ask "是否仍要强制继续？(y/N)："; read -r f
                [[ "${f,,}" == "y" ]] && { warn "已选择强制继续。"; break; }
            fi
        else
            ask "无法完成自动比对，确认域名已指向本机并继续？(y/N)："; read -r c
            [[ "${c,,}" == "y" ]] && break
        fi
    done

    ask "请输入用于申请证书的邮箱（回车默认 admin@${DOMAIN}）："
    read -r EMAIL; EMAIL=${EMAIL:-admin@${DOMAIN}}
}

# ---------- 安装 V2Ray ----------
install_v2ray() {
    if [[ -x /usr/local/bin/v2ray ]]; then info "已安装 V2Ray，跳过。"; return; fi
    info "安装 V2Ray（官方 v2fly 脚本）..."
    bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) >/dev/null
    info "V2Ray 安装完成。"
}

# 关键：V2Ray 实际读取的配置路径由 systemd 服务的 ExecStart 决定（官方脚本用
# /usr/local/etc/v2ray/config.json，部分定制安装用 /etc/v2ray/config.json）。
# 必须从服务定义动态探测，否则会出现“配置写对地方、服务读空配置”导致不监听端口的问题。
detect_v2ray_config_path() {
    local line cfg
    line=$(systemctl cat v2ray 2>/dev/null | grep -m1 '^ExecStart=')
    [[ -z "$line" && -f /etc/systemd/system/v2ray.service ]] && line=$(grep -m1 '^ExecStart=' /etc/systemd/system/v2ray.service)
    [[ -z "$line" ]] && return 0
    cfg=$(awk '{for(i=1;i<=NF;i++){
        if($i=="-c"||$i=="-config"){print $(i+1);exit}
        if($i ~ /^-config=/){s=$i;sub(/^-config=/,"",s);print s;exit}
        if($i ~ /^-c=/){s=$i;sub(/^-c=/,"",s);print s;exit}
    }}' <<<"$line")
    if [[ -n "$cfg" && "$cfg" == *.json ]]; then
        V2RAY_CONFIG="$cfg"
        info "检测到 V2Ray 实际配置路径：${V2RAY_CONFIG}"
    fi
}

gen_identifiers() {
    UUID=$(gen_uuid)
    WS_PATH="/$(head /dev/urandom | tr -dc 'a-f0-9' | head -c8)/"
    info "已生成 UUID：${UUID}"
    info "已生成 WebSocket 暗道路径：${WS_PATH}"
}
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
    else /usr/local/bin/v2ray uuid 2>/dev/null || head /dev/urandom | tr -dc 'a-f0-9' | head -c32; fi
}

# ---------- 证书 ----------
issue_cert() {
    mkdir -p "$CERT_DIR"
    [[ -f "${ACME_HOME}/acme.sh" ]] || { info "安装 acme.sh ..."; curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null; }
    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "${ACME_HOME}/acme.sh" --register-account -m "$EMAIL" >/dev/null 2>&1 || true
    info "通过 standalone 模式签发证书（临时占用 80 端口）..."
    systemctl stop nginx >/dev/null 2>&1 || true
    if ! "${ACME_HOME}/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 >/dev/null 2>&1; then
        error "证书签发失败。请确认 80 端口空闲、域名已解析、防火墙放行 80/443。"
        systemctl start nginx >/dev/null 2>&1 || true; exit 1
    fi
    "${ACME_HOME}/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" >/dev/null
    info "证书签发完成。"
}

# ---------- 伪装站 ----------
deploy_camouflage() {
    info "部署伪装站点到 ${WEBROOT} ..."
    mkdir -p "$WEBROOT"
    local tmp="/tmp/clean-blog-$$"
    if git clone --depth 1 https://github.com/StartBootstrap/startbootstrap-clean-blog.git "$tmp" >/dev/null 2>&1 && [[ -d "$tmp/dist" ]]; then
        cp -r "$tmp/dist/." "$WEBROOT/"
        curl -fsSL --max-time 20 -o "$WEBROOT/js/bootstrap.bundle.min.js" \
            https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js 2>/dev/null || true
        [[ -s "$WEBROOT/js/bootstrap.bundle.min.js" ]] && \
            sed -i 's#https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js#js/bootstrap.bundle.min.js#g' "$WEBROOT"/*.html
        rm -rf "$tmp"; info "伪装博客部署完成。"
    else
        warn "拉取模板失败，写入占位页面。"
        cat > "$WEBROOT/index.html" <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>DevNotes</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:720px;margin:60px auto;padding:0 20px;color:#222;line-height:1.7}</style>
</head><body><h1>DevNotes</h1><p>Notes on software, systems and the web.</p><hr>
<h2>A reproducible dev environment with Docker Compose</h2><p><small>May 28, 2026</small></p>
<p>Stop saying "works on my machine" — pin everything.</p></body></html>
HTML
    fi
}

# ---------- 写 V2Ray 配置（初始单用户，email=admin）----------
write_v2ray_config() {
    info "写入 V2Ray 配置 ${V2RAY_CONFIG} ..."
    mkdir -p "$(dirname "$V2RAY_CONFIG")" /var/log/v2ray
    cat > "$V2RAY_CONFIG" <<EOF
{
  "log": { "access": "/var/log/v2ray/access.log", "error": "/var/log/v2ray/error.log", "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${V2RAY_PORT},
      "listen": "127.0.0.1",
      "tag": "vmess-in",
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "${UUID}", "alterId": 0, "email": "admin" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "blackhole", "settings": {}, "tag": "blocked" }
  ],
  "routing": { "domainStrategy": "AsIs", "rules": [ { "type": "field", "inboundTag": ["vmess-in"], "outboundTag": "direct" } ] }
}
EOF
}

# ---------- 写 Nginx 配置 ----------
write_nginx_config() {
    info "写入 Nginx 配置 ${NGINX_CONF} ..."
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

# ---------- 证书续期 ----------
setup_renew() {
    info "配置证书自动续期 ..."
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
    ( crontab -l 2>/dev/null | grep -v 'ssl_update.sh'; echo "0 3 * * 0 bash /usr/bin/ssl_update.sh" ) | crontab -
}

# ---------- BBR 加速 ----------
enable_bbr() {
    info "开启 BBR 加速 ..."
    if lsmod | grep -q '^tcp_bbr' || sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        :
    fi
    modprobe tcp_bbr 2>/dev/null || true
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$cc" == "bbr" ]]; then
        info "BBR 已开启（拥塞控制：${cc}，队列：${qd}）。"
    else
        warn "未能确认 BBR 已生效（当前：${cc}）。可能内核过旧（需 4.9+），重启后再试。"
    fi
}

# ---------- 生成客户端链接 ----------
# 用法：build_vmess_link <uuid> <ps备注>
build_vmess_link() {
    local uuid="$1" ps="$2"
    local json
    json=$(cat <<EOF
{"v":"2","ps":"${ps}","add":"${DOMAIN}","port":"443","id":"${uuid}","aid":"0","net":"ws","type":"none","host":"${DOMAIN}","path":"${WS_PATH}","tls":"tls"}
EOF
)
    echo "vmess://$(echo -n "$json" | base64 -w0)"
}

print_user_link() {
    local uuid="$1" name="$2"
    local ps="${name}_${DOMAIN}"
    local link; link=$(build_vmess_link "$uuid" "$ps")
    echo
    echo -e "${GREEN}用户：${name}${PLAIN}  UUID：${uuid}"
    echo -e "${BLUE}vmess:// 链接：${PLAIN}"
    echo "$link"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE}二维码：${PLAIN}"
        qrencode -t ANSIUTF8 "$link"
    fi
}

# ---------- 启动 ----------
start_services() {
    info "校验并启动服务 ..."
    /usr/local/bin/v2ray test -c "$V2RAY_CONFIG" >/dev/null
    nginx -t >/dev/null
    systemctl enable v2ray >/dev/null 2>&1 || true; systemctl restart v2ray
    systemctl enable nginx >/dev/null 2>&1 || true; systemctl restart nginx
    verify_listening
}

# 启动后健康检查：确认 V2Ray 真的监听了端口（避免“服务 active 却没监听”导致的 502）
verify_listening() {
    sleep 2
    local ok=""
    for _ in 1 2 3 4 5; do
        if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${V2RAY_PORT}\b"; then ok=1; break; fi
        sleep 1
    done
    if [[ -n "$ok" ]]; then
        info "健康检查通过：V2Ray 正在监听 127.0.0.1:${V2RAY_PORT}。"
    else
        error "健康检查失败：V2Ray 未监听 127.0.0.1:${V2RAY_PORT}！"
        error "服务实际读取的配置：$(systemctl cat v2ray 2>/dev/null | grep -m1 '^ExecStart=')"
        error "本脚本写入的配置：${V2RAY_CONFIG}"
        warn  "请检查二者是否一致，以及 V2Ray 日志：journalctl -u v2ray -n 30 --no-pager"
        exit 1
    fi
}

restart_v2ray() {
    /usr/local/bin/v2ray test -c "$V2RAY_CONFIG" >/dev/null
    systemctl restart v2ray
    verify_listening
}

# ====================== 子命令 ======================

do_install() {
    check_root; check_os
    install_deps
    input_and_verify_domain
    install_v2ray
    detect_v2ray_config_path
    gen_identifiers
    issue_cert
    deploy_camouflage
    write_v2ray_config
    write_nginx_config
    setup_renew
    save_meta
    ask "是否同时开启 BBR 加速？(Y/n)："; read -r b
    [[ "${b,,}" != "n" ]] && enable_bbr
    start_services
    echo
    echo -e "${GREEN}=================== 部署完成 ===================${PLAIN}"
    echo -e " 伪装网站  : https://${DOMAIN}/"
    echo -e " 协议      : VMess + WebSocket + TLS"
    echo -e " 路径(path): ${WS_PATH}"
    print_user_link "$UUID" "admin"
    echo -e "${GREEN}===============================================${PLAIN}"
}

# 添加用户：adduser [备注]
do_adduser() {
    check_root; require_installed; need_jq
    local name="${1:-}"
    if [[ -z "$name" ]]; then ask "请输入新用户备注名（如 alice）："; read -r name; fi
    name=$(echo "$name" | tr -d '[:space:]'); name=${name:-user$RANDOM}
    if jq -e --arg n "$name" '.inbounds[0].settings.clients[]|select(.email==$n)' "$V2RAY_CONFIG" >/dev/null 2>&1; then
        error "用户备注 '${name}' 已存在，请换一个。"; exit 1
    fi
    local uuid; uuid=$(gen_uuid)
    local tmp; tmp=$(mktemp)
    jq --arg id "$uuid" --arg n "$name" \
        '.inbounds[0].settings.clients += [{"id":$id,"alterId":0,"email":$n}]' \
        "$V2RAY_CONFIG" > "$tmp" && mv "$tmp" "$V2RAY_CONFIG"
    restart_v2ray
    info "已添加用户：${name}"
    print_user_link "$uuid" "$name"
}

# 删除用户
do_deluser() {
    check_root; require_installed; need_jq
    mapfile -t users < <(jq -r '.inbounds[0].settings.clients[] | "\(.email // "(无备注)")\t\(.id)"' "$V2RAY_CONFIG")
    local total=${#users[@]}
    if [[ $total -le 1 ]]; then error "当前仅剩 ${total} 个用户，不允许删除最后一个用户。"; exit 1; fi
    echo "当前用户列表："
    local i=1
    for u in "${users[@]}"; do echo "  $i) ${u}"; i=$((i+1)); done
    ask "请输入要删除的用户序号："; read -r idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > total )); then error "序号无效。"; exit 1; fi
    local jq_idx=$((idx-1))
    local name; name=$(echo "${users[$jq_idx]}" | cut -f1)
    local tmp; tmp=$(mktemp)
    jq "del(.inbounds[0].settings.clients[$jq_idx])" "$V2RAY_CONFIG" > "$tmp" && mv "$tmp" "$V2RAY_CONFIG"
    restart_v2ray
    info "已删除用户：${name}"
}

# 查看所有用户及链接
do_users() {
    check_root; require_installed; need_jq
    local count; count=$(jq '.inbounds[0].settings.clients | length' "$V2RAY_CONFIG")
    info "共 ${count} 个用户（域名：${DOMAIN}，路径：${WS_PATH}）："
    local n
    while IFS=$'\t' read -r name id; do
        [[ -z "$id" ]] && continue
        n=${name:-user}
        print_user_link "$id" "$n"
    done < <(jq -r '.inbounds[0].settings.clients[] | "\(.email // "user")\t\(.id)"' "$V2RAY_CONFIG")
}

do_bbr() { check_root; enable_bbr; }

# 卸载
do_uninstall() {
    check_root
    warn "即将卸载 V2Ray 及相关配置。"
    ask "确认卸载？(y/N)："; read -r c
    [[ "${c,,}" == "y" ]] || { info "已取消。"; exit 0; }

    info "停止并卸载 V2Ray ..."
    systemctl stop v2ray >/dev/null 2>&1 || true
    bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove >/dev/null 2>&1 || true
    rm -rf /etc/v2ray /usr/local/etc/v2ray /var/log/v2ray 2>/dev/null || true

    info "移除 Nginx 站点配置 ..."
    rm -f "$NGINX_CONF" 2>/dev/null || true
    systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true

    info "移除证书续期任务 ..."
    crontab -l 2>/dev/null | grep -v 'ssl_update.sh' | crontab - 2>/dev/null || true
    rm -f /usr/bin/ssl_update.sh 2>/dev/null || true

    ask "是否删除证书 ${CERT_DIR} 与 acme.sh 记录？(y/N)："; read -r dc
    if [[ "${dc,,}" == "y" ]]; then
        load_meta 2>/dev/null || true
        [[ -n "${DOMAIN:-}" && -f "${ACME_HOME}/acme.sh" ]] && "${ACME_HOME}/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
        rm -f "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
    fi
    ask "是否删除伪装站点目录 ${WEBROOT}？(y/N)："; read -r dw
    [[ "${dw,,}" == "y" ]] && rm -rf "$WEBROOT" 2>/dev/null || true

    rm -rf "$META_DIR" 2>/dev/null || true
    info "卸载完成。Nginx 软件包与 BBR 设置保留（如需关闭 BBR 请手动删除 /etc/sysctl.d/99-bbr.conf）。"
}

# ---------- 交互菜单 ----------
menu() {
    check_root
    echo -e "${GREEN}========= V2Ray 部署管理脚本 =========${PLAIN}"
    echo " 1) 安装 / 部署"
    echo " 2) 添加用户"
    echo " 3) 删除用户"
    echo " 4) 查看所有用户及链接"
    echo " 5) 开启 BBR 加速"
    echo " 6) 卸载"
    echo " 0) 退出"
    echo -e "${GREEN}=====================================${PLAIN}"
    ask "请选择操作 [0-6]："; read -r opt
    case "$opt" in
        1) do_install ;;
        2) do_adduser ;;
        3) do_deluser ;;
        4) do_users ;;
        5) do_bbr ;;
        6) do_uninstall ;;
        0) exit 0 ;;
        *) error "无效选项。"; exit 1 ;;
    esac
}

# ---------- 入口 ----------
main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        install)        do_install ;;
        adduser)        shift || true; do_adduser "${1:-}" ;;
        deluser)        do_deluser ;;
        users|list)     do_users ;;
        bbr)            do_bbr ;;
        uninstall)      do_uninstall ;;
        menu|"")        menu ;;
        -h|--help|help) sed -n '2,20p' "$0" ;;
        *) error "未知命令：$cmd"; sed -n '12,20p' "$0"; exit 1 ;;
    esac
}

main "$@"
