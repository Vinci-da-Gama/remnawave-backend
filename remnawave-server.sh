#!/usr/bin/env bash

# ============================================================
# Remnawave + Nginx + SSL
# Ubuntu / Debian / AWS EC2
#
# Requirements:
#   - Panel domain is REQUIRED.
#   - Subscription domain is OPTIONAL; blank means disabled.
#   - AWS Security Group: TCP 80, 443, 8443.
#
# Architecture:
#   Internet -> Nginx :80/:443 -> Remnawave :3000
#   Remnawave -> PostgreSQL + Valkey
#
# IMPORTANT:
#   - Remnawave 3000/3001 are bound to localhost only.
#   - The Docker network is explicitly external/shared.
#   - No ${NGINX_DIR} interpolation is used in docker-compose.yml.
# ============================================================

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="${INSTALL_DIR}/nginx"
NETWORK_NAME="remnawave-network"

# ------------------------------------------------------------
# Graceful Ctrl+C / termination
# ------------------------------------------------------------
stopped_by_user() {
    echo
    echo "process will be stopped."
    exit 130
}
trap stopped_by_user INT TERM

# ------------------------------------------------------------
# Error handler
# ------------------------------------------------------------
on_error() {
    local line="${1:-unknown}"
    echo
    echo "ERROR: installation failed at line ${line}."
    echo
    echo "Useful diagnostics:"
    echo "  cd ${INSTALL_DIR} 2>/dev/null && docker compose ps"
    echo "  cd ${INSTALL_DIR} 2>/dev/null && docker compose logs --tail=100"
    echo "  cd ${NGINX_DIR} 2>/dev/null && docker compose ps"
    echo "  cd ${NGINX_DIR} 2>/dev/null && docker compose logs --tail=100"
    exit 1
}
trap 'on_error $LINENO' ERR

echo
echo "============================================================"
echo "        Remnawave + Nginx + SSL Installer"
echo "============================================================"
echo

# ============================================================
# 0. ROOT
# ============================================================

if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: Please run as root."
    echo "Use: sudo bash $0"
    exit 1
fi

# ============================================================
# 1. OS
# ============================================================

if [ ! -f /etc/os-release ]; then
    echo "ERROR: Cannot detect operating system."
    exit 1
fi

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        echo "ERROR: This script supports Ubuntu/Debian only."
        echo "Detected: ${PRETTY_NAME:-unknown}"
        exit 1
        ;;
esac

echo "OK: ${PRETTY_NAME:-$ID}"

# ============================================================
# 2. CONFIG
# ============================================================

echo
read -rp "Panel domain (REQUIRED): " MAIN_DOMAIN

if [ -z "${MAIN_DOMAIN}" ]; then
    echo
    echo "Panel domain is required."
    echo "No panel domain was provided. Exiting gracefully."
    exit 0
fi

read -rp "Subscription domain (OPTIONAL, press Enter to skip): " SUB_DOMAIN

read -rp "SSL email (REQUIRED): " EMAIL

if [ -z "${EMAIL}" ]; then
    echo
    echo "SSL email is required."
    echo "No email was provided. Exiting gracefully."
    exit 0
fi

# ============================================================
# 3. DOMAIN VALIDATION
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
    echo "ERROR: Invalid panel domain: ${MAIN_DOMAIN}"
    exit 1
fi

if [ -n "${SUB_DOMAIN}" ] && ! validate_domain "${SUB_DOMAIN}"; then
    echo "ERROR: Invalid subscription domain: ${SUB_DOMAIN}"
    exit 1
fi

echo
echo "------------------------------------------------------------"
echo "Panel        : ${MAIN_DOMAIN}"
if [ -n "${SUB_DOMAIN}" ]; then
    echo "Subscription : ${SUB_DOMAIN}"
else
    echo "Subscription : disabled"
fi
echo "SSL email    : ${EMAIL}"
echo "------------------------------------------------------------"
echo

# ============================================================
# 4. DEPENDENCIES
# ============================================================

echo ">>> Installing dependencies..."

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
# 5. DOCKER
# ============================================================

echo
echo ">>> Checking Docker..."

if ! command -v docker >/dev/null 2>&1; then
    echo ">>> Installing Docker..."
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose plugin is unavailable."
    exit 1
fi

echo "Docker : $(docker --version)"
echo "Compose: $(docker compose version)"

# ============================================================
# 6. DNS CHECK
# ============================================================

echo
echo ">>> Checking DNS..."

