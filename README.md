# v2ray-deploy

一键部署 **V2Ray (VMess + WebSocket + TLS)** 并用真实静态网站进行伪装的交互式脚本。

普通访客访问域名时看到的是一个正常的技术博客，只有走随机暗道路径的 WebSocket 流量才会进入 V2Ray 代理，从而降低被识别和封锁的概率。

## 特性

- **交互式输入域名**，并自动**校验域名解析的 IP 是否与本机公网 IP 一致**（不一致会警告并允许选择是否强制继续）
- 通过 [acme.sh](https://github.com/acmesh-official/acme.sh) 自动签发 Let's Encrypt 证书，并配置**每周自动续期**
- Nginx 前置反代：`/` 显示伪装博客，仅随机暗道路径走 WebSocket 进入 V2Ray
- 自动生成 **UUID** 与**随机 WebSocket 路径**
- 自动输出 `vmess://` 链接与终端二维码，可直接导入 v2rayN / v2rayNG / Shadowrocket 等客户端
- 使用现代 **VMess AEAD（alterId = 0）** 加密
- **BBR 加速**：一键开启 BBR + fq 队列，提升网络吞吐
- **多用户管理**：随时添加 / 删除用户，每个用户独立 UUID 与连接链接
- **一键卸载**：清理 V2Ray、Nginx 站点配置、续期任务（证书/伪装站可选择是否删除）
- **动态伪装站**：每日定时抓取[量子位(qbitai.com)](https://www.qbitai.com/)的真实 AI 资讯生成首页，看起来是一个持续更新的资讯站，而非静态假页面（抓取器 `/usr/local/bin/qbit-camouflage`，每日 07:30 cron 自动更新；抓取失败时保留现有页面）

## 命令一览

```bash
sudo bash deploy.sh             # 交互菜单
sudo bash deploy.sh install     # 部署
sudo bash deploy.sh adduser     # 添加用户（也可 adduser alice 直接指定备注）
sudo bash deploy.sh deluser     # 删除用户（按序号）
sudo bash deploy.sh users       # 查看所有用户及各自 vmess 链接/二维码
sudo bash deploy.sh bbr         # 开启 BBR 加速
sudo bash deploy.sh upgrade     # 升级配置：V2Ray核心 / nginx站点配置 / 动态伪装站 / TLS证书续期 / 元数据（不含BBR，BBR请用 bbr 命令）
sudo bash deploy.sh uninstall   # 卸载
```

> 管理类命令（`users`/`adduser`/`deluser`）会自动识别现有部署的协议（**VMess / VLESS**）并从 `nginx -T` 探测域名，因此也能管理非本脚本/手动部署的节点。

### `upgrade` 升级配置说明

`upgrade` 升级的是**部署相关配置**（不含 BBR；BBR 用独立的 `bbr` 命令）：

1. **V2Ray 核心** → 更新到最新版（官方安装脚本，仅更新二进制、不动配置）
2. **nginx 站点配置** → 刷新到脚本最新模板（**仅对脚本标准布局生效**；检测到自定义/手动部署、VLESS、源码编译版 nginx 等会自动跳过，避免破坏现有站点）
3. **动态伪装站** → 刷新为每日抓取量子位（检测到 WordPress 等真实站点自动跳过）
4. **TLS 证书** → 经 acme.sh 检查并按需续期
5. **元数据 + 运行目录信息文件** → 重新生成（含 Anywhere 一键导入链接）

## 客户端导入与信息保存

- `install` / `adduser` / `users` 运行结束会额外输出 **Anywhere**（iOS/iPadOS/macOS 原生客户端）一键导入链接：

```
anywhere://add-proxy?link=<分享链接>
```

- 同时把全部连接信息（分享链接 + Anywhere 链接）保存到**运行目录**下的 `v2ray-<域名>-info.txt`。
- 注意：Anywhere **不支持 vmess**，一键导入仅对 `vless` 等协议有效；vmess 节点请用分享链接/二维码导入支持 vmess 的客户端。

## 适用系统

- Debian 10+ / Ubuntu 20.04+
- 需 root 权限
- 需提前将域名的 A 记录解析到本机公网 IP
- 云服务器安全组/防火墙需放行 **80 / 443** 端口

## 使用方法

```bash
# 下载脚本
curl -fsSLO https://raw.githubusercontent.com/wareash/v2ray-deploy/main/deploy.sh

# 运行（交互式）
sudo bash deploy.sh
```

运行后按提示输入域名即可。脚本会：

1. 检测本机公网 IP
2. 解析你输入的域名并与本机 IP 比对
3. 校验通过后自动完成依赖安装、证书签发、V2Ray/Nginx 配置、伪装站部署与服务启动
4. 在终端输出客户端连接信息、`vmess://` 链接与二维码

## 部署架构

```
客户端 ──TLS:443(域名)──▶ Nginx ──┬─▶ 普通访问  → 伪装博客（静态网站）
                                  └─▶ 暗道路径  → WebSocket → V2Ray VMess(127.0.0.1)
```

## 关键文件

| 路径 | 说明 |
|---|---|
| `/etc/v2ray/config.json` | V2Ray 服务端配置 |
| `/etc/nginx/conf.d/v2ray.conf` | Nginx 站点与反代配置 |
| `/data/v2ray.crt` `/data/v2ray.key` | TLS 证书与私钥 |
| `/home/wwwroot/blog` | 伪装站点根目录 |
| `/usr/local/etc/v2ray-deploy/deploy.conf` | 部署元数据（域名 / 路径 / 端口，供用户管理使用） |
| `/usr/bin/ssl_update.sh` | 证书续期脚本（cron 每周执行） |
| `/usr/local/bin/qbit-camouflage` | 伪装站每日更新器（抓取量子位资讯生成首页） |
| `/etc/sysctl.conf`（受管块） | BBR + 网络优化（大 TCP 缓冲 / MTU 探测，追加在文件末尾以压过云厂商默认值）|

## 卸载

```bash
sudo bash deploy.sh uninstall
```

会停止并移除 V2Ray、删除 Nginx 站点配置与证书续期任务；证书目录与伪装站目录会询问是否一并删除。Nginx 软件包与 BBR 设置默认保留。

## 免责声明

本脚本仅供学习与合法的网络通信、隐私保护用途。请在遵守你所在国家/地区法律法规的前提下使用，使用者需自行承担相关责任。
