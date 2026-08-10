#!/usr/bin/env bash
# Remnawave 真爱直达包 · 2026
# Ubuntu / Debian
# Docker + Remnawave + Nginx + SSL
#
# 使用前请确认：
# 1. 域名 A 记录已经指向 EC2 公网 IP
# 2. AWS Security Group 已开放 TCP 443
# 3. AWS Security Group 已开放 TCP 8443（申请/续期 SSL 必需）
#
# 注意：
# AWS Security Group 无法仅靠本脚本安全修改，请手动确认。

set -euo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="/opt/remnawave/nginx"

echo
echo "╔════════════════════════════════════════════╗"
echo "║        💘 Remnawave 真爱直达包 · 2026     ║"
echo "╚════════════════════════════════════════════╝"
echo
echo "别折腾了，让 Remnawave 和你的服务器直接坠入爱河。"
echo

# ============================================================
# 0. Root
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 运行："
    echo "   sudo bash remnawave-love.sh"
    exit 1
fi

# ============================================================
# 1. OS 检查
# ============================================================

if [ ! -f /etc/os-release ]; then
    echo "❌ 无法识别当前系统。"
    exit 1
fi

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        echo "❌ 本脚本只支持 Ubuntu / Debian。"
        echo "   当前系统：${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

echo "✅ 系统：${PRETTY_NAME:-$ID}"
echo

# ============================================================
# 2. 域名 / 邮箱
# ============================================================

read -rp "💘 面板域名（例如 panel.example.com）: " MAIN_DOMAIN

if [ -z "$MAIN_DOMAIN" ]; then
    echo "❌ 面板域名不能为空。"
    exit 1
fi

read -rp "💌 订阅域名（留空 = 和面板共用一个域名）: " SUB_DOMAIN

if [ -z "$SUB_DOMAIN" ]; then
    SUB_DOMAIN="$MAIN_DOMAIN"
fi

read -rp "📮 SSL 证书邮箱（例如 admin@example.com）: " EMAIL

if [ -z "$EMAIL" ]; then
    echo "❌ 邮箱不能为空。"
    exit 1
fi

echo
echo "────────────────────────────────────────────"
echo "💘 面板：$MAIN_DOMAIN"
echo "💌 订阅：$SUB_DOMAIN"
echo "📮 邮箱：$EMAIL"
echo "────────────────────────────────────────────"
echo

echo "请确认："
echo "  AWS Security Group 已开放 TCP 443"
echo "  AWS Security Group 已开放 TCP 8443"
echo

read -rp "都准备好了？按 Enter 继续，Ctrl+C 退出：" _

# ============================================================
# 3. 基础依赖
# ============================================================

echo
echo ">>> 🧰 给服务器穿好装备：curl / socat / cron / openssl"

apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    socat \
    cron \
    openssl \
    ca-certificates

systemctl enable --now cron >/dev/null 2>&1 || true

# ============================================================
# 4. Docker
# ============================================================

if ! command -v docker >/dev/null 2>&1; then
    echo
    echo ">>> 🐳 Docker 还没来？那就请它进场。"

    curl -fsSL https://get.docker.com | sh
else
    echo ">>> 🐳 Docker 已在这里，老朋友了，跳过安装。"
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ docker compose 插件不可用。"
    echo "   请确认 Docker 安装正常。"
    exit 1
fi

echo "✅ Docker：$(docker --version)"
echo "✅ Compose：$(docker compose version --short)"

# ============================================================
# 5. 创建 Remnawave
# ============================================================

echo
echo ">>> 💕 给 Remnawave 安个家：$INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 官方 docker-compose
if [ ! -f docker-compose.yml ]; then
    echo ">>> 📦 拉取 Remnawave 官方 docker-compose..."
    curl -fsSL \
        -o docker-compose.yml \
        https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
else
    echo ">>> 📦 docker-compose.yml 已存在，保留现有文件。"
fi

# 官方 .env
if [ ! -f .env ]; then
    echo ">>> 🔐 拉取官方 .env.sample..."
    curl -fsSL \
        -o .env \
        https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
else
    echo ">>> 🔐 .env 已存在，继续使用现有配置。"
fi

# ============================================================
# 6. 写入环境变量
# ============================================================

echo
echo ">>> 🔐 给 Remnawave 换上新的爱情密码..."

set_env() {
    local key="$1"
    local value="$2"

    if grep -qE "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    elif grep -qE "^#${key}=" .env; then
        sed -i "s|^#${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
}

