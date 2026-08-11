#!/usr/bin/env bash

# ============================================================
# Remnawave + Nginx + SSL
# Ubuntu / Debian / AWS EC2
#
# Panel:
#   https://aa.dropmint.cc.cd
#
# Subscription:
#   https://sub.dropmint.cc.cd/api/sub
#
# Architecture:
#
# Internet
#    |
#    | 80 / 443
#    v
# Nginx
#    |
#    | Docker network: remnawave-network
#    v
# Remnawave :3000
#    |
#    +--> PostgreSQL
#    |
#    +--> Valkey
#
# SSL:
#   acme.sh + ALPN + TCP 8443
#
# IMPORTANT:
#   Do NOT expose Remnawave 3000/3001 publicly.
# ============================================================

set -Eeuo pipefail

INSTALL_DIR="/opt/remnawave"
NGINX_DIR="${INSTALL_DIR}/nginx"
NETWORK_NAME="remnawave-network"

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
    echo
    echo "sudo bash $0"
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
    ubuntu|debian)
        ;;
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

read -rp "Panel domain [aa.dropmint.cc.cd]: " MAIN_DOMAIN
MAIN_DOMAIN="${MAIN_DOMAIN:-aa.dropmint.cc.cd}"

read -rp "Subscription domain [sub.dropmint.cc.cd]: " SUB_DOMAIN
SUB_DOMAIN="${SUB_DOMAIN:-sub.dropmint.cc.cd}"

read -rp "SSL email: " EMAIL

if [ -z "${EMAIL}" ]; then
    echo "ERROR: SSL email cannot be empty."
    exit 1
fi

echo
echo "------------------------------------------------------------"
echo "Panel        : ${MAIN_DOMAIN}"
echo "Subscription : ${SUB_DOMAIN}"
echo "SSL email    : ${EMAIL}"
echo "------------------------------------------------------------"
echo

# ============================================================
# 3. BASIC VALIDATION
# ============================================================

if [[ "${MAIN_DOMAIN}" == *"/"* ]]; then
    echo "ERROR: MAIN_DOMAIN must not contain /"
    exit 1
fi

if [[ "${SUB_DOMAIN}" == *"/"* ]]; then
    echo "ERROR: SUB_DOMAIN must not contain /"
    exit 1
fi

if [[ "${MAIN_DOMAIN}" == "http://"* || "${MAIN_DOMAIN}" == "https://"* ]]; then
    echo "ERROR: Domain must not contain http:// or https://"
    exit 1
fi

if [[ "${SUB_DOMAIN}" == "http://"* || "${SUB_DOMAIN}" == "https://"* ]]; then
    echo "ERROR: Domain must not contain http:// or https://"
    exit 1
fi

# ============================================================
# 4. DEPENDENCIES
# ============================================================

echo
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
    echo
    echo "ERROR: Docker Compose plugin is unavailable."
    docker --version || true
    exit 1
fi

echo "Docker:"
docker --version

echo "Compose:"
docker compose version

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
resolve_domain "${SUB_DOMAIN}"

echo
echo "IMPORTANT:"
echo "Both domains must point to this EC2 public IPv4."
echo

# ============================================================
# 7. CHECK PORTS
# ============================================================

echo ">>> Checking local ports..."

if ss -lnt 2>/dev/null | grep -qE '(^|:)443[[:space:]]'; then
    echo "ERROR: TCP 443 is already occupied."
    ss -lntp | grep ':443' || true
    exit 1
fi

if ss -lnt 2>/dev/null | grep -qE '(^|:)80[[:space:]]'; then
    echo "ERROR: TCP 80 is already occupied."
    ss -lntp | grep ':80' || true
    exit 1
fi

if ss -lnt 2>/dev/null | grep -qE '(^|:)8443[[:space:]]'; then
    echo "ERROR: TCP 8443 is already occupied."
    ss -lntp | grep ':8443' || true
    exit 1
fi

echo "OK: 80 is free"
echo "OK: 443 is free"
echo "OK: 8443 is free"

# ============================================================
# 8. PREPARE DIRECTORIES
# ============================================================