resolve_domain() {
    local domain="$1"

    echo
    echo "Domain: ${domain}"

    if ! getent ahostsv4 "${domain}" >/dev/null 2>&1; then
        echo "WARNING: ${domain} does not currently resolve via IPv4."
        echo "Make sure its A record points to this EC2 public IPv4."
        return 0
    fi

    getent ahostsv4 "${domain}" | awk '{print $1}' | sort -u
}

resolve_domain "${MAIN_DOMAIN}"

if [ -n "${SUB_DOMAIN}" ]; then
    resolve_domain "${SUB_DOMAIN}"
fi

echo
echo "IMPORTANT:"
echo "The panel domain must point to this EC2 public IPv4."
if [ -n "${SUB_DOMAIN}" ]; then
    echo "The subscription domain must also point to this EC2 public IPv4."
fi

# ============================================================
# 7. PORT CHECK
# ============================================================

echo
echo ">>> Checking local ports..."

for port in 80 443 8443; do
    if ss -lnt 2>/dev/null | grep -qE "([[:space:]:])${port}[[:space:]]"; then
        echo "ERROR: TCP ${port} is already occupied."
        ss -lntp | grep ":${port}" || true
        exit 1
    fi
    echo "OK: ${port} is free"
done

# ============================================================
# 8. PREPARE DIRECTORIES
# ============================================================

echo
echo ">>> Preparing ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"
mkdir -p "${NGINX_DIR}"
cd "${INSTALL_DIR}"

# ============================================================
# 9. DOWNLOAD OFFICIAL ENV SAMPLE
# ============================================================

echo
echo ">>> Downloading official Remnawave environment sample..."

curl -fsSL \
    -o "${INSTALL_DIR}/.env" \
    "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

if [ ! -s "${INSTALL_DIR}/.env" ]; then
    echo "ERROR: .env download failed."
    exit 1
fi

# ============================================================
# 10. DOCKER NETWORK
# ============================================================

echo
echo ">>> Creating Docker network..."

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "OK: Docker network already exists."
else
    docker network create --driver bridge "${NETWORK_NAME}" >/dev/null
    echo "OK: Docker network ${NETWORK_NAME}"
fi

# ============================================================
# 11. REMNAWAVE COMPOSE
#
# IMPORTANT:
# There is deliberately NO ${NGINX_DIR} in this heredoc.
# Docker Compose must not interpolate a host Bash variable.
#
# The host path is inserted literally by Bash below.
# ============================================================

echo
echo ">>> Preparing Remnawave Docker Compose..."

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
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
      - ${NGINX_DIR}/:/var/lib/remnawave/configs/xray/ssl

    ports:
      - "127.0.0.1:3000:\${APP_PORT:-3000}"
      - "127.0.0.1:3001:\${METRICS_PORT:-3001}"

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "curl -f http://localhost:\${METRICS_PORT:-3001}/health"
        ]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 30s

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

    <<: [*common, *logging, *env]

    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      TZ: UTC

    ports:
      - "127.0.0.1:6767:5432"

    volumes:
      - remnawave-db-data:/var/lib/postgresql

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}"
        ]
      interval: 3s
      timeout: 10s
      retries: 10
      start_period: 10s

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
# 12. ENV HELPERS / SECRETS
# ============================================================

echo
echo ">>> Generating secure secrets..."

set_env() {
    local key="$1"
    local value="$2"

    if grep -qE "^${key}=" "${INSTALL_DIR}/.env"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${INSTALL_DIR}/.env"
    elif grep -qE "^#${key}=" "${INSTALL_DIR}/.env"; then
        sed -i "s|^#${key}=.*|${key}=${value}|" "${INSTALL_DIR}/.env"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${INSTALL_DIR}/.env"
    fi
}

JWT_AUTH_SECRET="$(openssl rand -hex 64)"
JWT_API_TOKENS_SECRET="$(openssl rand -hex 64)"
APP_SECRET="$(openssl rand -hex 64)"
METRICS_PASS="$(openssl rand -hex 64)"
WEBHOOK_SECRET_HEADER="$(openssl rand -hex 32)"
POSTGRES_PASSWORD="$(openssl rand -hex 24)"

set_env "JWT_AUTH_SECRET" "${JWT_AUTH_SECRET}"
set_env "JWT_API_TOKENS_SECRET" "${JWT_API_TOKENS_SECRET}"

if grep -qE "^APP_SECRET=|^#APP_SECRET=" "${INSTALL_DIR}/.env"; then
    set_env "APP_SECRET" "${APP_SECRET}"