# ------------------------------------------------------------
# APP_SECRET
# 官方要求使用 APP_SECRET
# 每次运行都生成新的随机 APP_SECRET
# ------------------------------------------------------------

APP_SECRET="$(openssl rand -hex 64)"

# METRICS_PASS
METRICS_PASS="$(openssl rand -hex 64)"

# WEBHOOK_SECRET_HEADER
# 官方要求：准确 64 个字符
WEBHOOK_SECRET_HEADER="$(openssl rand -hex 32)"

# PostgreSQL
POSTGRES_PASSWORD="$(openssl rand -hex 24)"

set_env "APP_SECRET" "$APP_SECRET"
set_env "METRICS_PASS" "$METRICS_PASS"
set_env "WEBHOOK_SECRET_HEADER" "$WEBHOOK_SECRET_HEADER"
set_env "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"

# ------------------------------------------------------------
# DATABASE_URL 同步 PostgreSQL 密码
# ------------------------------------------------------------

if grep -q '^DATABASE_URL=' .env; then
    sed -i \
        "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\)|\1${POSTGRES_PASSWORD}\2|" \
        .env
else
    echo "DATABASE_URL=\"postgresql://postgres:${POSTGRES_PASSWORD}@remnawave-db:5432/postgres\"" >> .env
fi

# ============================================================
# 7. Remnawave 域名
# ============================================================

echo
echo ">>> 🌹 告诉 Remnawave：你以后就住这里。"

# 官方当前使用 FRONT_END_DOMAIN
set_env "FRONT_END_DOMAIN" "$MAIN_DOMAIN"

# 订阅地址
set_env "SUB_PUBLIC_DOMAIN" "${SUB_DOMAIN}/api/sub"

echo "   FRONT_END_DOMAIN=${MAIN_DOMAIN}"
echo "   SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub"

# ============================================================
# 8. 检查关键端口
# ============================================================

echo
echo ">>> 🔍 看看 443 / 8443 有没有别人占着..."

if ss -lnt 2>/dev/null | grep -qE '(^|:)443[[:space:]]'; then
    echo "❌ TCP 443 已经被其他程序占用。"
    echo "   请先处理 443 端口，再运行本脚本。"
    exit 1
fi

if ss -lnt 2>/dev/null | grep -qE '(^|:)8443[[:space:]]'; then
    echo "❌ TCP 8443 已经被其他程序占用。"
    echo "   acme.sh 需要暂时使用 8443。"
    exit 1
fi

echo "✅ 443 空闲"
echo "✅ 8443 空闲"

# ============================================================
# 9. 启动 Remnawave
# ============================================================

echo
echo ">>> 🚀 Remnawave 出发！"

docker compose up -d

echo
echo ">>> ⏳ 给 Remnawave 一点时间谈恋爱..."

sleep 8

if ! docker inspect -f '{{.State.Running}}' remnawave 2>/dev/null | grep -q true; then
    echo "❌ Remnawave 容器没有正常运行。"
    echo
    docker compose ps
    echo
    docker compose logs --tail=80 remnawave
    exit 1
fi

echo "✅ Remnawave 已启动。"

# ============================================================
# 10. Docker 网络
# ============================================================

echo
echo ">>> 🌐 准备 Nginx 与 Remnawave 的约会场地..."

docker network create remnawave-network >/dev/null 2>&1 || true

# ============================================================
# 11. acme.sh
# ============================================================

echo
echo ">>> 🔒 SSL 证书：让你的域名也穿上西装。"

if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    echo ">>> 安装 acme.sh..."

    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
fi

ACME_SH="$HOME/.acme.sh/acme.sh"

if [ ! -x "$ACME_SH" ]; then
    echo "❌ acme.sh 安装失败。"
    exit 1
fi

mkdir -p "$NGINX_DIR"

# ============================================================
# 12. SSL 证书
# ============================================================

echo
echo ">>> 🔐 为你的域名申请 SSL..."

CERT_ARGS=(-d "$MAIN_DOMAIN")

if [ "$SUB_DOMAIN" != "$MAIN_DOMAIN" ]; then
    CERT_ARGS+=(-d "$SUB_DOMAIN")
fi

"$ACME_SH" --issue \
    --standalone \
    "${CERT_ARGS[@]}" \
    --alpn \
    --tlsport 8443 \
    --key-file "$NGINX_DIR/privkey.key" \
    --fullchain-file "$NGINX_DIR/fullchain.pem"

