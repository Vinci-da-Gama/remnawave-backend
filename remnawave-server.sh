#!/usr/bin/env bash

# ============================================================
# Remnawave 面板 + Nginx 反代 + Let's Encrypt 证书
# 目标环境：AWS EC2 / Ubuntu / Debian
#
# 本脚本只装面板。节点（remnanode）在面板装好后，
# 登录面板 Nodes -> Management 里创建，节点地址/端口/SNI 都在面板 UI 填。
# 节点若要和面板挤同一台机器共用 443，回来在 nginx.conf 的
# sni_target 映射里加一行即可（文件里已留好带注释的位置）。
#
# 端口架构
#   公网 :80  -> Nginx HTTP：ACME HTTP-01 校验 + 301 跳转
#   公网 :443 -> Nginx stream 层，ssl_preread 按 ALPN/SNI 分流
#                ├─ ALPN=acme-tls/1  -> 容器 :18443 -> 宿主机 :8443 (acme.sh)
#                ├─ SNI=面板/订阅域名 -> 容器 :9443 -> remnawave:3000
#                └─ 其它 SNI          -> 拒绝握手（节点位预留在此）
#
#   Let's Encrypt 的 TLS-ALPN-01 只连 443，所以由 stream 层按 ALPN
#   把校验流量转到 8443。同机节点同样占 443，靠 SNI 与面板分开。
#
# AWS 安全组：TCP 80、443 必开；8443 建议开（便于排查）。
# 3000 / 3001 / 6767 只绑 127.0.0.1，不对外。
# ============================================================

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="${INSTALL_DIR}/nginx"
CERT_DIR="${NGINX_DIR}/certs"              # 证书目录 -> 容器 /etc/nginx/ssl
ACME_WEBROOT="${NGINX_DIR}/acme-webroot"   # HTTP-01 校验目录 -> 容器 /var/www/acme
NETWORK_NAME="remnawave-network"

ACME_TLS_PORT="8443"        # 宿主机：acme.sh TLS-ALPN-01 监听端口
INTERNAL_HTTPS_PORT="9443"  # 容器内：面板 HTTPS
ACME_RELAY_PORT="18443"     # 容器内：剥离 PROXY 头后转发给 acme.sh

PG_USER="postgres"
PG_DB="postgres"

NGINX_IMAGE="nginx:1.30"

# Ctrl+C / kill 时优雅退出
stopped_by_user() {
    echo
    echo "process will be stopped."
    exit 130
}
trap stopped_by_user INT TERM