fi

set_env "METRICS_PASS" "${METRICS_PASS}"
set_env "WEBHOOK_SECRET_HEADER" "${WEBHOOK_SECRET_HEADER}"
set_env "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"

# ============================================================
# 13. DATABASE
# ============================================================

echo
echo ">>> Configuring PostgreSQL..."

DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@remnawave-db:5432/postgres"

if grep -q '^DATABASE_URL=' "${INSTALL_DIR}/.env"; then
    sed -i "s|^DATABASE_URL=.*|DATABASE_URL=\"${DATABASE_URL}\"|" "${INSTALL_DIR}/.env"
else
    printf 'DATABASE_URL="%s"\n' "${DATABASE_URL}" >> "${INSTALL_DIR}/.env"
fi

# ============================================================
# 14. DOMAINS
# ============================================================

echo
echo ">>> Configuring domains..."

set_env "FRONT_END_DOMAIN" "${MAIN_DOMAIN}"
set_env "PANEL_DOMAIN" "${MAIN_DOMAIN}"

if [ -n "${SUB_DOMAIN}" ]; then
    set_env "SUB_PUBLIC_DOMAIN" "${SUB_DOMAIN}/api/sub"
else
    # Do not invent a subscription URL when the user skipped it.
    if grep -qE '^SUB_PUBLIC_DOMAIN=' "${INSTALL_DIR}/.env"; then
        sed -i 's|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=|' "${INSTALL_DIR}/.env"
    elif grep -qE '^#SUB_PUBLIC_DOMAIN=' "${INSTALL_DIR}/.env"; then
        sed -i 's|^#SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=|' "${INSTALL_DIR}/.env"
    else
        printf 'SUB_PUBLIC_DOMAIN=\n' >> "${INSTALL_DIR}/.env"
    fi
fi

echo "FRONT_END_DOMAIN=${MAIN_DOMAIN}"
if [ -n "${SUB_DOMAIN}" ]; then
    echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub"
else
    echo "SUB_PUBLIC_DOMAIN=disabled"
fi
echo "PANEL_DOMAIN=${MAIN_DOMAIN}"

# ============================================================
# 15. VALIDATE COMPOSE
# ============================================================

echo
echo ">>> Validating Remnawave Compose..."

cd "${INSTALL_DIR}"
docker compose config >/dev/null
echo "OK: docker-compose.yml"

# ============================================================
# 16. START REMNAWAVE
# ============================================================

echo
echo ">>> Starting Remnawave..."

docker compose up -d

echo
echo ">>> Waiting for PostgreSQL / Valkey / Remnawave..."

for i in $(seq 1 90); do
    db_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' remnawave-db 2>/dev/null || true)"
    redis_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' remnawave-redis 2>/dev/null || true)"
    app_running="$(docker inspect -f '{{.State.Running}}' remnawave 2>/dev/null || true)"

    if [ "${db_status}" = "healthy" ] &&
       [ "${redis_status}" = "healthy" ] &&
       [ "${app_running}" = "true" ]; then
        echo "OK: Remnawave stack is running."
        break
    fi

    if [ "${db_status}" = "unhealthy" ]; then
        echo
        echo "ERROR: PostgreSQL is unhealthy."
        docker compose ps
        docker compose logs --tail=100 remnawave-db
        exit 1
    fi

    if [ "$i" -eq 90 ]; then
        echo
        echo "ERROR: Remnawave stack did not become ready."
        docker compose ps
        docker compose logs --tail=100
        exit 1
    fi

    sleep 2
done

# ============================================================
# 17. VERIFY NETWORK
# ============================================================

echo
echo ">>> Verifying Remnawave Docker network..."

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave"'; then
    echo "ERROR: remnawave is not connected to ${NETWORK_NAME}."
    docker network inspect "${NETWORK_NAME}" || true
    exit 1
fi

echo "OK: remnawave is connected to ${NETWORK_NAME}"

# ============================================================
# 18. HEALTH CHECK
# ============================================================

echo
echo ">>> Testing Remnawave health endpoint..."

if curl -fsS --max-time 10 \
    "http://127.0.0.1:3001/health" >/dev/null 2>&1; then
    echo "OK: Remnawave health endpoint is responding."
else
    echo "WARNING: Remnawave health endpoint is not ready."
    docker compose ps
fi

# ============================================================
# 19. ACME.SH
# ============================================================

echo
echo ">>> Installing acme.sh..."

export HOME="/root"

if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
    curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"
fi

