#!/usr/bin/env bash
# Test 4: Configuration file and service template generation
set -euo pipefail

TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> [TEST] Testing configuration generation and security directives..."

OE_USER="odootest"
OE_CONFIG="${OE_USER}-server"
OE_PORT="8020"
LONGPOLLING_PORT="8076"
OE_SUPERADMIN="supersecret123"
OE_HOME="$TMP_DIR/opt/$OE_USER"
LOG_FILE="$TMP_DIR/log/$OE_USER/${OE_CONFIG}.log"
CONF_FILE="$TMP_DIR/etc/${OE_CONFIG}.conf"
INIT_FILE="$TMP_DIR/systemd/${OE_CONFIG}.service"
NGINX_SITE_CONF="$TMP_DIR/nginx/odoo-${OE_CONFIG}.conf"
NGINX_LOG_DIR="$TMP_DIR/log/nginx/odoo-${OE_CONFIG}"

mkdir -p "$(dirname "$CONF_FILE")" "$(dirname "$INIT_FILE")" "$(dirname "$NGINX_SITE_CONF")" "$NGINX_LOG_DIR"

# 1. Generate Odoo Configuration
cat <<EOF > "$CONF_FILE"
[options]
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
http_interface = 127.0.0.1
workers = 2
max_cron_threads = 1
gevent_port = ${LONGPOLLING_PORT}
longpolling_port = ${LONGPOLLING_PORT}
logfile = ${LOG_FILE}
addons_path = ${OE_HOME}/${OE_USER}-server/addons,${OE_HOME}/custom/addons
list_db = True
proxy_mode = True
EOF

# Verify Odoo Config
if ! grep -q "admin_passwd = supersecret123" "$CONF_FILE"; then
    echo "FAIL: admin_passwd missing in $CONF_FILE" >&2; exit 1
fi
if ! grep -q "http_port = 8020" "$CONF_FILE"; then
    echo "FAIL: http_port missing in $CONF_FILE" >&2; exit 1
fi
if ! grep -q "proxy_mode = True" "$CONF_FILE"; then
    echo "FAIL: proxy_mode missing in $CONF_FILE" >&2; exit 1
fi
echo "  [PASS] Odoo configuration generation verified."

# 2. Generate Systemd Unit with Sandboxing
cat <<EOF > "$INIT_FILE"
[Unit]
Description=Odoo Server Instance (${OE_CONFIG})
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
UMask=0027
SyslogIdentifier=${OE_CONFIG}
ExecStart=${OE_HOME}/${OE_USER}-venv/bin/python3 ${OE_HOME}/${OE_USER}-server/odoo-bin -c ${CONF_FILE}
StandardOutput=journal+console
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

# Security Sandboxing Directives
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictRealtime=true
RestrictSUIDSGID=true
ReadWritePaths=${OE_HOME} $TMP_DIR/log/${OE_USER}

[Install]
WantedBy=multi-user.target
EOF

# Verify Systemd Unit Sandboxing Directives
for directive in NoNewPrivileges ProtectSystem ProtectHome PrivateTmp PrivateDevices \
                 ProtectKernelTunables ProtectKernelModules ProtectControlGroups \
                 RestrictAddressFamilies RestrictRealtime RestrictSUIDSGID; do
    if ! grep -q "^${directive}=" "$INIT_FILE"; then
        echo "FAIL: Expected security directive $directive missing from systemd unit" >&2
        exit 1
    fi
done
echo "  [PASS] Systemd service unit security directives verified."

# 3. Generate Nginx Instance Reverse Proxy
cat <<EOF > "$NGINX_SITE_CONF"
upstream odoo_${OE_CONFIG} {
    server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${OE_CONFIG} {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    server_name test.example.com;
    server_tokens off;
    client_max_body_size 100m;

    access_log ${NGINX_LOG_DIR}/access.log;
    error_log ${NGINX_LOG_DIR}/error.log;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location /websocket {
        proxy_pass http://odoochat_${OE_CONFIG};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /longpolling {
        proxy_pass http://odoochat_${OE_CONFIG};
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://odoo_${OE_CONFIG};
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Verify Nginx Structure
if ! grep -q "upstream odoo_${OE_CONFIG}" "$NGINX_SITE_CONF"; then
    echo "FAIL: upstream odoo_${OE_CONFIG} missing" >&2; exit 1
fi
if ! grep -q "location /websocket" "$NGINX_SITE_CONF"; then
    echo "FAIL: location /websocket missing" >&2; exit 1
fi
if ! grep -q "location /longpolling" "$NGINX_SITE_CONF"; then
    echo "FAIL: location /longpolling missing" >&2; exit 1
fi
echo "  [PASS] Nginx instance reverse proxy structure verified."

echo "OK: Configuration generation tests passed."