echo "✅ SSL 证书申请成功。"

# ============================================================
# 13. Nginx 配置
# ============================================================

echo
echo ">>> 🪽 Nginx 登场：负责把 HTTPS 请求温柔地送到 Remnawave。"

cat > "$NGINX_DIR/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    server_name $MAIN_DOMAIN $SUB_DOMAIN;

    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
    }

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;

    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    ssl_reject_handshake on;
}
EOF

# ============================================================
# 14. Nginx Compose
# ============================================================

echo
echo ">>> 🐳 给 Nginx 安排一个独立的小窝..."

cat > "$NGINX_DIR/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:stable-alpine
    container_name: remnawave-nginx
    hostname: remnawave-nginx

    cap_drop:
      - ALL

    cap_add:
      - NET_BIND_SERVICE

    security_opt:
      - no-new-privileges:true

    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro

    restart: unless-stopped

    ports:
      - "443:443"

    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
EOF

# ============================================================
# 15. 启动 Nginx
# ============================================================

echo
echo ">>> 🚀 Nginx 上线，最后一公里马上打通。"

cd "$NGINX_DIR"

docker compose up -d

sleep 3

# ============================================================
# 16. Nginx 检查
# ============================================================

echo
echo ">>> 🩺 做最后一次健康检查..."

if ! docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null | grep -q true; then
    echo "❌ Nginx 启动失败。"
    echo
    docker compose ps
    echo
    docker compose logs --tail=80
    exit 1
fi

if ! curl -kIs --max-time 10 "https://${MAIN_DOMAIN}" >/dev/null 2>&1; then
    echo
    echo "⚠️ HTTPS 暂时没有拿到正常响应。"
    echo
    echo "可能原因："
    echo "  1. DNS 还没有指向 EC2"
    echo "  2. AWS Security Group 没开放 443"
    echo "  3. DNS/CDN 还没有生效"
    echo
    echo "先不要慌，Nginx 本身已经启动。"
else
    echo "✅ HTTPS 已经可以正常访问。"
fi

# ============================================================
# 17. 注册证书自动续期
# ============================================================

echo
echo ">>> ♻️ 给 SSL 续上长情：证书到期会自动更新。"

"$ACME_SH" --install-cert \
    -d "$MAIN_DOMAIN" \
    --key-file "$NGINX_DIR/privkey.key" \
    --fullchain-file "$NGINX_DIR/fullchain.pem" \
    --reloadcmd "docker exec remnawave-nginx nginx -s reload"

echo "✅ SSL 自动续期已配置。"

# ============================================================
# 18. 最终检查
# ============================================================

echo
echo ">>> 🔥 最终状态"

echo
docker compose -f "$INSTALL_DIR/docker-compose.yml" ps
echo
docker compose -f "$NGINX_DIR/docker-compose.yml" ps

echo
echo "╔════════════════════════════════════════════╗"
echo "║              💘 真爱已连接                 ║"
echo "╠════════════════════════════════════════════╣"
echo "║                                            ║"
echo "║  🎛️  面板： https://$MAIN_DOMAIN"
echo "║  💌 订阅： $SUB_DOMAIN/api/sub"
echo "║  🔒 SSL ： 自动续期"
echo "║  🐳 Docker：已启动"
echo "║  🪽 Nginx ：已启动"
echo "║                                            ║"
echo "╚════════════════════════════════════════════╝"

echo
echo "❤️  常用命令"
echo
echo "   启动: docker compose up -d"
echo
echo "📁 Remnawave"
echo "   cd $INSTALL_DIR"
echo "   docker compose ps"
echo "   docker compose logs -f remnawave"
echo "   docker compose restart"
echo "   docker compose down"
echo
echo "🪽 Nginx"
echo "   cd $NGINX_DIR"
echo "   docker compose ps"
echo "   docker compose logs -f"
echo "   docker compose restart"
echo "   docker compose down"
echo
echo "🔐 SSL"
echo "   $ACME_SH --list"
echo
echo "🩺 快速检查"
echo "   curl -I https://$MAIN_DOMAIN"
echo "   docker ps"
echo
echo "💡 如果你修改了 .env："
echo "   cd $INSTALL_DIR"
echo "   docker compose down && docker compose up -d"
echo
echo "💘 好了，服务器已经就位。"
echo "   剩下的，就是让 Remnawave 好好爱你了。"
echo