echo
echo ">>> Preparing ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}"
mkdir -p "${NGINX_DIR}"

cd "${INSTALL_DIR}"

# ============================================================
# 9. DOWNLOAD OFFICIAL REMNAWAVE FILES
# ============================================================

echo
echo ">>> Downloading official Remnawave files..."

curl -fsSL \
    -o "${INSTALL_DIR}/docker-compose.yml" \
    "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"

curl -fsSL \
    -o "${INSTALL_DIR}/.env" \
    "https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

if [ ! -s "${INSTALL_DIR}/docker-compose.yml" ]; then
    echo "ERROR: docker-compose.yml download failed."
    exit 1
fi

if [ ! -s "${INSTALL_DIR}/.env" ]; then
    echo "ERROR: .env download failed."
    exit 1
fi

# ============================================================
# 10. DOCKER NETWORK
#
# IMPORTANT:
# The network MUST exist BEFORE Remnawave is started.
#
# This fixes the original installer bug.
# ============================================================

echo
echo ">>> Creating Docker network..."

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "Docker network already exists: ${NETWORK_NAME}"
else
    docker network create \
        --driver bridge \
        "${NETWORK_NAME}"
fi

echo "OK: Docker network ${NETWORK_NAME}"

# ============================================================
# 11. FORCE REMNAWAVE COMPOSE TO USE SAME NETWORK
#
# We intentionally generate our own compose file.
#
# The network is external because Nginx is in another compose
# project and MUST join exactly the same Docker network.
# ============================================================

echo
echo ">>> Preparing Remnawave Docker Compose..."

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
      - ${NGINX_DIR}/:/var/lib/remnawave/configs/xray/ssl

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
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      TZ: UTC

    ports:
      - "127.0.0.1:6767:5432"

    volumes:
      - remnawave-db-data:/var/lib/postgresql

    healthcheck:
      test:
        [
          "CMD-SHELL",
          "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"
        ]
      interval: 3s
      timeout: 10s
      retries: 5

  remnawave-redis:
    image: valkey/valkey:9-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis

    <<: [*common, *logging]

    volumes:
      - valkey-socket:/var/run/valkey

    command: >
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
      --port 0

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
      retries: 5

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
# 12. GENERATE SECRETS
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

# Compatibility with versions that still contain APP_SECRET.
if grep -qE "^APP_SECRET=|^#APP_SECRET=" "${INSTALL_DIR}/.env"; then
    set_env "APP_SECRET" "${APP_SECRET}"
fi

set_env "METRICS_PASS" "${METRICS_PASS}"
set_env "WEBHOOK_SECRET_HEADER" "${WEBHOOK_SECRET_HEADER}"
set_env "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"

# ============================================================
# 13. DATABASE URL
# ============================================================

echo
echo ">>> Configuring PostgreSQL..."

DATABASE_URL="postgresql://postgres:${POSTGRES_PASSWORD}@remnawave-db:5432/postgres"

if grep -q '^DATABASE_URL=' "${INSTALL_DIR}/.env"; then
    sed -i \
        "s|^DATABASE_URL=.*|DATABASE_URL=\"${DATABASE_URL}\"|" \
        "${INSTALL_DIR}/.env"
else
    printf 'DATABASE_URL="%s"\n' "${DATABASE_URL}" >> "${INSTALL_DIR}/.env"
fi

# ============================================================
# 14. DOMAIN CONFIG
# ============================================================

echo
echo ">>> Configuring domains..."

set_env "FRONT_END_DOMAIN" "${MAIN_DOMAIN}"
set_env "SUB_PUBLIC_DOMAIN" "${SUB_DOMAIN}/api/sub"
set_env "PANEL_DOMAIN" "${MAIN_DOMAIN}"

echo
echo "FRONT_END_DOMAIN=${MAIN_DOMAIN}"
echo "SUB_PUBLIC_DOMAIN=${SUB_DOMAIN}/api/sub"
echo "PANEL_DOMAIN=${MAIN_DOMAIN}"

# ============================================================
# 15. VALIDATE COMPOSE BEFORE STARTING
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
echo ">>> Waiting for Remnawave..."