ACME_SH="${HOME}/.acme.sh/acme.sh"

if [ ! -x "${ACME_SH}" ]; then
    echo "ERROR: acme.sh installation failed."
    exit 1
fi

systemctl enable --now cron >/dev/null 2>&1 || true

# ============================================================
# 20. ISSUE SSL
# ============================================================

echo
echo ">>> Issuing SSL certificate..."

mkdir -p "${NGINX_DIR}"

CERT_ARGS=(-d "${MAIN_DOMAIN}")

if [ -n "${SUB_DOMAIN}" ]; then
    CERT_ARGS+=(-d "${SUB_DOMAIN}")
fi

"${ACME_SH}" \
    --issue \
    --standalone \
    "${CERT_ARGS[@]}" \
    --alpn \
    --tlsport 8443

echo "OK: SSL certificate issued."

# ============================================================
# 21. INSTALL SSL CERTIFICATE
# ============================================================

echo
echo ">>> Installing SSL certificate..."

"${ACME_SH}" \
    --install-cert \
    -d "${MAIN_DOMAIN}" \
    --key-file "${NGINX_DIR}/privkey.key" \
    --fullchain-file "${NGINX_DIR}/fullchain.pem"

chmod 600 "${NGINX_DIR}/privkey.key"
chmod 644 "${NGINX_DIR}/fullchain.pem"

# ============================================================
# 22. NGINX CONFIG
# ============================================================

echo
echo ">>> Creating Nginx configuration..."

SERVER_NAMES="${MAIN_DOMAIN}"
if [ -n "${SUB_DOMAIN}" ]; then
    SERVER_NAMES="${MAIN_DOMAIN} ${SUB_DOMAIN}"
fi

cat > "${NGINX_DIR}/nginx.conf" <<EOF
upstream remnawave {
    server remnawave:3000;
}

server {
    listen 80;
    listen [::]:80;

    server_name ${SERVER_NAMES};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;

    http2 on;

    server_name ${SERVER_NAMES};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.key;
    ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;

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

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    ssl_reject_handshake on;
}
EOF

# ============================================================
# 23. NGINX COMPOSE
#
# IMPORTANT:
# No ${NGINX_DIR} appears here.
# Relative bind mounts are resolved from NGINX_DIR by Compose.
# ============================================================

echo
echo ">>> Creating Nginx Docker Compose..."

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

    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro

    ports:
      - "0.0.0.0:80:80"
      - "0.0.0.0:443:443"

    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    external: true
EOF

# ============================================================
# 24. NGINX TEST
# ============================================================

echo
echo ">>> Testing Nginx configuration..."

cd "${NGINX_DIR}"

docker compose run --rm --no-deps remnawave-nginx nginx -t
echo "OK: Nginx configuration is valid."

# ============================================================
# 25. DOCKER DNS TEST
# ============================================================

echo
echo ">>> Testing Docker DNS: Nginx -> Remnawave..."

docker compose run --rm --no-deps remnawave-nginx \
    getent hosts remnawave

echo "OK: Docker DNS resolves remnawave."

# ============================================================
# 26. START NGINX
# ============================================================

echo
echo ">>> Starting Nginx..."

docker compose up -d
sleep 5

if ! docker inspect \
    -f '{{.State.Running}}' \
    remnawave-nginx 2>/dev/null | grep -q true; then

    echo
    echo "ERROR: Nginx failed to start."
    docker compose ps
    docker compose logs --tail=100
    exit 1
fi

echo "OK: Nginx is running."

# ============================================================
# 27. FINAL NETWORK CHECK
# ============================================================

echo
echo ">>> Verifying final Docker network..."

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave"'; then
    echo "ERROR: remnawave is missing from ${NETWORK_NAME}."
    exit 1
fi

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave-nginx"'; then
    echo "ERROR: remnawave-nginx is missing from ${NETWORK_NAME}."
    exit 1
fi

echo "OK: Both containers share ${NETWORK_NAME}"

# ============================================================
# 28. NGINX -> REMNAWAVE TEST
# ============================================================

echo
echo ">>> Testing Nginx -> Remnawave connectivity..."

docker exec remnawave-nginx \
    wget -q -O /dev/null --timeout=10 \
    "http://remnawave:3000/" \
    || {
        echo
        echo "ERROR: Nginx cannot reach Remnawave."
        echo
        docker logs --tail=50 remnawave
        echo
        docker logs --tail=50 remnawave-nginx
        exit 1
    }

echo "OK: Nginx can reach Remnawave."

