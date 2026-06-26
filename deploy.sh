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
#   sudo bash deploy.sh upgrade        # 升级配置：V2Ray核心/nginx配置/伪装站/证书/元数据（不含BBR）
#   sudo bash deploy.sh uninstall      # 卸载
#
# 说明：install / adduser / users 运行结束会生成 Anywhere(iOS/macOS 客户端) 一键导入
#       链接（anywhere://add-proxy?link=...），并把连接信息保存到“运行目录”下的
#       v2ray-<域名>-info.txt 文件中。注意 Anywhere 不支持 vmess，仅 vless 等可一键导入。

# 注意：刻意不使用 pipefail。配合 set -e 时，`cmd | grep -m1`/`| head` 会因下游提前
# 关闭管道使上游收到 SIGPIPE(退出码141)，被 pipefail+set -e 误判为致命错误。
set -eu

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
PROTOCOL="vmess"   # 本脚本部署为 vmess；管理旧/手动部署时会从配置自动探测（可能是 vless）
RUN_DIR="$(pwd)"   # 脚本被调用时的工作目录；运行结束把连接信息保存到这里
INFO_FILE=""       # 运行目录下保存连接信息的文件（init_info_file 时确定）
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
PROTOCOL="${PROTOCOL}"
EOF
}

# 从 nginx 配置探测对外服务域名（排除占位/本地名）
detect_domain() {
    local dump names n
    dump=$(nginx -T 2>/dev/null || true)
    [[ -z "$dump" ]] && dump=$(grep -rhE '^[[:space:]]*server_name' /etc/nginx/ 2>/dev/null || true)
    names=$(grep -E '^[[:space:]]*server_name' <<<"$dump" | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' | tr ' ' '\n' || true)
    while read -r n; do
        [[ -z "$n" ]] && continue
        case "$n" in
            _|localhost|*[!a-zA-Z0-9.-]*) continue ;;
        esac
        [[ "$n" == *.* ]] || continue
        echo "$n"; return 0
    done <<<"$names"
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
    PROTOCOL=$(jq -r '.inbounds[0].protocol // "vmess"' "$V2RAY_CONFIG" 2>/dev/null)
    # 域名：优先脚本自身的 NGINX_CONF，其次从全局 nginx 配置探测（兼容手动/旧部署）
    if [[ -f "$NGINX_CONF" ]]; then
        DOMAIN=$(grep -m1 -E '^\s*server_name' "$NGINX_CONF" | awk '{print $2}' | tr -d ';')
    fi
    [[ -z "$DOMAIN" ]] && DOMAIN=$(detect_domain)
    # 推断真实伪装站根目录（以 nginx 实际服务目录为准，避免误用默认值）
    local wr; wr=$(detect_webroot); [[ -n "$wr" ]] && WEBROOT="$wr"
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
    apt-get install -y curl socat unzip git nginx dnsutils qrencode jq iproute2 python3 ca-certificates >/dev/null
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
    local domain="$1" ip="" out=""
    if command -v dig >/dev/null 2>&1; then
        out=$(dig +short A "$domain" @1.1.1.1 2>/dev/null || true)
        [[ -z "$out" ]] && out=$(dig +short A "$domain" 2>/dev/null || true)
        ip=$(grep -E '^[0-9.]+$' <<<"$out" | head -1 || true)
    fi
    if [[ -z "$ip" ]] && command -v getent >/dev/null 2>&1; then
        out=$(getent ahostsv4 "$domain" 2>/dev/null || true)
        ip=$(awk '{print $1}' <<<"$out" | head -1 || true)
    fi
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
    local unit line cfg
    # 先把整段输出读入变量，再在变量上 grep，避免 grep -m1 触发上游 SIGPIPE
    unit=$(systemctl cat v2ray 2>/dev/null || true)
    [[ -z "$unit" && -f /etc/systemd/system/v2ray.service ]] && unit=$(cat /etc/systemd/system/v2ray.service 2>/dev/null || true)
    line=$(grep -m1 '^ExecStart=' <<<"$unit" || true)
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
    # acme.sh --issue 退出码：0=成功签发，2=证书已存在且无需续期（跳过）。两者都视为正常；
    # 其它非零码才是真正失败。这样重复运行 install 时不会因"已有证书"被误判为失败。
    local rc=0
    "${ACME_HOME}/acme.sh" --issue -d "$DOMAIN" --standalone --keylength ec-256 >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 && $rc -ne 2 ]]; then
        error "证书签发失败（acme.sh 退出码 ${rc}）。请确认 80 端口空闲、域名已解析、防火墙放行 80/443。"
        systemctl start nginx >/dev/null 2>&1 || true; exit 1
    fi
    # 安装/复制证书到目标路径
    "${ACME_HOME}/acme.sh" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$CERT_FILE" --key-file "$KEY_FILE" >/dev/null 2>&1 || true
    # 以"证书文件是否真正生成"作为最终成功判据，避免退出码歧义
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        error "证书文件未生成（${CERT_FILE} / ${KEY_FILE}）。请检查 acme.sh 日志：${ACME_HOME}/acme.sh --info -d ${DOMAIN}"
        systemctl start nginx >/dev/null 2>&1 || true; exit 1
    fi
    info "证书就绪：${CERT_FILE}"
}