# 任意命令失败时打印行号和排查命令
on_error() {
    local line="${1:-unknown}"
    echo
    echo "ERROR: 安装在第 ${line} 行失败。"
    echo
    echo "排查命令："
    echo "  cd ${INSTALL_DIR} 2>/dev/null && docker compose ps"
    echo "  cd ${INSTALL_DIR} 2>/dev/null && docker compose logs --tail=100"
    echo "  cd ${NGINX_DIR} 2>/dev/null && docker compose logs --tail=100"
    exit 1
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------
# 字符串匹配辅助函数
#
# 全脚本不使用 `命令 | grep -q` 做判断：
# grep -q 命中后立即退出并关闭管道，上游命令若还在写就会收到
# SIGPIPE 而以 141 退出，set -o pipefail 会把整条管道判为失败，
# 于是明明匹配上了却走进错误分支。改成先取到字符串再用 bash 匹配。
# ------------------------------------------------------------

# 字符串 $1 是否包含子串 $2
str_has() {
    [[ "$1" == *"$2"* ]]
}

# 多行字符串 $1 里是否有一整行等于 $2
has_line() {
    [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

# 空格分隔的列表 $1 里是否含有词 $2
has_word() {
    [[ " $1 " == *" $2 "* ]]
}

# 容器 $1 是否已接入 ${NETWORK_NAME}
container_in_network() {
    local members
    members="$(docker network inspect "${NETWORK_NAME}" \
        --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null || true)"
    has_line "${members}" "$1"
}

echo
echo "============================================================"
echo "     Remnawave + Nginx(SNI 分流) + SSL Installer"
echo "============================================================"
echo

# ============================================================
# 1. 环境检查
# ============================================================

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: 请用 root 运行。"
    echo "用法: sudo bash $0"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "ERROR: 无法识别操作系统。"
    exit 1
fi

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        echo "ERROR: 本脚本仅支持 Ubuntu / Debian。"
        echo "当前系统: ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

echo "OK: ${PRETTY_NAME:-$ID}"

# ============================================================
# 2. 读取域名与邮箱
# ============================================================

echo
read -rp "面板域名 Panel domain (必填): " MAIN_DOMAIN

if [ -z "${MAIN_DOMAIN}" ]; then
    echo
    echo "面板域名为必填项，未输入，脚本退出。"
    exit 0
fi

echo
echo "订阅域名 Subscription domain（可选）"
echo "  直接回车 = 与面板使用同一个域名（${MAIN_DOMAIN}）"
read -rp "订阅域名: " SUB_DOMAIN

# 留空时订阅与面板共用一个域名
if [ -z "${SUB_DOMAIN}" ]; then
    SUB_DOMAIN="${MAIN_DOMAIN}"
fi

echo
read -rp "SSL 邮箱 (必填): " EMAIL

if [ -z "${EMAIL}" ]; then
    echo
    echo "SSL 邮箱为必填项，未输入，脚本退出。"
    exit 0
fi

# ============================================================
# 3. 域名合法性校验与去重
# ============================================================

validate_domain() {
    local domain="$1"

    if [[ "${domain}" == *"/"* ]] ||
       [[ "${domain}" == *" "* ]] ||
       [[ "${domain}" == *":"* ]] ||
       [[ "${domain}" == http://* ]] ||
       [[ "${domain}" == https://* ]]; then
        return 1
    fi

    [[ "${domain}" == *.* ]]
}

if ! validate_domain "${MAIN_DOMAIN}"; then
    echo "ERROR: 面板域名不合法: ${MAIN_DOMAIN}"
    exit 1
fi

if ! validate_domain "${SUB_DOMAIN}"; then
    echo "ERROR: 订阅域名不合法: ${SUB_DOMAIN}"
    exit 1
fi

# DOMAIN_LIST：面板 HTTPS 的域名，同时也是要签进证书的域名。
# 同名只保留一份，避免 nginx server_name 冲突和 acme.sh 重复 -d
DOMAIN_LIST=("${MAIN_DOMAIN}")
SAME_DOMAIN="yes"
if [ "${SUB_DOMAIN}" != "${MAIN_DOMAIN}" ]; then
    DOMAIN_LIST+=("${SUB_DOMAIN}")
    SAME_DOMAIN="no"
fi

echo
echo "------------------------------------------------------------"
echo "面板域名 : ${MAIN_DOMAIN}"
if [ "${SAME_DOMAIN}" = "yes" ]; then
    echo "订阅域名 : ${SUB_DOMAIN}  (与面板同域名)"
else
    echo "订阅域名 : ${SUB_DOMAIN}"
fi
echo "订阅地址 : https://${SUB_DOMAIN}/api/sub"
echo "SSL 邮箱 : ${EMAIL}"
echo "------------------------------------------------------------"
echo

# ============================================================
# 4. 清理旧安装
#
# 重装会生成新的 POSTGRES_PASSWORD，旧数据卷里存的是老密码，
# 不清理会导致后端连不上库。
# ============================================================

echo ">>> 检查是否存在旧安装..."

FOUND_OLD="no"

if [ -d "${INSTALL_DIR}" ]; then
    FOUND_OLD="yes"
fi

if command -v docker >/dev/null 2>&1; then
    OLD_CONTAINERS="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
    for c in remnawave remnawave-db remnawave-redis remnawave-nginx; do
        if has_line "${OLD_CONTAINERS}" "${c}"; then
            FOUND_OLD="yes"
        fi
    done

    OLD_VOLUMES="$(docker volume ls --format '{{.Name}}' 2>/dev/null || true)"
    for v in remnawave-db-data valkey-socket; do
        if has_line "${OLD_VOLUMES}" "${v}"; then
            FOUND_OLD="yes"
        fi
    done
fi

if [ "${FOUND_OLD}" = "yes" ]; then
    echo
    echo "检测到已有的 Remnawave 安装（目录 / 容器 / 数据卷）。"
    echo
    echo "将要删除："
    echo "  - 容器: remnawave remnawave-db remnawave-redis remnawave-nginx"
    echo "  - 数据卷: remnawave-db-data valkey-socket （面板数据会全部丢失）"
    echo "  - 目录: ${INSTALL_DIR}"
    echo "  /root/.acme.sh 里已签发的证书保留，不会重复消耗签发次数。"
    echo
    read -rp "确认清理并全新安装？输入 yes 继续，其它任意键退出: " WIPE_CONFIRM

    if [ "${WIPE_CONFIRM}" != "yes" ]; then
        echo "已取消，脚本退出。"
        exit 0
    fi

    echo ">>> 正在清理旧安装..."

    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        ( cd "${INSTALL_DIR}" && docker compose down -v --remove-orphans ) >/dev/null 2>&1 || true
    fi
    if [ -f "${NGINX_DIR}/docker-compose.yml" ]; then
        ( cd "${NGINX_DIR}" && docker compose down -v --remove-orphans ) >/dev/null 2>&1 || true
    fi

    docker rm -f remnawave remnawave-db remnawave-redis remnawave-nginx >/dev/null 2>&1 || true
    docker volume rm -f remnawave-db-data valkey-socket >/dev/null 2>&1 || true
    rm -rf "${INSTALL_DIR}"

    echo "OK: 旧安装已清理。"
else
    echo "OK: 未发现旧安装。"
fi

# ============================================================
# 5. 安装依赖
# ============================================================

echo
echo ">>> 安装系统依赖..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    socat \
    cron \
    openssl \
    ca-certificates \
    dnsutils \
    iproute2

systemctl enable --now cron >/dev/null 2>&1 || true

# ============================================================
# 6. Docker
# ============================================================

echo
echo ">>> 检查 Docker..."

if ! command -v docker >/dev/null 2>&1; then
    echo ">>> 安装 Docker..."
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 缺少 Docker Compose 插件。"
    exit 1
fi

echo "Docker : $(docker --version)"
echo "Compose: $(docker compose version)"

# ============================================================
# 7. Swap
#
# t3.micro 只有 1GB 内存，PostgreSQL + Valkey + Node 后端容易 OOM。
# 内存不足 1.8GB 且没有 swap 时建一个 2GB swap 文件。
# ============================================================

echo
echo ">>> 检查内存与 Swap..."

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
SWAP_LINES="$(swapon --show --noheadings 2>/dev/null | wc -l | tr -d ' ')"

echo "内存: ${MEM_MB} MB / Swap 条目: ${SWAP_LINES}"

if [ "${MEM_MB}" -lt 1800 ] && [ "${SWAP_LINES}" -eq 0 ] && [ ! -f /swapfile ]; then
    echo ">>> 创建 2GB /swapfile..."
    if fallocate -l 2G /swapfile 2>/dev/null || \
       dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        if ! grep -q '^/swapfile' /etc/fstab; then
            printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
        fi
        echo "OK: Swap 已启用。"
    else
        echo "WARNING: Swap 创建失败，继续安装。"
    fi
else
    echo "OK: 无需创建 Swap。"
fi

# ============================================================
# 8. DNS 检查
#
# 对比域名 A 记录与本机公网 IP（EC2 IMDSv2 获取）。
# 不匹配会导致证书签发失败，且每周只有 5 次签发机会，先拦下来。
# ============================================================

echo
echo ">>> 检查 DNS 解析..."

get_public_ip() {
    local token="" ip=""

    token="$(curl -sS -X PUT --max-time 3 \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" \
        "http://169.254.169.254/latest/api/token" 2>/dev/null || true)"

    if [ -n "${token}" ]; then
        ip="$(curl -sS --max-time 3 \
            -H "X-aws-ec2-metadata-token: ${token}" \
            "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
    fi

    # 非 EC2 环境或元数据不可用时的兜底
    if [ -z "${ip}" ]; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi

    printf '%s' "${ip}"
}

PUBLIC_IP="$(get_public_ip)"

if [ -n "${PUBLIC_IP}" ]; then
    echo "本机公网 IPv4: ${PUBLIC_IP}"
else
    echo "WARNING: 无法获取本机公网 IP，跳过 IP 比对。"
fi

DNS_OK="yes"

for d in "${DOMAIN_LIST[@]}"; do
    echo
    echo "域名: ${d}"

    RESOLVED="$(getent ahostsv4 "${d}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"

    if [ -z "${RESOLVED}" ]; then
        echo "  解析结果: (无 A 记录 / 未解析)"
        DNS_OK="no"
        continue
    fi

    echo "  解析结果: ${RESOLVED}"

    if [ -n "${PUBLIC_IP}" ]; then
        if has_word "${RESOLVED}" "${PUBLIC_IP}"; then
            echo "  OK: 已指向本机公网 IP"
        else
            echo "  WARNING: 未指向本机公网 IP (${PUBLIC_IP})"
            DNS_OK="no"
        fi
    fi
done

if [ "${DNS_OK}" != "yes" ]; then
    echo
    echo "------------------------------------------------------------"
    echo "DNS 检查未通过。"
    echo "请把上面所有域名的 A 记录指向: ${PUBLIC_IP:-<本机公网IPv4>}"
    echo "Cloudflare 需切换为「仅 DNS / DNS only」灰云。"
    echo "现在继续，证书签发几乎必然失败。"
    echo "------------------------------------------------------------"
    read -rp "仍要继续？输入 yes 继续，其它任意键退出: " DNS_CONFIRM
    if [ "${DNS_CONFIRM}" != "yes" ]; then
        echo "已退出。等 DNS 生效后重新运行本脚本。"
        exit 0
    fi
fi

# ============================================================
# 9. 端口占用检查
#
# 80=Nginx HTTP，443=Nginx stream，8443=acme.sh，6767=PostgreSQL
# ============================================================

echo
echo ">>> 检查本机端口占用..."

port_in_use() {
    local out
    out="$(ss -H -lnt "sport = :$1" 2>/dev/null || true)"
    [ -n "${out}" ]
}

for port in 80 443 "${ACME_TLS_PORT}" 6767; do
    if port_in_use "${port}"; then
        echo "ERROR: TCP ${port} 已被占用。"
        ss -lntp "sport = :${port}" || true
        exit 1
    fi
    echo "OK: ${port} 空闲"
done

# ============================================================
# 10. 建目录
# ============================================================

echo
echo ">>> 准备目录 ${INSTALL_DIR} ..."

mkdir -p "${INSTALL_DIR}"
mkdir -p "${NGINX_DIR}"
mkdir -p "${CERT_DIR}"
mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"

# 容器内 nginx 以 nginx 用户读取证书和校验文件，目录需 755
chmod 755 "${NGINX_DIR}" \
          "${CERT_DIR}" \
          "${ACME_WEBROOT}" \
          "${ACME_WEBROOT}/.well-known" \
          "${ACME_WEBROOT}/.well-known/acme-challenge"

cd "${INSTALL_DIR}"

# ============================================================
# 11. 下载官方 .env 模板
#
# 官方模板结尾没有换行符，直接 >> 追加会把新变量粘到最后一行的值后面。
# 下载后立刻补一个换行。
# ============================================================

echo
echo ">>> 下载 Remnawave 官方 .env 模板..."

curl -fsSL \
    -o "${INSTALL_DIR}/.env" \
    "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

if [ ! -s "${INSTALL_DIR}/.env" ]; then
    echo "ERROR: .env 下载失败。"
    exit 1
fi

# 最后一个字节不是 \n 就补一个（tail -c 1 | wc -l 为 0 表示没有换行）
ensure_trailing_newline() {
    local file="$1"
    [ -s "${file}" ] || return 0
    if [ "$(tail -c 1 "${file}" | wc -l | tr -d ' ')" -eq 0 ]; then
        printf '\n' >> "${file}"
    fi
}

ensure_trailing_newline "${INSTALL_DIR}/.env"
chmod 600 "${INSTALL_DIR}/.env"

echo "OK: .env 已下载。"

# ============================================================
# 12. Docker 网络
# ============================================================

echo
echo ">>> 创建 Docker 网络..."

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "OK: Docker 网络已存在。"
else
    docker network create --driver bridge "${NETWORK_NAME}" >/dev/null
    echo "OK: 已创建 Docker 网络 ${NETWORK_NAME}"
fi

# ============================================================
# 13. 生成 Remnawave 的 docker-compose.yml
#
# 引号 heredoc：Bash 不做替换，${...} 原样交给 Compose 解析。
# 宿主机路径用相对路径，由 Compose 相对 /opt/remnawave 解析。
# ============================================================

echo
echo ">>> 生成 Remnawave docker-compose.yml ..."

cat > "${INSTALL_DIR}/docker-compose.yml" <<'EOF'
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always
  networks:
    - remnawave-network

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

x-env: &env
  env_file:
    - .env

services:

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging, *env]

    volumes:
      - valkey-socket:/var/run/valkey
      # Xray 证书目录，与 Nginx 共用同一套 Let's Encrypt 证书
      - ./nginx/certs:/var/lib/remnawave/configs/xray/ssl

    ports:
      - "127.0.0.1:3000:${APP_PORT:-3000}"
      - "127.0.0.1:3001:${METRICS_PORT:-3001}"

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -f http://localhost:${METRICS_PORT:-3001}/health"
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s

    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

  remnawave-db:
    image: postgres:18.4
    container_name: remnawave-db
    hostname: remnawave-db

    shm_size: 512mb

    <<: [*common, *logging]

    # 不引用 .env。数据库只需要这三个变量，显式声明，
    # 用户名与库名写死为 postgres，与 DATABASE_URL 保持一致。
    environment:
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?POSTGRES_PASSWORD 未在 .env 中设置}
      TZ: UTC

    ports:
      - "127.0.0.1:6767:5432"

    volumes:
      - remnawave-db-data:/var/lib/postgresql

    # 健康检查写死用户名与库名，走 Unix socket，不依赖环境变量展开。
    # 超时上限 30s + 20*5s ≈ 130s，留给 EC2 小机型跑 initdb。
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "pg_isready -U postgres -d postgres"
        ]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 30s

  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis

    <<: [*common, *logging]

    volumes:
      - valkey-socket:/var/run/valkey

    command:
      - valkey-server
      - --save
      - ""
      - --appendonly
      - "no"
      - --maxmemory-policy
      - noeviction
      - --loglevel
      - warning
      - --unixsocket
      - /var/run/valkey/valkey.sock
      - --unixsocketperm
      - "777"
      - --port
      - "0"

    healthcheck:
      test:
        [
          "CMD",
          "valkey-cli",
          "-s",
          "/var/run/valkey/valkey.sock",
          "ping"
        ]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 5s

networks:
  remnawave-network:
    name: remnawave-network
    external: true

volumes:
  remnawave-db-data:
    name: remnawave-db-data
    driver: local
    external: false

  valkey-socket:
    name: valkey-socket
    driver: local
    external: false
EOF

# ============================================================
# 14. 写入 .env
# ============================================================

echo
echo ">>> 写入 .env 配置..."

# 用 awk 整行重写而不是 sed，避免 value 里的 & | \ / 被当成特殊字符。
# 同一个 key 出现多次时只保留第一条。追加前先补换行。
set_env() {
    local key="$1"
    local value="$2"
    local file="${INSTALL_DIR}/.env"
    local tmp="${file}.tmp"

    ensure_trailing_newline "${file}"

    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "${file}"; then
        # 正则用 [ \t] 而不是 [[:space:]]，兼容 Ubuntu 默认的 mawk
        awk -v k="${key}" -v v="${value}" '
            $0 ~ ("^[ \t]*#?[ \t]*" k "=") {
                if (!seen) { print k "=" v; seen = 1 }
                next
            }
            { print }
        ' "${file}" > "${tmp}"
        mv "${tmp}" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi

    chmod 600 "${file}"
}

get_env() {
    local key="$1"
    grep -E "^${key}=" "${INSTALL_DIR}/.env" | head -n 1 | cut -d= -f2- || true
}

# 全部用十六进制，不含会干扰 awk / Compose 插值的字符
APP_SECRET="$(openssl rand -hex 64)"
METRICS_PASS="$(openssl rand -hex 32)"
WEBHOOK_SECRET_HEADER="$(openssl rand -hex 32)"   # 必须正好 64 个字符
POSTGRES_PASSWORD="$(openssl rand -hex 24)"

set_env "APP_SECRET"            "${APP_SECRET}"
set_env "METRICS_PASS"          "${METRICS_PASS}"
set_env "WEBHOOK_SECRET_HEADER" "${WEBHOOK_SECRET_HEADER}"

set_env "POSTGRES_USER"     "${PG_USER}"
set_env "POSTGRES_DB"       "${PG_DB}"
set_env "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
set_env "DATABASE_URL"      "\"postgresql://${PG_USER}:${POSTGRES_PASSWORD}@remnawave-db:5432/${PG_DB}\""

# FRONT_END_DOMAIN 用于 CORS；SUB_PUBLIC_DOMAIN 不带 http/https，结尾不带 /
set_env "FRONT_END_DOMAIN"   "${MAIN_DOMAIN}"
set_env "PANEL_DOMAIN"       "${MAIN_DOMAIN}"
set_env "SUB_PUBLIC_DOMAIN"  "${SUB_DOMAIN}/api/sub"

echo "FRONT_END_DOMAIN=${MAIN_DOMAIN}"
echo "PANEL_DOMAIN=${MAIN_DOMAIN}"
echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub"

# ============================================================
# 15. 校验 .env
#
# 起容器前检查取值格式和重复定义，避免建出坏数据库。
# ============================================================

echo
echo ">>> 校验 .env ..."

ENV_OK="yes"

check_env_value() {
    local key="$1"
    local pattern="$2"
    local actual
    actual="$(get_env "${key}")"

    if [ -z "${actual}" ]; then
        echo "  ERROR: ${key} 为空"
        ENV_OK="no"
        return
    fi

    if ! [[ "${actual}" =~ ${pattern} ]]; then
        echo "  ERROR: ${key} 取值异常: ${actual}"
        ENV_OK="no"
        return
    fi

    echo "  OK: ${key}"
}

check_env_value "POSTGRES_USER"     '^[A-Za-z0-9_]+$'
check_env_value "POSTGRES_DB"       '^[A-Za-z0-9_]+$'
check_env_value "POSTGRES_PASSWORD" '^[A-Za-z0-9]+$'
check_env_value "APP_SECRET"        '^[A-Za-z0-9]+$'
check_env_value "PANEL_DOMAIN"      '^[A-Za-z0-9.-]+$'
check_env_value "SUB_PUBLIC_DOMAIN" '^[A-Za-z0-9./-]+$'

# 同名变量出现多次时后面的会覆盖前面的
for k in POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD DATABASE_URL \
         PANEL_DOMAIN SUB_PUBLIC_DOMAIN FRONT_END_DOMAIN; do
    cnt="$(grep -cE "^${k}=" "${INSTALL_DIR}/.env" || true)"
    if [ "${cnt}" -gt 1 ]; then
        echo "  ERROR: ${k} 在 .env 中出现了 ${cnt} 次"
        ENV_OK="no"
    fi
done

if [ "${ENV_OK}" != "yes" ]; then
    echo
    echo "ERROR: .env 校验未通过，已中止。"
    echo "请检查: ${INSTALL_DIR}/.env"
    exit 1
fi

echo "OK: .env 校验通过。"

echo
echo ">>> 校验 Remnawave Compose ..."

cd "${INSTALL_DIR}"
docker compose config >/dev/null
echo "OK: docker-compose.yml"

# ============================================================
# 16. 启动 PostgreSQL 与 Valkey
#
# 先起数据库并等健康，再起后端，这样数据库出问题能直接看到它的日志。
# ============================================================

echo
echo ">>> 启动 PostgreSQL 与 Valkey ..."

docker compose up -d remnawave-db remnawave-redis

container_state() {
    docker inspect -f \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$1" 2>/dev/null || true
}

echo ">>> 等待数据库就绪（最多 180 秒）..."

DB_READY="no"

for i in $(seq 1 90); do
    db_status="$(container_state remnawave-db)"
    redis_status="$(container_state remnawave-redis)"

    if [ "${db_status}" = "healthy" ] && [ "${redis_status}" = "healthy" ]; then
        DB_READY="yes"
        break
    fi

    if [ "${db_status}" = "unhealthy" ]; then
        break
    fi

    sleep 2
done

if [ "${DB_READY}" != "yes" ]; then
    echo
    echo "ERROR: PostgreSQL / Valkey 未能就绪。"
    echo "  remnawave-db    : $(container_state remnawave-db)"
    echo "  remnawave-redis : $(container_state remnawave-redis)"
    echo
    echo "----- remnawave-db 容器环境变量 -----"
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' remnawave-db \
        | grep -E '^POSTGRES_' || true
    echo
    echo "----- remnawave-db 健康检查输出 -----"
    docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' remnawave-db 2>/dev/null || true
    echo
    echo "----- remnawave-db 日志 -----"
    docker compose logs --tail=120 remnawave-db || true
    echo
    echo "----- remnawave-redis 日志 -----"
    docker compose logs --tail=40 remnawave-redis || true
    exit 1
fi

echo "OK: PostgreSQL 与 Valkey 已就绪。"

# ============================================================
# 17. 启动 Remnawave 后端
# ============================================================

echo
echo ">>> 启动 Remnawave 后端 ..."

docker compose up -d

APP_READY="no"

for i in $(seq 1 90); do
    app_running="$(docker inspect -f '{{.State.Running}}' remnawave 2>/dev/null || true)"

    # 容器在跑还不够，等 /health 真正返回 200
    if [ "${app_running}" = "true" ]; then
        if curl -fsS --max-time 5 "http://127.0.0.1:3001/health" >/dev/null 2>&1; then
            APP_READY="yes"
            break
        fi
    fi

    sleep 2
done

if [ "${APP_READY}" != "yes" ]; then
    echo
    echo "ERROR: Remnawave 后端未能就绪。"
    docker compose ps
    echo
    docker compose logs --tail=150 remnawave || true
    exit 1
fi

echo "OK: Remnawave 后端已就绪（/health 正常）。"

if ! container_in_network remnawave; then
    echo "ERROR: remnawave 未接入 ${NETWORK_NAME}。"
    docker network inspect "${NETWORK_NAME}" || true
    exit 1
fi

echo "OK: remnawave 已接入 ${NETWORK_NAME}"

# ============================================================
# 18. 自签名引导证书
#
# Nginx 的 HTTPS server 必须有证书才能启动，而 ACME 校验又要先有
# Nginx 的分流层才能通过。先放一张自签证书，拿到正式证书后覆盖。
# ============================================================

echo
echo ">>> 生成自签名引导证书 ..."

if [ ! -s "${CERT_DIR}/fullchain.pem" ] || [ ! -s "${CERT_DIR}/privkey.key" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "${CERT_DIR}/privkey.key" \
        -out    "${CERT_DIR}/fullchain.pem" \
        -subj   "/CN=${MAIN_DOMAIN}" >/dev/null 2>&1
    echo "OK: 引导证书已生成。"
else
    echo "OK: 已存在证书文件，跳过。"
fi

# 容器内 nginx 以 nginx 用户读取，需要 644
chmod 644 "${CERT_DIR}/privkey.key" "${CERT_DIR}/fullchain.pem"

# ============================================================
# 19. 生成 Nginx 主配置
#
# stream 块只能写在主配置顶层，不能放进 conf.d，
# 所以直接替换容器的 /etc/nginx/nginx.conf。
# ============================================================

echo
echo ">>> 生成 Nginx 配置（含 SNI 分流）..."

SERVER_NAMES="${DOMAIN_LIST[*]}"

# stream 层的 SNI 映射：面板 / 订阅域名 -> 容器内 HTTPS
SNI_MAP_ENTRIES=""
for d in "${DOMAIN_LIST[@]}"; do
    SNI_MAP_ENTRIES+="        ${d}  127.0.0.1:${INTERNAL_HTTPS_PORT};
"
done

# 同机节点的位置：面板里创建好节点后，来这里加一行把它的域名指向 Xray
SNI_MAP_ENTRIES+="
        # ---- 同机节点在此加行 ----
        # 面板 Nodes -> Management 建好节点、Hosts 里定好客户端用的域名后，
        # 把该域名解析到本机，然后在这里加一行指向 Xray 的监听地址，例如：
        #     n1.example.com  172.17.0.1:8444;
        # remnanode 若接入了 ${NETWORK_NAME}，直接写 容器名:端口。
        # Xray 入站需开 \"acceptProxyProtocol\": true。
        # 走 TLS（非 Reality）还要把该域名签进证书，命令见安装结束时的输出。
"

# 用 cat > 原地覆盖以保持 inode 不变，容器里的 bind mount 才能看到新内容。
# 不要用 mv 或 sed -i。
cat > "${NGINX_DIR}/nginx.conf" <<EOF
# ============================================================
# Remnawave Nginx 主配置（由安装脚本生成）
#
#   公网 :80   -> http 层，ACME HTTP-01 + 跳转 HTTPS
#   公网 :443  -> stream 层，ssl_preread 按 ALPN/SNI 分流
#   内部 :${INTERNAL_HTTPS_PORT} -> http 层，面板 HTTPS，接收 PROXY 协议
#   内部 :${ACME_RELAY_PORT} -> stream 层，剥离 PROXY 头后转宿主机 acme.sh
# ============================================================

user  nginx;
worker_processes  auto;
worker_rlimit_nofile 65535;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections 8192;
}

# ============================================================
# HTTP 层
# ============================================================
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" "\$http_user_agent"';

    access_log  /var/log/nginx/access.log main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;
    server_tokens   off;
    client_max_body_size 100m;

    # WebSocket 升级头：只有 WS 请求才发 Connection: upgrade
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    upstream remnawave {
        server remnawave:3000;
    }

    # 公网 80：ACME HTTP-01 校验 + 跳转 HTTPS
    server {
        listen 80;
        server_name ${SERVER_NAMES};

        location /.well-known/acme-challenge/ {
            root /var/www/acme;
            default_type "text/plain";
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    # 非本站域名的 80 请求直接断开
    server {
        listen 80 default_server;
        server_name _;

        location /.well-known/acme-challenge/ {
            root /var/www/acme;
            default_type "text/plain";
        }

        location / {
            return 444;
        }
    }

    # 内部 ${INTERNAL_HTTPS_PORT}：面板 / 订阅 HTTPS，只监听容器内 127.0.0.1
    server {
        listen 127.0.0.1:${INTERNAL_HTTPS_PORT} ssl proxy_protocol;
        http2 on;

        server_name ${SERVER_NAMES};

        # 从 stream 层的 PROXY 头取真实客户端 IP
        set_real_ip_from 127.0.0.1;
        real_ip_header   proxy_protocol;

        ssl_certificate         /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key     /etc/nginx/ssl/privkey.key;
        ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 1d;
        ssl_session_cache shared:MozSSL:10m;
        ssl_session_tickets off;

        location / {
            proxy_http_version 1.1;
            proxy_pass http://remnawave;

            proxy_set_header Host              \$host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Host  \$host;

            proxy_set_header Upgrade    \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;

            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
        }

        gzip on;
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 6;
        gzip_min_length 256;

        gzip_types
            application/atom+xml
            application/geo+json
            application/javascript
            application/json
            application/ld+json
            application/manifest+json
            application/rdf+xml
            application/rss+xml
            application/xhtml+xml
            application/xml
            image/svg+xml
            text/css
            text/javascript
            text/plain
            text/xml;
    }

    # 未知 SNI 落到这里，直接拒绝 TLS 握手
    server {
        listen 127.0.0.1:${INTERNAL_HTTPS_PORT} ssl proxy_protocol default_server;
        server_name _;

        ssl_reject_handshake on;
    }
}

# ============================================================
# STREAM 层：公网 443 的总入口
# ssl_preread 只读 TLS 握手里的 SNI 和 ALPN，不解密、不终止 TLS
# ============================================================
stream {
    log_format stream_main '\$remote_addr [\$time_local] '
                           'sni="\$ssl_preread_server_name" '
                           'alpn="\$ssl_preread_alpn_protocols" '
                           '-> \$stream_target \$status '
                           '\$bytes_sent/\$bytes_received \$session_time';

    access_log /dev/stdout stream_main;

    # 按 SNI 选后端
    map \$ssl_preread_server_name \$sni_target {
${SNI_MAP_ENTRIES}
        # 未知域名送到 default_server 去拒绝握手
        default  127.0.0.1:${INTERNAL_HTTPS_PORT};
    }

    # ALPN 是 acme-tls/1 的走 ACME 中转，其余按 SNI 走
    map \$ssl_preread_alpn_protocols \$stream_target {
        ~\bacme-tls/1\b  127.0.0.1:${ACME_RELAY_PORT};
        default          \$sni_target;
    }

    server {
        listen 443 reuseport;

        ssl_preread on;

        # 给后端带 PROXY 头以保留真实客户端 IP。
        # Xray 入站需要开 "acceptProxyProtocol": true 才能接。
        proxy_protocol on;

        proxy_pass \$stream_target;

        proxy_connect_timeout 5s;
        proxy_timeout 3600s;
    }

    # ACME 中转：剥掉 PROXY 头后交给宿主机的 acme.sh，
    # acme.sh 的 socat 监听不认 PROXY 协议。
    server {
        listen 127.0.0.1:${ACME_RELAY_PORT} proxy_protocol;

        proxy_pass host.docker.internal:${ACME_TLS_PORT};

        proxy_connect_timeout 5s;
        proxy_timeout 60s;
    }
}
EOF

echo "OK: Nginx 配置已生成。"

# ============================================================
# 20. 生成 Nginx 的 docker-compose.yml
#
# 挂主配置 /etc/nginx/nginx.conf（需要 stream 块）。
# 证书和校验目录挂目录不挂单个文件，挂不存在的文件 Docker 会建成目录。
# extra_hosts 让容器能访问宿主机上的 acme.sh。
# cap_drop ALL 后补回 CHOWN/SETGID/SETUID/DAC_OVERRIDE，nginx 需要它们降权 worker。
# ============================================================

echo
echo ">>> 生成 Nginx docker-compose.yml ..."

cat > "${NGINX_DIR}/docker-compose.yml" <<'EOF'
services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always

    security_opt:
      - no-new-privileges:true

    cap_drop:
      - ALL

    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETGID
      - SETUID
      - DAC_OVERRIDE

    extra_hosts:
      - "host.docker.internal:host-gateway"

    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/ssl:ro
      - ./acme-webroot:/var/www/acme:ro

    ports:
      - "0.0.0.0:80:80"
      - "0.0.0.0:443:443"

    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: 3

    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

# ============================================================
# 21. 校验并启动 Nginx
# ============================================================

echo
echo ">>> 检查 Nginx 镜像的 stream_ssl_preread 模块 ..."

NGINX_BUILD_INFO="$(docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 || true)"

if ! str_has "${NGINX_BUILD_INFO}" 'stream_ssl_preread'; then
    echo "ERROR: ${NGINX_IMAGE} 缺少 ngx_stream_ssl_preread_module，无法做 SNI 分流。"
    exit 1
fi

echo "OK: stream_ssl_preread 可用。"

echo
echo ">>> 测试 Nginx 配置 ..."

# 用一次性 docker run 做语法检查。
# 不用 docker compose run：本服务设了 container_name，各版本处理不一致。
docker run --rm --network "${NETWORK_NAME}" \
    -v "${NGINX_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "${CERT_DIR}:/etc/nginx/ssl:ro" \
    -v "${ACME_WEBROOT}:/var/www/acme:ro" \
    --add-host "host.docker.internal:127.0.0.1" \
    "${NGINX_IMAGE}" nginx -t

echo "OK: Nginx 配置有效。"

echo
echo ">>> 启动 Nginx ..."

cd "${NGINX_DIR}"
docker compose up -d

for i in $(seq 1 15); do
    if [ "$(docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null || true)" = "true" ]; then
        break
    fi
    sleep 1
done

if [ "$(docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null || true)" != "true" ]; then
    echo
    echo "ERROR: Nginx 启动失败。"
    docker compose ps
    docker compose logs --tail=100
    exit 1
fi

sleep 2
echo "OK: Nginx 已启动。"

# ============================================================
# 22. 安装 acme.sh
# ============================================================

echo
echo ">>> 安装 acme.sh ..."

export HOME="/root"

if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
fi

ACME_SH="${HOME}/.acme.sh/acme.sh"

if [ ! -x "${ACME_SH}" ]; then
    echo "ERROR: acme.sh 安装失败。"
    exit 1
fi

# 默认 CA 换成 Let's Encrypt，避免 ZeroSSL 的账号 / EAB 问题
"${ACME_SH}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
"${ACME_SH}" --register-account -m "${EMAIL}" --server letsencrypt >/dev/null 2>&1 || true

systemctl enable --now cron >/dev/null 2>&1 || true

# ============================================================
# 23. 签发证书
#
# 主方案 TLS-ALPN-01：acme.sh 监听宿主机 8443，stream 层按 ALPN 转发。
# 备用方案 HTTP-01 webroot：走 80 端口。
# 两种方式 acme.sh 都会记住，续期时复用，不需要停 Nginx。
# ============================================================

echo
echo ">>> 签发 SSL 证书 ..."

CERT_ARGS=()
for d in "${DOMAIN_LIST[@]}"; do
    CERT_ARGS+=(-d "${d}")
done

echo "证书域名: ${DOMAIN_LIST[*]}"

ACME_METHOD=""

echo
echo ">>> [1/2] TLS-ALPN-01（--alpn --tlsport ${ACME_TLS_PORT}）..."

set +e
"${ACME_SH}" \
    --issue \
    "${CERT_ARGS[@]}" \
    --alpn \
    --tlsport "${ACME_TLS_PORT}" \
    --server letsencrypt \
    --keylength 2048
ACME_RC=$?
set -e

# 0=签发成功，2=证书未到期已跳过，都算通过
if [ "${ACME_RC}" -eq 0 ] || [ "${ACME_RC}" -eq 2 ]; then
    ACME_METHOD="tls-alpn-01 (port ${ACME_TLS_PORT})"
else
    echo
    echo "WARNING: TLS-ALPN-01 失败（返回码 ${ACME_RC}），回退 HTTP-01。"
    echo
    echo ">>> [2/2] HTTP-01 webroot（80 端口）..."

    set +e
    "${ACME_SH}" \
        --issue \
        "${CERT_ARGS[@]}" \
        --webroot "${ACME_WEBROOT}" \
        --server letsencrypt \
        --keylength 2048
    ACME_RC=$?
    set -e

    if [ "${ACME_RC}" -eq 0 ] || [ "${ACME_RC}" -eq 2 ]; then
        ACME_METHOD="http-01 webroot (port 80)"
    fi
fi

if [ -z "${ACME_METHOD}" ]; then
    echo
    echo "ERROR: SSL 证书签发失败（两种方式都没成功，最后返回码 ${ACME_RC}）。"
    echo
    echo "常见原因："
    echo "  1) 域名 A 记录未指向本机公网 IP: ${PUBLIC_IP:-未知}"
    echo "  2) AWS 安全组未放行 TCP 80 / 443"
    echo "  3) Cloudflare 开了小黄云代理（需切换为 DNS only）"
    echo "  4) 节点域名填了但没解析到本机，会拖累整张证书"
    echo "  5) 达到 Let's Encrypt 频率限制（同一组域名每周 5 次）"
    echo
    echo "acme.sh 日志: ${HOME}/.acme.sh/acme.sh.log"
    echo "Nginx  日志: docker logs remnawave-nginx"
    exit 1
fi

echo
echo "OK: 证书签发成功，校验方式 = ${ACME_METHOD}"

# ============================================================
# 24. 安装证书并配置自动续期
#
# reloadcmd 在每次续期后修正权限并热重载 Nginx，不停机。
# ============================================================

echo
echo ">>> 安装证书并配置自动续期 ..."

"${ACME_SH}" \
    --install-cert \
    -d "${MAIN_DOMAIN}" \
    --key-file       "${CERT_DIR}/privkey.key" \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --reloadcmd      "chmod 644 ${CERT_DIR}/privkey.key ${CERT_DIR}/fullchain.pem; docker exec remnawave-nginx nginx -s reload"

if [ ! -s "${CERT_DIR}/fullchain.pem" ] || [ ! -s "${CERT_DIR}/privkey.key" ]; then
    echo "ERROR: 证书文件未生成。"
    ls -la "${CERT_DIR}" || true
    exit 1
fi

chmod 644 "${CERT_DIR}/privkey.key" "${CERT_DIR}/fullchain.pem"

CERT_ISSUER="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -issuer 2>/dev/null || true)"
CERT_SUBJECT="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -subject 2>/dev/null || true)"
CERT_DATES="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -dates 2>/dev/null || true)"
CERT_SANS="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n' || true)"

echo "签发者: ${CERT_ISSUER}"
echo "有效期: ${CERT_DATES}"
echo "覆盖域名: ${CERT_SANS}"

# 自签证书的 issuer 与 subject 相同，据此判断正式证书是否装上。
# 不比对 "CN=域名" 字样：不同 OpenSSL 版本打印成 CN=x 或 CN = x，不可靠。
if [ "${CERT_ISSUER#issuer=}" = "${CERT_SUBJECT#subject=}" ]; then
    echo "ERROR: 当前仍是自签名引导证书，正式证书没有装上。"
    exit 1
fi

# 逐个确认域名都在证书 SAN 里（CERT_SANS 形如 DNS:a.com,DNS:b.com）
for d in "${DOMAIN_LIST[@]}"; do
    if str_has ",${CERT_SANS}," ",DNS:${d},"; then
        echo "  OK: ${d} 已在证书内"
    else
        echo "  WARNING: ${d} 不在证书 SAN 内"
    fi
done

docker exec remnawave-nginx nginx -s reload
sleep 2

echo "OK: 正式证书已安装，自动续期已配置。"

# ============================================================
# 25. 连通性测试
# ============================================================

echo
echo ">>> 测试 Docker DNS: Nginx -> Remnawave ..."

docker exec remnawave-nginx getent hosts remnawave
echo "OK: Docker DNS 解析正常。"

echo
echo ">>> 校验两个容器在同一网络 ..."

for c in remnawave remnawave-nginx; do
    if ! container_in_network "${c}"; then
        echo "ERROR: ${NETWORK_NAME} 中缺少 ${c}。"
        docker network inspect "${NETWORK_NAME}" || true
        exit 1
    fi
done

echo "OK: 两个容器共用 ${NETWORK_NAME}"

echo
echo ">>> 测试 Nginx -> Remnawave 连通性 ..."

if ! docker exec remnawave-nginx \
        wget -q -O /dev/null --timeout=10 "http://remnawave:3000/"; then
    echo
    echo "ERROR: Nginx 无法访问 Remnawave。"
    docker logs --tail=50 remnawave || true
    docker logs --tail=50 remnawave-nginx || true
    exit 1
fi

echo "OK: Nginx 可以访问 Remnawave。"

echo
echo ">>> 面板 HTTPS 测试（走完整分流链路，校验证书链）..."

# 不加 -k：证书链、SNI 分流、PROXY 协议任一环出错都会失败
if curl -fsSI --max-time 15 \
    --resolve "${MAIN_DOMAIN}:443:127.0.0.1" \
    "https://${MAIN_DOMAIN}/" >/dev/null; then
    echo "OK: 面板 HTTPS 正常。"
else
    echo
    echo "ERROR: 面板 HTTPS 测试失败。"
    docker logs --tail=100 remnawave-nginx || true
    exit 1
fi

if [ "${SAME_DOMAIN}" = "no" ]; then
    echo
    echo ">>> 订阅域名 HTTPS 测试 ..."
    if curl -fsSI --max-time 15 \
        --resolve "${SUB_DOMAIN}:443:127.0.0.1" \
        "https://${SUB_DOMAIN}/" >/dev/null; then
        echo "OK: 订阅域名 HTTPS 正常。"
    else
        echo "WARNING: 订阅域名 HTTPS 未通过，请检查其 DNS 解析。"
    fi
fi

echo
echo ">>> 未知 SNI 拒绝测试 ..."

if curl -sI --max-time 10 -k \
    --resolve "unknown-sni-test.invalid:443:127.0.0.1" \
    "https://unknown-sni-test.invalid/" >/dev/null 2>&1; then
    echo "WARNING: 未知 SNI 没有被拒绝。"
else
    echo "OK: 未知 SNI 已被拒绝握手。"
fi

echo
echo ">>> HTTP -> HTTPS 跳转测试 ..."

REDIRECT_HEAD="$(curl -sSI --max-time 15 \
    --resolve "${MAIN_DOMAIN}:80:127.0.0.1" \
    "http://${MAIN_DOMAIN}/" 2>/dev/null || true)"

if str_has "${REDIRECT_HEAD}" " 301 " || str_has "${REDIRECT_HEAD}" " 302 "; then
    echo "OK: HTTP 已跳转 HTTPS。"
else
    echo "WARNING: HTTP 跳转未返回 301/302。"
fi

# ============================================================
# 26. 输出结果
# ============================================================

echo
echo "============================================================"
echo "                    安装完成"
echo "============================================================"
echo

echo "🎛️  面板地址:"
echo "    https://${MAIN_DOMAIN}"

echo
echo "💌 订阅地址:"
echo "    https://${SUB_DOMAIN}/api/sub"
if [ "${SAME_DOMAIN}" = "yes" ]; then
    echo "    （与面板共用同一域名）"
fi

echo
echo "🔐 证书:"
echo "    校验方式 : ${ACME_METHOD}"
echo "    证书文件 : ${CERT_DIR}/fullchain.pem"
echo "    私钥文件 : ${CERT_DIR}/privkey.key"
echo "    覆盖域名 : ${DOMAIN_LIST[*]}"
echo "    ${CERT_DATES}"
echo "    自动续期 : acme.sh cron，续期后自动 reload Nginx，不停机"

echo
echo "🐳 容器状态:"
docker ps \
    --filter name=remnawave \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "🔌 端口:"
echo "    公网 80    Nginx HTTP（ACME 校验 + 跳转）"
echo "    公网 443   Nginx stream 分流（面板 / 订阅 / 节点）"
echo "    宿主 ${ACME_TLS_PORT}  acme.sh TLS-ALPN-01（仅签发续期时占用）"
echo "    容器 ${INTERNAL_HTTPS_PORT}  面板 HTTPS"
echo "    容器 ${ACME_RELAY_PORT} ACME PROXY 剥离中转"
echo "    本机 3000/3001/6767  Remnawave / 指标 / PostgreSQL"

echo
echo "============================================================"
echo "              🛰️  接入 VPN 节点"
echo "============================================================"
echo
echo "节点不在本脚本里配置，全部在面板 UI 完成："
echo "    1) 浏览器打开 https://${MAIN_DOMAIN} 创建管理员账号"
echo "    2) Nodes -> Management -> Create new node"
echo "       填 Country / Internal name / Address / Port(默认 2222)"
echo "    3) 面板会生成一段 docker-compose.yml，拷到节点服务器上："
echo "         mkdir -p /opt/remnanode && cd /opt/remnanode"
echo "         nano docker-compose.yml   # 粘贴面板给的内容"
echo "         docker compose up -d"
echo "    4) 回面板点 Create 完成，并选一个 Config Profile"
echo "    5) Hosts 里新建 Host，Address 填客户端要连的域名，"
echo "       需要时用 SNI 覆盖 serverNames —— 这里才是「节点域名」"
echo
echo "  Address 里的域名解析到节点服务器的 IP，与本机面板域名无关。"
echo "  NODE_PORT(2222) 只在面板和节点之间用，防火墙上只放行面板 IP。"
echo
echo "【节点在另一台机器】本机不用做任何改动。"
echo
echo "【节点和面板同一台机器，共用 443】还需要三步："
echo "    a) 把节点域名解析到 ${PUBLIC_IP:-本机公网IP}"
echo "    b) 走 TLS（非 Reality）时把它签进证书："
echo "         ${ACME_SH} --issue -d ${MAIN_DOMAIN} -d <节点域名> \\"
echo "           --alpn --tlsport ${ACME_TLS_PORT} --server letsencrypt"
echo "         证书路径 ${CERT_DIR}/  后端容器内 /var/lib/remnawave/configs/xray/ssl/"
echo "         Reality(self-steal) 不需要证书，跳过这步"
echo "    c) 编辑 ${NGINX_DIR}/nginx.conf，在 stream 的 sni_target"
echo "       「同机节点在此加行」处加一行，然后 reload："
echo "         <节点域名>  172.17.0.1:8444;"
echo "         docker exec remnawave-nginx nginx -t && \\"
echo "         docker exec remnawave-nginx nginx -s reload"
echo "       Xray 入站要开 \"acceptProxyProtocol\": true（stream 层带 PROXY 头）"
echo
echo "  加这一行之前，除面板域名外的所有 SNI 都会被拒绝握手。"

echo
echo "============================================================"
echo "                    常用命令"
echo "============================================================"
echo

echo "🎛️  Remnawave:"
echo "    cd ${INSTALL_DIR} && docker compose ps"
echo "    cd ${INSTALL_DIR} && docker compose logs -f remnawave"
echo "    cd ${INSTALL_DIR} && docker compose restart"

echo
echo "🪽 Nginx:"
echo "    docker exec remnawave-nginx nginx -t"
echo "    docker exec remnawave-nginx nginx -s reload"
echo "    配置文件: ${NGINX_DIR}/nginx.conf"
echo "    看 SNI 分流: docker logs -f remnawave-nginx | grep sni="

echo
echo "🩺 健康检查:"
echo "    curl -fsS http://127.0.0.1:3001/health"
echo "    docker ps"

echo
echo "🗄️  数据库:"
echo "    docker exec -it remnawave-db psql -U ${PG_USER} -d ${PG_DB}"
echo "    docker exec remnawave-db pg_dump -U ${PG_USER} ${PG_DB} > /root/remnawave-backup.sql"

echo
echo "🔐 SSL:"
echo "    ${ACME_SH} --list"
echo "    ${ACME_SH} --renew -d ${MAIN_DOMAIN} --force"
echo "    openssl x509 -in ${CERT_DIR}/fullchain.pem -noout -dates -issuer"

echo
echo "⚙️  修改 .env 后:"
echo "    cd ${INSTALL_DIR} && docker compose down && docker compose up -d"

echo
echo "🗑️  完全卸载:"
echo "    cd ${INSTALL_DIR} && docker compose down -v --remove-orphans; \\"
echo "    cd ${NGINX_DIR} && docker compose down -v --remove-orphans; \\"
echo "    docker rm -f remnawave remnawave-db remnawave-redis remnawave-nginx; \\"
echo "    docker volume rm -f remnawave-db-data valkey-socket; \\"
echo "    docker network rm ${NETWORK_NAME}; \\"
echo "    rm -rf ${INSTALL_DIR}"

echo
echo "============================================================"
echo "  首次访问面板时会要求创建管理员账号，请立即创建。"
echo "============================================================"
echo