for i in $(seq 1 60); do

    if docker inspect \
        -f '{{.State.Running}}' \
        remnawave 2>/dev/null | grep -q true; then

        echo "OK: remnawave container is running."
        break
    fi

    if [ "$i" -eq 60 ]; then
        echo
        echo "ERROR: Remnawave failed to start."
        echo
        docker compose ps
        echo
        docker compose logs --tail=100 remnawave
        exit 1
    fi

    sleep 2
done

# ============================================================
# 17. VERIFY REMNAWAVE NETWORK
# ============================================================

echo
echo ">>> Verifying Docker network..."

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave"'; then

    echo "ERROR: remnawave is NOT connected to ${NETWORK_NAME}."

    docker network inspect "${NETWORK_NAME}" || true

    echo
    echo "Trying to repair Docker network..."

    docker compose down

    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true

    docker network create \
        --driver bridge \
        "${NETWORK_NAME}"

    docker compose up -d

    sleep 5

fi

# Final network check.

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave"'; then

    echo
    echo "ERROR: Remnawave still cannot join Docker network."
    echo
    docker network inspect "${NETWORK_NAME}" || true
    exit 1
fi

echo "OK: remnawave is connected to ${NETWORK_NAME}"

# ============================================================
# 18. TEST REMNAWAVE INTERNAL API
# ============================================================

echo
echo ">>> Testing Remnawave localhost port..."

if ! curl -fsS \
    --max-time 10 \
    "http://127.0.0.1:3001/health" \
    >/dev/null 2>&1; then

    echo "WARNING: Remnawave health endpoint is not ready yet."

    docker compose ps
    docker compose logs --tail=50 remnawave

else
    echo "OK: Remnawave health endpoint is responding."
fi

# ============================================================
# 19. INSTALL ACME.SH
# ============================================================

echo
echo ">>> Installing acme.sh..."

export HOME="/root"

if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
    curl -fsSL \
        https://get.acme.sh \
        | sh -s email="${EMAIL}"
fi

ACME_SH="${HOME}/.acme.sh/acme.sh"

if [ ! -x "${ACME_SH}" ]; then
    echo "ERROR: acme.sh installation failed."
    exit 1
fi

# Make sure cron exists for renewal.
systemctl enable --now cron >/dev/null 2>&1 || true

# ============================================================
# 20. ISSUE SSL CERTIFICATE
#
# IMPORTANT:
# Nginx is NOT started yet.
# Therefore 8443 is available to acme.sh.
# ============================================================

echo
echo ">>> Issuing SSL certificate..."

mkdir -p "${NGINX_DIR}"

CERT_ARGS=(
    -d "${MAIN_DOMAIN}"
    -d "${SUB_DOMAIN}"
)

"${ACME_SH}" \
    --issue \
    --standalone \
    "${CERT_ARGS[@]}" \
    --alpn \
    --tlsport 8443

echo "OK: SSL certificate issued."

# ============================================================
# 21. INSTALL CERTIFICATE
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

cat > "${NGINX_DIR}/nginx.conf" <<EOF

# ============================================================
# Remnawave upstream
# ============================================================

upstream remnawave {
    server remnawave:3000;
}

# ============================================================
# HTTP -> HTTPS
# ============================================================

server {
    listen 80;
    listen [::]:80;

    server_name ${MAIN_DOMAIN} ${SUB_DOMAIN};

    return 301 https://\$host\$request_uri;
}

# ============================================================
# HTTPS
# ============================================================

server {
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;

    http2 on;

    server_name ${MAIN_DOMAIN} ${SUB_DOMAIN};

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

# ============================================================
# Reject unknown HTTPS hosts
# ============================================================

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    ssl_reject_handshake on;
}

EOF

# ============================================================
# 23. NGINX DOCKER COMPOSE
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
    driver: bridge
    external: true
EOF

# ============================================================
# 24. NGINX CONFIG TEST BEFORE START
# ============================================================

echo
echo ">>> Testing Nginx configuration..."

cd "${NGINX_DIR}"