# ---------- 伪装站 ----------
# 伪装站采用「主题模板 + 每日抓取量子位(qbitai.com)资讯」：先铺好 clean-blog 主题（提供
# CSS/JS/图片等静态资源），再由 qbit-camouflage 抓取真实资讯生成首页，并配置每日定时更新，
# 使站点看起来是一个持续更新的真实 AI 资讯站，而非静态假页面。
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
        rm -rf "$tmp"; info "伪装主题部署完成。"
    else
        warn "拉取主题模板失败，将仅依赖抓取内容（页面可能无样式）。"
    fi
    install_camouflage_updater
    info "首次抓取量子位资讯生成首页 ..."
    QBIT_FEED="${QBIT_FEED:-https://www.qbitai.com/feed}" /usr/local/bin/qbit-camouflage "$WEBROOT" || warn "首次抓取失败，保留模板首页。"
    # 每日 07:30 定时抓取更新
    ( crontab -l 2>/dev/null | grep -v 'qbit-camouflage'; echo "30 7 * * * /usr/local/bin/qbit-camouflage ${WEBROOT} >/var/log/qbit-camouflage.log 2>&1" ) | crontab -
    info "已配置每日 07:30 自动抓取更新伪装站内容。"
}

# 安装伪装站每日更新器：抓取量子位 RSS 生成首页（抓取失败时保留现有页面）
install_camouflage_updater() {
    info "安装伪装站更新器 /usr/local/bin/qbit-camouflage ..."
    cat > /usr/local/bin/qbit-camouflage <<'UPDATER'
#!/usr/bin/env bash
# qbit-camouflage：抓取量子位(qbitai.com) RSS，生成伪装站首页 index.html。
# 用法：qbit-camouflage [webroot]   （默认 /home/wwwroot/blog）
# 抓取/解析失败时保留现有页面，绝不写出空页面。
set -u
WEBROOT="${1:-/home/wwwroot/blog}"
FEED="${QBIT_FEED:-https://www.qbitai.com/feed}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

[ -d "$WEBROOT" ] || mkdir -p "$WEBROOT"
TMP="$(mktemp)"; OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT"' EXIT

if ! curl -fsSL --max-time 30 -A "$UA" "$FEED" -o "$TMP" || [ ! -s "$TMP" ]; then
    echo "[qbit-camouflage] RSS 获取失败，保留现有页面" >&2
    exit 0
fi

if ! FEED_FILE="$TMP" python3 - "$OUT" <<'PYEOF'
import sys, os, html, datetime, email.utils
import xml.etree.ElementTree as ET

feed_file = os.environ["FEED_FILE"]
out_file = sys.argv[1]
DC = "{http://purl.org/dc/elements/1.1/}creator"

try:
    items = ET.parse(feed_file).findall(".//item")
except Exception as e:
    sys.stderr.write("parse error: %s\n" % e)
    sys.exit(1)

if not items:
    sys.exit(1)

def fmt(pub):
    try:
        dt = email.utils.parsedate_to_datetime(pub)
        return dt.astimezone(datetime.timezone(datetime.timedelta(hours=8))).strftime("%Y年%m月%d日 %H:%M")
    except Exception:
        return pub

posts = []
for it in items[:12]:
    title = html.escape((it.findtext("title") or "").strip())
    link = html.escape((it.findtext("link") or "#").strip())
    desc = html.escape((it.findtext("description") or "").strip())
    creator = html.escape((it.findtext(DC) or "编辑部").strip())
    date = html.escape(fmt((it.findtext("pubDate") or "").strip()))
    if not title:
        continue
    sub = ('<h3 class="post-subtitle">%s</h3>' % desc) if desc else ""
    posts.append(
        '<div class="post-preview">\n'
        '  <a href="%s" target="_blank" rel="noopener">\n'
        '    <h2 class="post-title">%s</h2>\n%s'
        '  </a>\n'
        '  <p class="post-meta">由 %s 发布于 %s</p>\n'
        '</div>\n<hr class="my-4" />' % (link, title, sub, creator, date)
    )

updated = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%Y-%m-%d %H:%M")
year = datetime.datetime.now().year

page = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
    <meta name="description" content="智能前线 - 每日追踪人工智能与前沿科技动态" />
    <meta name="author" content="智能前线" />
    <title>智能前线 - 每日 AI 与科技前沿速递</title>
    <link rel="icon" type="image/x-icon" href="assets/favicon.ico" />
    <script src="https://use.fontawesome.com/releases/v6.3.0/js/all.js" crossorigin="anonymous"></script>
    <link href="https://fonts.googleapis.com/css?family=Lora:400,700,400italic,700italic" rel="stylesheet" type="text/css" />
    <link href="https://fonts.googleapis.com/css?family=Open+Sans:300italic,400italic,600italic,700italic,800italic,400,300,600,700,800" rel="stylesheet" type="text/css" />
    <link href="css/styles.css" rel="stylesheet" />
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-light" id="mainNav">
        <div class="container px-4 px-lg-5">
            <a class="navbar-brand" href="index.html">智能前线</a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarResponsive" aria-controls="navbarResponsive" aria-expanded="false" aria-label="Toggle navigation">
                菜单 <i class="fas fa-bars"></i>
            </button>
            <div class="collapse navbar-collapse" id="navbarResponsive">
                <ul class="navbar-nav ms-auto py-4 py-lg-0">
                    <li class="nav-item"><a class="nav-link px-lg-3 py-3 py-lg-4" href="index.html">首页</a></li>
                    <li class="nav-item"><a class="nav-link px-lg-3 py-3 py-lg-4" href="about.html">关于</a></li>
                    <li class="nav-item"><a class="nav-link px-lg-3 py-3 py-lg-4" href="contact.html">联系</a></li>
                </ul>
            </div>
        </div>
    </nav>
    <header class="masthead" style="background-image: url('assets/img/home-bg.jpg')">
        <div class="container position-relative px-4 px-lg-5">
            <div class="row gx-4 gx-lg-5 justify-content-center">
                <div class="col-md-10 col-lg-8 col-xl-7">
                    <div class="site-heading">
                        <h1>智能前线</h1>
                        <span class="subheading">每日追踪人工智能与前沿科技动态</span>
                    </div>
                </div>
            </div>
        </div>
    </header>
    <div class="container px-4 px-lg-5">
        <div class="row gx-4 gx-lg-5 justify-content-center">
            <div class="col-md-10 col-lg-8 col-xl-7">
__POSTS__
                <div class="small text-center text-muted fst-italic mb-4">内容每日更新 · 最近更新：__UPDATED__</div>
            </div>
        </div>
    </div>
    <footer class="border-top">
        <div class="container px-4 px-lg-5">
            <div class="row gx-4 gx-lg-5 justify-content-center">
                <div class="col-md-10 col-lg-8 col-xl-7">
                    <div class="small text-center text-muted fst-italic">Copyright &copy; 智能前线 __YEAR__</div>
                </div>
            </div>
        </div>
    </footer>
    <script src="js/bootstrap.bundle.min.js"></script>
    <script src="js/scripts.js"></script>
</body>
</html>
"""

page = page.replace("__POSTS__", "\n".join(posts))
page = page.replace("__UPDATED__", updated)
page = page.replace("__YEAR__", str(year))

with open(out_file, "w", encoding="utf-8") as f:
    f.write(page)
PYEOF
then
    echo "[qbit-camouflage] 生成失败，保留现有页面" >&2
    exit 0
fi

if [ -s "$OUT" ]; then
    install -m 644 "$OUT" "$WEBROOT/index.html"
    echo "[qbit-camouflage] 已更新 $WEBROOT/index.html （$(date '+%Y-%m-%d %H:%M:%S')）"
else
    echo "[qbit-camouflage] 生成内容为空，保留现有页面" >&2
fi
UPDATER
    chmod +x /usr/local/bin/qbit-camouflage
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
    # 官方 v2ray 服务以 User=nobody 运行，必须保证配置文件对其可读
    chmod 644 "$V2RAY_CONFIG"
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

# ---------- BBR + 网络优化 ----------
# 重要：很多云厂商在 /etc/sysctl.conf 里写死了较小的 rmem_max/wmem_max，而该文件由
# `sysctl --system` 最后加载，会覆盖 /etc/sysctl.d/*.conf 的设置。因此这里把优化项以
# 受管块的形式追加到 /etc/sysctl.conf 末尾（同文件内后写的生效），确保压过厂商默认值。
SYSCTL_BEGIN="# >>> v2ray-deploy network tuning >>>"
SYSCTL_END="# <<< v2ray-deploy network tuning <<<"
enable_bbr() {
    info "开启 BBR 并优化网络参数 ..."
    modprobe tcp_bbr 2>/dev/null || true
    # 清理旧的独立文件与受管块，避免重复/冲突
    rm -f /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
    sed -i "/${SYSCTL_BEGIN}/,/${SYSCTL_END}/d" /etc/sysctl.conf 2>/dev/null || true
    cat >> /etc/sysctl.conf <<EOF
${SYSCTL_BEGIN}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
${SYSCTL_END}
EOF
    sysctl --system >/dev/null 2>&1 || true
    local cc qd rmem
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [[ "$cc" == "bbr" && "$rmem" -ge 33554432 ]]; then
        info "网络优化已生效（拥塞控制：${cc}，队列：${qd}，TCP缓冲：$((rmem/1024/1024))MB，MTU探测：开）。"
    else
        warn "网络优化未完全生效（cc=${cc}, rmem_max=${rmem}）。内核需 4.9+ 才支持 BBR；可重启后再试。"
    fi
}

# ---------- 生成客户端链接 ----------
# URL 编码（用于 vless 链接的 path 等参数）
urlencode() {
    local s="$1" out="" c i
    for ((i=0;i<${#s};i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    echo "$out"
}

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

# 用法：build_vless_link <uuid> <ps备注>（VLESS + WS + TLS，TLS 由 nginx 在 443 终止）
build_vless_link() {
    local uuid="$1" ps="$2"
    local p; p=$(urlencode "$WS_PATH")
    echo "vless://${uuid}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${p}#$(urlencode "$ps")"
}

# 按当前部署协议生成链接
build_link() {
    if [[ "${PROTOCOL,,}" == "vless" ]]; then build_vless_link "$1" "$2"; else build_vmess_link "$1" "$2"; fi
}

# Anywhere(iOS/macOS 原生客户端) 一键导入 deep link：anywhere://add-proxy?link=<链接>
# link 参数取 ?link= 之后的内容（无需百分号编码）。注意 Anywhere 不支持 vmess://。
build_anywhere_link() { echo "anywhere://add-proxy?link=$1"; }

# 初始化运行目录下的连接信息文件
init_info_file() {
    INFO_FILE="${RUN_DIR}/v2ray-${DOMAIN}-info.txt"
    {
        echo "# V2Ray 连接信息"
        echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 伪装网站：https://${DOMAIN}/"
        echo "# 协议：${PROTOCOL}    地址：${DOMAIN}    端口：443    路径：${WS_PATH}"
        echo "# Anywhere 客户端：https://apps.apple.com/us/app/id6758235178"
        echo
    } > "$INFO_FILE" 2>/dev/null || { warn "无法写入运行目录 ${RUN_DIR}，跳过信息保存。"; INFO_FILE=""; }
}

# 追加一条用户记录到信息文件
append_info() {  # <uuid> <name> <link> <anywhere_link>
    [[ -n "$INFO_FILE" ]] || return 0
    {
        echo "用户：$2"
        echo "UUID：$1"
        echo "链接：$3"
        echo "Anywhere 一键导入：$4"
        echo "----------------------------------------"
    } >> "$INFO_FILE" 2>/dev/null || true
}

print_user_link() {
    local uuid="$1" name="$2"
    local ps="${name}_${DOMAIN}"
    local link; link=$(build_link "$uuid" "$ps")
    local aw; aw=$(build_anywhere_link "$link")
    local scheme="vmess"; [[ "${PROTOCOL,,}" == "vless" ]] && scheme="vless"
    echo
    echo -e "${GREEN}用户：${name}${PLAIN}  UUID：${uuid}"
    echo -e "${BLUE}${scheme}:// 链接：${PLAIN}"
    echo "$link"
    echo -e "${BLUE}Anywhere 一键导入：${PLAIN}"
    echo "$aw"
    [[ "${PROTOCOL,,}" == "vmess" ]] && warn "Anywhere 不支持 vmess，该一键导入仅对 vless 等协议有效。"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE}二维码（${scheme} 链接）：${PLAIN}"
        qrencode -t ANSIUTF8 "$link"
    fi
    append_info "$uuid" "$name" "$link" "$aw"
}

# 提示信息文件已保存
notify_info_saved() {
    [[ -n "$INFO_FILE" && -f "$INFO_FILE" ]] && info "连接信息已保存到：${GREEN}${INFO_FILE}${PLAIN}"
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
    local ok="" listening
    for _ in 1 2 3 4 5; do
        # 先存变量再匹配，避免 grep 提前关闭管道导致 ss 收到 SIGPIPE 而误判
        listening=$(ss -tlnp 2>/dev/null || true)
        if grep -q "127.0.0.1:${V2RAY_PORT}\b" <<<"$listening"; then ok=1; break; fi
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
    echo -e " 地址(add) : ${DOMAIN}"
    echo -e " 端口(port): 443"
    echo -e " UUID(id)  : ${UUID}"
    echo -e " 路径(path): ${WS_PATH}"
    echo -e "${GREEN}===============================================${PLAIN}"
    # 链接与二维码放在最后输出，方便直接复制 / 扫码
    init_info_file
    print_user_link "$UUID" "admin"
    notify_info_saved
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
    if [[ "${PROTOCOL,,}" == "vless" ]]; then
        jq --arg id "$uuid" --arg n "$name" \
            '.inbounds[0].settings.clients += [{"id":$id,"email":$n}]' \
            "$V2RAY_CONFIG" > "$tmp" && mv "$tmp" "$V2RAY_CONFIG"
    else
        jq --arg id "$uuid" --arg n "$name" \
            '.inbounds[0].settings.clients += [{"id":$id,"alterId":0,"email":$n}]' \
            "$V2RAY_CONFIG" > "$tmp" && mv "$tmp" "$V2RAY_CONFIG"
    fi
    chmod 644 "$V2RAY_CONFIG"  # mktemp 默认 600，需恢复为 nobody 可读
    restart_v2ray
    info "已添加用户：${name}"
    init_info_file
    print_user_link "$uuid" "$name"
    notify_info_saved
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
    chmod 644 "$V2RAY_CONFIG"  # mktemp 默认 600，需恢复为 nobody 可读
    restart_v2ray
    info "已删除用户：${name}"
}

# 列出所有用户、打印链接并保存到运行目录信息文件（需先 require_installed）
list_and_save_users() {
    need_jq
    local count; count=$(jq '.inbounds[0].settings.clients | length' "$V2RAY_CONFIG")
    info "共 ${count} 个用户（域名：${DOMAIN}，路径：${WS_PATH}）："
    init_info_file
    local n
    while IFS=$'\t' read -r name id; do
        [[ -z "$id" ]] && continue
        n=${name:-user}
        print_user_link "$id" "$n"
    done < <(jq -r '.inbounds[0].settings.clients[] | "\(.email // "user")\t\(.id)"' "$V2RAY_CONFIG")
    notify_info_saved
}

# 查看所有用户及链接
do_users() { check_root; require_installed; list_and_save_users; }

do_bbr() { check_root; enable_bbr; }

# ---------- 升级（网络优化 + 动态伪装），兼容非本脚本部署 ----------
# 从 nginx 配置探测伪装站根目录（兼容 apt 版与源码编译版 nginx）
# 会排除 ACME 验证 / well-known 等非伪装目录，返回第一个合理的站点根目录
detect_webroot() {
    local dump roots line r=""
    if command -v nginx >/dev/null 2>&1; then
        dump=$(nginx -T 2>/dev/null || true)
    fi
    [[ -z "$dump" ]] && dump=$(grep -rhE '^[[:space:]]*root[[:space:]]+[^;]+;' /etc/nginx/ 2>/dev/null || true)
    roots=$(grep -E '^[[:space:]]*root[[:space:]]' <<<"$dump" | awk '{print $2}' | tr -d ';' || true)
    while read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            *letsencrypt*|*well-known*|*acme*|*challenge*|*.well-known*) continue ;;
        esac
        r="$line"; break
    done <<<"$roots"
    echo "$r"
}

# 将（可能是静态的）伪装站升级为「每日抓取量子位资讯」的动态站；幂等
upgrade_camouflage() {
    # 安全保护：若现有伪装站是 WordPress 等真实 CMS（本身就是高质量动态伪装），
    # 则跳过替换，避免破坏正在运行的站点。
    if [[ -f "$WEBROOT/wp-config.php" || -d "$WEBROOT/wp-content" || -d "$WEBROOT/wp-includes" ]]; then
        warn "检测到 ${WEBROOT} 为 WordPress 站点（已是高质量动态伪装），跳过伪装站替换。"
        return 0
    fi
    info "升级伪装站为「每日抓取量子位资讯」动态站 -> ${WEBROOT}"
    mkdir -p "$WEBROOT"
    # 仅当目录基本为空（无主题且无首页）时才补齐 clean-blog 主题，避免覆盖已有站点
    if [[ ! -e "$WEBROOT/css" && ! -e "$WEBROOT/index.html" ]]; then
        local tmp="/tmp/clean-blog-$$"
        if git clone --depth 1 https://github.com/StartBootstrap/startbootstrap-clean-blog.git "$tmp" >/dev/null 2>&1 && [[ -d "$tmp/dist" ]]; then
            cp -r "$tmp/dist/." "$WEBROOT/"
            curl -fsSL --max-time 20 -o "$WEBROOT/js/bootstrap.bundle.min.js" \
                https://cdn.jsdelivr.net/npm/bootstrap@5.2.3/dist/js/bootstrap.bundle.min.js 2>/dev/null || true
            rm -rf "$tmp"
        else
            warn "拉取主题模板失败，将仅依赖抓取内容生成首页。"
        fi
    fi
    install_camouflage_updater
    [[ -f "$WEBROOT/index.html" ]] && cp "$WEBROOT/index.html" "$WEBROOT/index.html.bak" 2>/dev/null || true
    info "抓取量子位资讯生成首页 ..."
    QBIT_FEED="${QBIT_FEED:-https://www.qbitai.com/feed}" /usr/local/bin/qbit-camouflage "$WEBROOT" || warn "抓取失败，保留现有首页。"
    ( crontab -l 2>/dev/null | grep -v 'qbit-camouflage'; echo "30 7 * * * /usr/local/bin/qbit-camouflage ${WEBROOT} >/var/log/qbit-camouflage.log 2>&1" ) | crontab -
    info "伪装站升级完成，已配置每日 07:30 自动抓取更新。"
}

# 更新 V2Ray 核心到最新版（官方 fhs 安装脚本，仅更新二进制，不动配置）
upgrade_core() {
    info "更新 V2Ray 核心到最新版 ..."
    local before after
    before=$(/usr/local/bin/v2ray version 2>/dev/null | head -1 || true)
    if bash <(curl -fsSL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) >/dev/null 2>&1; then
        after=$(/usr/local/bin/v2ray version 2>/dev/null | head -1 || true)
        info "V2Ray 核心：${before:-未知} -> ${after:-未知}"
    else
        warn "V2Ray 核心更新失败（可能网络问题），保持现有版本。"
    fi
}

# 刷新 nginx 站点配置到脚本最新模板。
# 安全保护：仅当是“脚本标准布局”(apt nginx + 标准 conf 路径 + vmess + 脚本证书) 时才刷新，
# 否则跳过，避免破坏自定义/手动部署（如 WordPress+VLESS、源码编译版 nginx）。
upgrade_nginx_conf() {
    if [[ "${PROTOCOL,,}" != "vmess" ]]; then
        warn "非 vmess 部署（${PROTOCOL}），跳过 nginx 配置刷新（避免破坏自定义站点）。"; return 0
    fi
    if [[ ! -f "$NGINX_CONF" ]]; then
        warn "未发现脚本标准 nginx 配置 ${NGINX_CONF}（疑似手动/编译版部署），跳过 nginx 配置刷新。"; return 0
    fi
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        warn "未发现脚本标准证书 ${CERT_FILE}，跳过 nginx 配置刷新（避免写出引用缺失证书的配置）。"; return 0
    fi
    info "刷新 nginx 站点配置到最新模板 ..."
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)" 2>/dev/null || true
    write_nginx_config
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true
        info "nginx 站点配置已刷新。"
    else
        warn "新 nginx 配置校验失败，已保留原配置备份，请手动检查：nginx -t"
    fi
}

# 检查并续期 TLS 证书（acme.sh）
upgrade_cert() {
    if [[ -f "${ACME_HOME}/acme.sh" ]]; then
        info "检查 / 续期 TLS 证书 ..."
        "${ACME_HOME}/acme.sh" --cron --home "${ACME_HOME}" >/dev/null 2>&1 || true
        info "证书续期检查完成（acme.sh 仅在临近到期时实际续期）。"
    else
        warn "未检测到 acme.sh，证书可能由其它方式（certbot 等）管理，跳过续期。"
    fi
}

# 升级部署相关配置：核心 / nginx配置 / 伪装站 / 证书 / 元数据。
# 注意：不改动 BBR/网络优化（那是独立命令 deploy.sh bbr）。兼容旧/手动/VLESS 部署。
do_upgrade() {
    check_root
    info "===== 升级部署配置（不含 BBR）====="
    require_installed   # 探测配置路径 + 读取/推断 域名/路径/端口/协议
    # 确定伪装站目录：以 nginx 实际服务目录为准（权威），探测不到才退回元数据值
    local wr; wr=$(detect_webroot)
    [[ -n "$wr" ]] && WEBROOT="$wr"
    info "伪装站目录：${WEBROOT}"
    # 1) 更新 V2Ray 核心
    upgrade_core
    # 2) 刷新 nginx 站点配置（仅脚本标准布局）
    upgrade_nginx_conf
    # 3) 刷新动态伪装站（自动跳过 WordPress 等真实站点）
    upgrade_camouflage
    # 4) 证书检查 / 续期
    upgrade_cert
    # 5) 刷新元数据并重启校验
    save_meta
    restart_v2ray
    info "===== 升级完成（未改动 BBR；如需网络优化请运行：deploy.sh bbr）====="
    # 6) 重新生成运行目录信息文件 + Anywhere 链接
    list_and_save_users
}

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

    info "移除证书续期与伪装站更新任务 ..."
    crontab -l 2>/dev/null | grep -vE 'ssl_update.sh|qbit-camouflage' | crontab - 2>/dev/null || true
    rm -f /usr/bin/ssl_update.sh /usr/local/bin/qbit-camouflage /var/log/qbit-camouflage.log 2>/dev/null || true

    ask "是否删除证书 ${CERT_DIR} 与 acme.sh 记录？(y/N)："; read -r dc
    if [[ "${dc,,}" == "y" ]]; then
        load_meta 2>/dev/null || true
        [[ -n "${DOMAIN:-}" && -f "${ACME_HOME}/acme.sh" ]] && "${ACME_HOME}/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
        rm -f "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
    fi
    ask "是否删除伪装站点目录 ${WEBROOT}？(y/N)："; read -r dw
    [[ "${dw,,}" == "y" ]] && rm -rf "$WEBROOT" 2>/dev/null || true

    rm -rf "$META_DIR" 2>/dev/null || true
    # 移除网络优化受管块（保留厂商原有的 sysctl 设置）
    sed -i "/${SYSCTL_BEGIN}/,/${SYSCTL_END}/d" /etc/sysctl.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
    info "卸载完成。Nginx 软件包保留；网络优化(含BBR)已从 /etc/sysctl.conf 移除（重启后恢复）。"
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
    echo " 6) 升级配置（核心/nginx/伪装站/证书/元数据，不含BBR）"
    echo " 7) 卸载"
    echo " 0) 退出"
    echo -e "${GREEN}=====================================${PLAIN}"
    ask "请选择操作 [0-7]："; read -r opt
    case "$opt" in
        1) do_install ;;
        2) do_adduser ;;
        3) do_deluser ;;
        4) do_users ;;
        5) do_bbr ;;
        6) do_upgrade ;;
        7) do_uninstall ;;
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
        upgrade)        do_upgrade ;;
        uninstall)      do_uninstall ;;
        menu|"")        menu ;;
        -h|--help|help) sed -n '2,21p' "$0" ;;
        *) error "未知命令：$cmd"; sed -n '10,21p' "$0"; exit 1 ;;
    esac
}

main "$@"