# ============================================================
# 29. AUTO RENEWAL
# ============================================================

echo
echo ">>> Configuring automatic SSL renewal..."

"${ACME_SH}" \
    --install-cert \
    -d "${MAIN_DOMAIN}" \
    --key-file "${NGINX_DIR}/privkey.key" \
    --fullchain-file "${NGINX_DIR}/fullchain.pem" \
    --reloadcmd "docker exec remnawave-nginx nginx -s reload"

echo "OK: Automatic SSL renewal configured."

# ============================================================
# 30. LOCAL HTTPS TEST
# ============================================================

echo
echo ">>> Testing HTTPS locally..."

if curl -k -fsSI --max-time 15 \
    --resolve "${MAIN_DOMAIN}:443:127.0.0.1" \
    "https://${MAIN_DOMAIN}/" >/dev/null; then
    echo "OK: Local HTTPS is working."
else
    echo
    echo "ERROR: Local HTTPS test failed."
    docker compose logs --tail=100
    exit 1
fi

# ============================================================
# 31. HTTP REDIRECT TEST
# ============================================================

echo
echo ">>> Testing HTTP -> HTTPS redirect..."

if curl -fsSI --max-time 15 \
    --resolve "${MAIN_DOMAIN}:80:127.0.0.1" \
    "http://${MAIN_DOMAIN}/" | grep -qiE "301|302"; then
    echo "OK: HTTP redirects to HTTPS."
else
    echo "WARNING: HTTP redirect test did not return 301/302."
fi

# ============================================================
# 32. FINAL STATUS
# ============================================================

echo
echo "============================================================"
echo "              INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "🎛️  Panel:"
echo "    https://${MAIN_DOMAIN}"

if [ -n "${SUB_DOMAIN}" ]; then
    echo
    echo "💌 Subscription:"
    echo "    https://${SUB_DOMAIN}/api/sub"
fi

echo
echo "🐳 Docker:"
docker ps \
    --filter name=remnawave \
    --filter name=remnawave-nginx \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "🌐 Docker network:"
docker network inspect "${NETWORK_NAME}" \
    --format '{{range .Containers}}{{.Name}} -> {{.IPv4Address}}{{println}}{{end}}'

echo
echo "🔌 Listening ports:"
ss -lntp | grep -E ':(80|443)[[:space:]]' || true

echo
echo "============================================================"
echo "                 📚 COMMON COMMANDS"
echo "============================================================"
echo

echo "🎛️  Remnawave:"
echo "    cd ${INSTALL_DIR} && docker compose ps"
echo "    cd ${INSTALL_DIR} && docker compose logs -f remnawave"
echo "    cd ${INSTALL_DIR} && docker compose restart"
echo "    cd ${INSTALL_DIR} && docker compose down"
echo "    cd ${INSTALL_DIR} && docker compose up -d"

echo
echo "🪽 Nginx:"
echo "    cd ${NGINX_DIR} && docker compose ps"
echo "    cd ${NGINX_DIR} && docker compose logs -f"
echo "    cd ${NGINX_DIR} && docker compose restart"
echo "    cd ${NGINX_DIR} && docker compose down"
echo "    cd ${NGINX_DIR} && docker compose up -d"

echo
echo "🩺 Health:"
echo "    curl -fsS http://127.0.0.1:3001/health"
echo "    docker ps"
echo "    docker network inspect ${NETWORK_NAME}"

echo
echo "🔐 SSL:"
echo "    ${ACME_SH} --list"
echo "    ${ACME_SH} --renew-all"

echo
echo "🌍 HTTPS:"
echo "    curl -I https://${MAIN_DOMAIN}"

echo
echo "⚙️  After changing .env:"
echo "    cd ${INSTALL_DIR} && docker compose down && docker compose up -d"

echo
echo "🗑️  FULL UNINSTALL:"
echo "    cd ${INSTALL_DIR} 2>/dev/null || true && docker compose down -v --remove-orphans 2>/dev/null || true && cd ${NGINX_DIR} 2>/dev/null || true && docker compose down -v --remove-orphans 2>/dev/null || true && docker rm -f remnawave remnawave-db remnawave-redis remnawave-nginx 2>/dev/null || true && docker volume rm remnawave-db-data valkey-socket 2>/dev/null || true && docker network rm ${NETWORK_NAME} 2>/dev/null || true && rm -rf ${INSTALL_DIR}"

echo
echo "============================================================"
echo "                    ❤️  Ready"
echo "============================================================"
echo