docker compose run \
    --rm \
    --no-deps \
    remnawave-nginx \
    nginx -t

echo "OK: Nginx configuration is valid."

# ============================================================
# 25. VERIFY NGINX CAN RESOLVE REMNAWAVE
#
# This is the exact problem that broke the previous install.
# ============================================================

echo
echo ">>> Testing Docker DNS: remnawave -> remnawave..."

docker compose run \
    --rm \
    --no-deps \
    remnawave-nginx \
    getent hosts remnawave

echo "OK: Docker DNS can resolve remnawave."

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
    echo
    docker compose ps
    echo
    docker compose logs --tail=100
    exit 1
fi

echo "OK: Nginx is running."

# ============================================================
# 27. VERIFY BOTH CONTAINERS ARE ON SAME NETWORK
# ============================================================

echo
echo ">>> Verifying final Docker network..."

docker network inspect "${NETWORK_NAME}" \
    | grep -E '"Name": "(remnawave|remnawave-nginx)"' \
    || true

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave"'; then

    echo "ERROR: remnawave is missing from network."
    exit 1
fi

if ! docker network inspect "${NETWORK_NAME}" \
    | grep -q '"Name": "remnawave-nginx"'; then

    echo "ERROR: remnawave-nginx is missing from network."
    exit 1
fi

echo
echo "OK: Both containers share ${NETWORK_NAME}"

# ============================================================
# 28. TEST NGINX -> REMNAWAVE
# ============================================================

echo
echo ">>> Testing Nginx -> Remnawave connectivity..."

docker exec remnawave-nginx \
    wget \
    -q \
    -O /dev/null \
    --timeout=10 \
    "http://remnawave:3000/" \
    || {

        echo
        echo "WARNING: Nginx container cannot currently reach Remnawave."
        echo
        docker logs --tail=50 remnawave
        echo
        docker logs --tail=50 remnawave-nginx
        exit 1
    }

echo "OK: Nginx can reach Remnawave."

# ============================================================
# 29. SSL RENEWAL
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

if curl \
    -k \
    -fsSI \
    --max-time 15 \
    --resolve "${MAIN_DOMAIN}:443:127.0.0.1" \
    "https://${MAIN_DOMAIN}/" \
    >/dev/null; then

    echo "OK: Local HTTPS is working."

else

    echo
    echo "ERROR: Local HTTPS test failed."
    echo
    docker compose logs --tail=100
    exit 1
fi

# ============================================================
# 31. HTTP REDIRECT TEST
# ============================================================

echo
echo ">>> Testing HTTP -> HTTPS redirect..."

if curl \
    -fsSI \
    --max-time 15 \
    --resolve "${MAIN_DOMAIN}:80:127.0.0.1" \
    "http://${MAIN_DOMAIN}/" \
    | grep -qi "301\|302"; then

    echo "OK: HTTP redirects to HTTPS."

else

    echo "WARNING: HTTP redirect test did not return 301/302."
fi

# ============================================================
# 32. FINAL STATUS
# ============================================================

echo
echo "============================================================"
echo "                    INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Panel:"
echo "  https://${MAIN_DOMAIN}"

echo
echo "Subscription:"
echo "  https://${SUB_DOMAIN}/api/sub"

echo
echo "Docker:"
docker ps \
    --filter name=remnawave \
    --filter name=remnawave-nginx \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "Docker network:"
docker network inspect "${NETWORK_NAME}" \
    --format '{{range .Containers}}{{.Name}} -> {{.IPv4Address}}{{println}}{{end}}'

echo
echo "Listening ports:"
ss -lntp | grep -E ':(80|443)\s' || true

echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo
echo "AWS Security Group must allow:"
echo
echo "  TCP 80"
echo "  TCP 443"
echo "  TCP 8443"
echo
echo "Remnawave 3000/3001 are bound to 127.0.0.1 only."
echo
echo "Open:"
echo
echo "  https://${MAIN_DOMAIN}"
echo
echo "Do NOT use:"
echo "  http://127.0.0.1:3000"
echo "  http://${MAIN_DOMAIN}:3000"
echo
echo "============================================================"
echo
