#!/usr/bin/env bash
################################################################################
# Script for installing isolated Odoo instances on Ubuntu 22.04 and 24.04 LTS.
# Original Author: Yenthe Van Ginneken
# Modified & Hardened by: Ameer Haider
# License: MIT (see LICENSE file)
#-------------------------------------------------------------------------------
# This script deploys an isolated Odoo instance on an Ubuntu server prepared by
# server_config.sh. Each instance operates with its own:
#   - System service account (no interactive login shell)
#   - Dedicated directory tree under /opt/<instance> (0750 permissions)
#   - Dedicated Python virtual environment (venv)
#   - Isolated PostgreSQL role (non-superuser)
#   - Dedicated HTTP and WebSocket/longpolling ports
#   - Hardened systemd service with Linux sandboxing directives
#   - Instance-specific Nginx reverse proxy configuration & log rotation
#
# Usage:
#   1. Adjust the configuration parameters below for each unique instance.
#   2. Execute: sudo bash odoo_install.sh
################################################################################

set -euo pipefail
umask 027

#===============================================================================
# INSTANCE CONFIGURATION PARAMETERS (Edit per instance)
#===============================================================================
OE_USER="odoo"                          # Unique system & PostgreSQL user (lowercase, alphanumeric, _)
OE_PORT="8016"                          # Unique HTTP listening port (1024-65535)
LONGPOLLING_PORT="8072"                 # Unique WebSocket/longpolling port (1024-65535, != OE_PORT)
OE_VERSION="17.0"                       # Odoo version (e.g. 16.0, 17.0, 18.0, 19.0, 20.0)

IS_ENTERPRISE="False"                   # Set to "True" to clone and configure Odoo Enterprise addons
INSTALL_NGINX="True"                    # Set to "True" to configure instance Nginx reverse proxy
WEBSITE_NAME="_"                        # Domain name (e.g., odoo.example.com). Use "_" for catch-all/dev
ENABLE_SSL="False"                      # Set to "True" to provision Let's Encrypt TLS with Certbot
ADMIN_EMAIL="odoo@example.com"          # Real admin email for Certbot registration (required if ENABLE_SSL=True)

GENERATE_RANDOM_PASSWORD="True"         # Set to "True" to auto-generate a cryptographically secure password
OE_SUPERADMIN="admin"                   # Used only if GENERATE_RANDOM_PASSWORD="False"

LIST_DB="True"                          # Set to "True" for initial DB creation; switch to "False" afterwards
DB_FILTER=""                            # Optional dbfilter (e.g. "^%d$" or "^odoo.*$"). Empty = unrestricted

# Derived paths
OE_CONFIG="${OE_USER}-server"
OE_HOME="/opt/${OE_USER}"
OE_HOME_SERVER="${OE_HOME}/${OE_USER}-server"
OE_HOME_VENV="${OE_HOME}/${OE_USER}-venv"
INIT_FILE="/etc/systemd/system/${OE_CONFIG}.service"
CONF_FILE="/etc/${OE_CONFIG}.conf"
NGINX_SITE_CONF="/etc/nginx/conf.d/odoo-${OE_CONFIG}.conf"
LOG_DIR="/var/log/${OE_USER}"
LOG_FILE="${LOG_DIR}/${OE_CONFIG}.log"
LOGROTATE_CONF="/etc/logrotate.d/${OE_CONFIG}"

#===============================================================================
# ERROR & ROLLBACK HANDLING
#===============================================================================
cleanup_on_error() {
    local line="$1"
    echo "" >&2
    echo "================================================================================" >&2
    echo " [FATAL ERROR] Installation encountered a failure on line $line." >&2
    echo " The operation stopped before completing instance deployment." >&2
    echo "" >&2
    echo " Diagnostic information for instance: '${OE_CONFIG}'" >&2
    echo " - System User:        ${OE_USER}" >&2
    echo " - Filesystem Home:    ${OE_HOME}" >&2
    echo " - Configuration:      ${CONF_FILE}" >&2
    echo " - Systemd Service:    ${INIT_FILE}" >&2
    echo " - Nginx Config:       ${NGINX_SITE_CONF}" >&2
    echo "" >&2
    echo " Safe manual cleanup commands (affects ONLY this instance):" >&2
    echo "   sudo systemctl stop ${OE_CONFIG}.service 2>/dev/null || true" >&2
    echo "   sudo systemctl disable ${OE_CONFIG}.service 2>/dev/null || true" >&2
    echo "   sudo rm -f ${INIT_FILE} ${CONF_FILE} ${NGINX_SITE_CONF} ${LOGROTATE_CONF}" >&2
    echo "   sudo systemctl daemon-reload" >&2
    echo "   sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || true" >&2
    echo "   sudo rm -rf ${OE_HOME} ${LOG_DIR}" >&2
    echo "   sudo userdel ${OE_USER} 2>/dev/null || true" >&2
    echo "   sudo -u postgres dropuser ${OE_USER} 2>/dev/null || true" >&2
    echo "================================================================================" >&2
}
trap 'cleanup_on_error $LINENO' ERR

#===============================================================================
# PREFLIGHT VERIFICATION & COMPATIBILITY GATES
# (Strict zero-side-effect validation before any system changes)
#===============================================================================
echo "==> Running preflight verification for instance '${OE_CONFIG}'..."

# 1. Privileges check
if (( EUID != 0 )); then
    echo "Error: This script must be run as root (sudo)." >&2
    exit 1
fi

# 2. Host Operating System check
# shellcheck source=/dev/null
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
else
    echo "Error: /etc/os-release not found. Only Ubuntu 22.04 & 24.04 LTS are supported." >&2
    exit 1
fi

if [[ "${ID:-}" != "ubuntu" || ! "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
    echo "Error: Unsupported distribution (${ID:-} ${VERSION_ID:-}). Only Ubuntu 22.04 & 24.04 LTS are supported." >&2
    exit 1
fi

# 3. User and identifier validation
if [[ ! "$OE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Error: OE_USER '$OE_USER' contains invalid characters. Use lowercase alphanumeric and underscores." >&2
    exit 1
fi

# Prohibit colliding with critical system users
case "$OE_USER" in
    root|postgres|nginx|www-data|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|backup|list|irc|nobody|systemd*)
        echo "Error: OE_USER cannot be a reserved system user ($OE_USER)." >&2
        exit 1
        ;;
esac

# 4. Port configuration validation
if [[ ! "$OE_PORT" =~ ^[0-9]+$ || ! "$LONGPOLLING_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: Ports must be positive integers." >&2
    exit 1
fi

if (( OE_PORT < 1024 || OE_PORT > 65535 || LONGPOLLING_PORT < 1024 || LONGPOLLING_PORT > 65535 )); then
    echo "Error: Ports must be in the unprivileged range (1024-65535)." >&2
    exit 1
fi

if (( OE_PORT == LONGPOLLING_PORT )); then
    echo "Error: OE_PORT ($OE_PORT) and LONGPOLLING_PORT ($LONGPOLLING_PORT) must be distinct." >&2
    exit 1
fi

# 5. Odoo version format and compatibility gating
if [[ ! "$OE_VERSION" =~ ^[0-9]+\.0$ ]]; then
    echo "Error: OE_VERSION must follow the standard release format, e.g. 16.0, 17.0, 18.0, 19.0, 20.0." >&2
    exit 1
fi

# Version-specific runtime compatibility verification
# Odoo 20.0 requires Python >= 3.12 and PostgreSQL >= 16 (odoo/release.py).
# Ubuntu 22.04 LTS defaults to Python 3.10 and PostgreSQL 14.
if [[ "$OE_VERSION" == "20.0" && "$VERSION_ID" == "22.04" ]]; then
    echo "Error: Odoo 20.0 requires Python >= 3.12 and PostgreSQL >= 16." >&2
    echo "       Ubuntu 22.04 LTS defaults to Python 3.10 and PostgreSQL 14." >&2
    echo "       Please use Ubuntu 24.04 LTS (Noble) to deploy Odoo 20.0." >&2
    exit 1
fi

# 6. Host tool requirements (ensures server_config.sh was executed)
for cmd in git python3 curl psql systemctl openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required utility '$cmd' is not installed. Please run 'sudo bash server_config.sh' first." >&2
        exit 1
    fi
done

# 7. Collision checks: Prevent overwriting any existing instance
if id "$OE_USER" >/dev/null 2>&1; then
    echo "Error: System user '$OE_USER' already exists. Choose a unique OE_USER for this instance." >&2
    exit 1
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OE_USER'" 2>/dev/null | grep -q 1; then
    echo "Error: PostgreSQL role '$OE_USER' already exists. Choose a unique OE_USER for this instance." >&2
    exit 1
fi

if [[ -e "$OE_HOME" ]]; then
    echo "Error: Directory '$OE_HOME' already exists. Refusing to overwrite existing instance." >&2
    exit 1
fi

if [[ -e "$CONF_FILE" ]]; then
    echo "Error: Configuration file '$CONF_FILE' already exists." >&2
    exit 1
fi

if [[ -e "$INIT_FILE" ]]; then
    echo "Error: Systemd service '$INIT_FILE' already exists." >&2
    exit 1
fi

if [[ -e "$LOG_DIR" ]]; then
    echo "Error: Log directory '$LOG_DIR' already exists." >&2
    exit 1
fi

if [[ -e "$LOGROTATE_CONF" ]]; then
    echo "Error: Logrotate configuration '$LOGROTATE_CONF' already exists." >&2
    exit 1
fi

# Check if ports are already bound
if command -v ss >/dev/null 2>&1; then
    if ss -ltnH "( sport = :$OE_PORT or sport = :$LONGPOLLING_PORT )" | grep -q .; then
        echo "Error: Port $OE_PORT or $LONGPOLLING_PORT is already listening on this host." >&2
        exit 1
    fi
fi

# 8. Web and SSL settings validation
if [[ "$WEBSITE_NAME" != "_" ]]; then
    if [[ ! "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: WEBSITE_NAME must be a valid FQDN (e.g. odoo.example.com) or '_'." >&2
        exit 1
    fi
fi

if [[ "$INSTALL_NGINX" == "True" && -e "$NGINX_SITE_CONF" ]]; then
    echo "Error: Nginx configuration '$NGINX_SITE_CONF' already exists." >&2
    exit 1
fi

if [[ "$INSTALL_NGINX" == "True" && "$ENABLE_SSL" == "True" ]]; then
    if [[ "$WEBSITE_NAME" == "_" ]]; then
        echo "Error: ENABLE_SSL is True, but WEBSITE_NAME is set to '_'. A valid public DNS domain is required." >&2
        exit 1
    fi
    if [[ "$ADMIN_EMAIL" == "odoo@example.com" || ! "$ADMIN_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: A valid, real ADMIN_EMAIL is required for Certbot SSL certificate registration." >&2
        exit 1
    fi
fi

echo "==> Preflight checks passed successfully. Proceeding with deployment."

#===============================================================================
# 1. POSTGRESQL ROLE PROVISIONING
#===============================================================================
echo "==> Ensuring PostgreSQL service is active..."
systemctl is-active --quiet postgresql || systemctl start postgresql

echo "==> Creating PostgreSQL role '${OE_USER}'..."
# Non-superuser role with CREATEDB privilege to allow initial database management
sudo -u postgres createuser --createdb --no-superuser --no-createrole "$OE_USER"

#===============================================================================
# 2. SYSTEM SERVICE ACCOUNT & DIRECTORY HIERARCHY
#===============================================================================
echo "==> Creating system service user '${OE_USER}'..."
# System account without interactive login shell for enhanced process security
adduser --system --quiet --shell=/usr/sbin/nologin --home="$OE_HOME" --no-create-home --gecos 'Odoo Service Account' --group "$OE_USER"

echo "==> Creating isolated directory hierarchy under '${OE_HOME}'..."
mkdir -p "$OE_HOME"
mkdir -p "$OE_HOME/custom/addons"
mkdir -p "$OE_HOME/backups"
mkdir -p "$OE_HOME/bin"
mkdir -p "$LOG_DIR"

chmod 0750 "$OE_HOME"
chmod 0750 "$LOG_DIR"
chown -R "$OE_USER:$OE_USER" "$OE_HOME" "$LOG_DIR"

#===============================================================================
# 3. ODOO CORE SOURCE CODE RETRIEVAL
#===============================================================================
echo "==> Cloning Odoo ${OE_VERSION} core from official repository..."
git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo.git "$OE_HOME_SERVER"
chown -R "$OE_USER:$OE_USER" "$OE_HOME_SERVER"

#===============================================================================
# 4. PYTHON VIRTUAL ENVIRONMENT & DEPENDENCY INSTALLATION
#===============================================================================
echo "==> Creating isolated Python virtual environment at '${OE_HOME_VENV}'..."
python3 -m venv "$OE_HOME_VENV"

echo "==> Upgrading pip, setuptools, and wheel in virtual environment..."
"$OE_HOME_VENV/bin/pip" install --upgrade pip setuptools wheel

echo "==> Installing Odoo requirements from cloned repository..."
"$OE_HOME_VENV/bin/pip" install -r "$OE_HOME_SERVER/requirements.txt"

#===============================================================================
# 5. ENTERPRISE ADDONS (OPTIONAL)
#===============================================================================
if [[ "$IS_ENTERPRISE" == "True" ]]; then
    echo "==> Configuring Odoo Enterprise addons..."
    mkdir -p "$OE_HOME/enterprise/addons"

    # Install Python libraries commonly needed by enterprise modules
    "$OE_HOME_VENV/bin/pip" install --no-binary :all: num2words \
        || "$OE_HOME_VENV/bin/pip" install num2words
    "$OE_HOME_VENV/bin/pip" install pdfminer.six ofxparse dbfread ebaysdk firebase_admin pyOpenSSL

    echo "==> Cloning Odoo Enterprise repository..."
    if ! git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise.git "$OE_HOME/enterprise/addons" 2>/dev/null; then
        echo "Notice: Could not clone private odoo/enterprise repository automatically."
        echo "Ensure GitHub authentication is configured, or manually place Enterprise addons into: $OE_HOME/enterprise/addons"
    fi
    chown -R "$OE_USER:$OE_USER" "$OE_HOME/enterprise"
fi

# Fix ownership across entire home folder
chown -R "$OE_USER:$OE_USER" "$OE_HOME"

#===============================================================================
# 6. LOG ROTATION CONFIGURATION
#===============================================================================
echo "==> Configuring automated log rotation (30-day retention)..."
cat <<EOF > "$LOGROTATE_CONF"
${LOG_FILE} {
    daily
    rotate 30
    copytruncate
    delaycompress
    compress
    notifempty
    missingok
}
EOF
chmod 0644 "$LOGROTATE_CONF"

#===============================================================================
# 7. ODOO CONFIGURATION FILE GENERATION
#===============================================================================
echo "==> Generating Odoo server configuration at '${CONF_FILE}'..."

if [[ "$GENERATE_RANDOM_PASSWORD" == "True" ]]; then
    OE_SUPERADMIN="$(openssl rand -hex 24)"
fi

if [[ "$IS_ENTERPRISE" == "True" && -d "$OE_HOME/enterprise/addons" ]]; then
    ADDONS_PATH="${OE_HOME}/enterprise/addons,${OE_HOME_SERVER}/addons,${OE_HOME}/custom/addons"
else
    ADDONS_PATH="${OE_HOME_SERVER}/addons,${OE_HOME}/custom/addons"
fi

cat <<EOF > "$CONF_FILE"
[options]
; Database administration password (protects /web/database/manager)
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
http_interface = 127.0.0.1
workers = 2
max_cron_threads = 1
gevent_port = ${LONGPOLLING_PORT}
longpolling_port = ${LONGPOLLING_PORT}
logfile = ${LOG_FILE}
addons_path = ${ADDONS_PATH}
list_db = ${LIST_DB}
EOF

if [[ -n "$DB_FILTER" ]]; then
    echo "dbfilter = ${DB_FILTER}" >> "$CONF_FILE"
fi

if [[ "$INSTALL_NGINX" == "True" ]]; then
    echo "proxy_mode = True" >> "$CONF_FILE"
fi

# Security Hardening: Root owns the configuration file with 0640 permissions.
# The Odoo group has read permissions, preventing the application process
# from modifying its own configuration or security directives.
chown root:"$OE_USER" "$CONF_FILE"
chmod 0640 "$CONF_FILE"

#===============================================================================
# 8. PROCESS MANAGEMENT HELPER SCRIPT
#===============================================================================
# Kept outside the git repository to preserve clean git status
cat <<EOF > "$OE_HOME/bin/odoo-start.sh"
#!/usr/bin/env bash
# Manual startup helper for instance: ${OE_CONFIG}
exec "${OE_HOME_VENV}/bin/python3" "${OE_HOME_SERVER}/odoo-bin" -c "${CONF_FILE}" "\$@"
EOF
chmod 0750 "$OE_HOME/bin/odoo-start.sh"
chown "$OE_USER:$OE_USER" "$OE_HOME/bin/odoo-start.sh"

#===============================================================================
# 9. SYSTEMD SERVICE CONFIGURATION & HARDENING
#===============================================================================
echo "==> Creating systemd service unit '${INIT_FILE}'..."
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
ExecStart=${OE_HOME_VENV}/bin/python3 ${OE_HOME_SERVER}/odoo-bin -c ${CONF_FILE}
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
ReadWritePaths=${OE_HOME} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$INIT_FILE"
systemctl daemon-reload
systemctl enable "$OE_CONFIG.service"

echo "==> Starting Odoo service '${OE_CONFIG}.service'..."
systemctl start "$OE_CONFIG.service"

# Brief pause to verify service didn't immediately crash
sleep 2
if ! systemctl is-active --quiet "$OE_CONFIG.service"; then
    echo "Warning: Odoo service did not enter active state. Check 'journalctl -u ${OE_CONFIG}.service -n 50'." >&2
fi

#===============================================================================
# 10. NGINX REVERSE PROXY & WEBSOCKET ROUTING
#===============================================================================
if [[ "$INSTALL_NGINX" == "True" ]]; then
    echo "==> Configuring Nginx reverse proxy..."

    # Create dedicated log directory for this instance's Nginx logs
    NGINX_LOG_DIR="/var/log/nginx/odoo-${OE_CONFIG}"
    install -d -m 0755 "$NGINX_LOG_DIR"

    # Append instance Nginx logs to instance logrotate configuration
    cat <<EOF >> "$LOGROTATE_CONF"

${NGINX_LOG_DIR}/access.log ${NGINX_LOG_DIR}/error.log {
    daily
    rotate 30
    copytruncate
    delaycompress
    compress
    notifempty
    missingok
}
EOF

    # Ensure global WebSocket connection upgrade map exists
    mkdir -p /etc/nginx/conf.d
    if [[ ! -f /etc/nginx/conf.d/odoo_websocket_map.conf ]]; then
        cat <<'EOF' > /etc/nginx/conf.d/odoo_websocket_map.conf
# Global Odoo WebSocket connection upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    fi

    # Domain for server block
    SERVER_DOMAIN="${WEBSITE_NAME}"

    cat <<EOF > "$NGINX_SITE_CONF"
# Upstream definitions for instance: ${OE_CONFIG}
upstream odoo_${OE_CONFIG} {
    server 127.0.0.1:${OE_PORT};
}
upstream odoochat_${OE_CONFIG} {
    server 127.0.0.1:${LONGPOLLING_PORT};
}

server {
    listen 80;
    server_name ${SERVER_DOMAIN};
    server_tokens off;
    client_max_body_size 100m;

    # Instance-isolated Nginx logs
    access_log ${NGINX_LOG_DIR}/access.log;
    error_log ${NGINX_LOG_DIR}/error.log;

    # Proxy timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # WebSocket routing (Odoo 16+ chat & bus communication)
    location /websocket {
        proxy_pass http://odoochat_${OE_CONFIG};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Longpolling routing (Odoo 16 compatibility)
    location /longpolling {
        proxy_pass http://odoochat_${OE_CONFIG};
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Primary application proxy routing
    location / {
        proxy_redirect off;
        proxy_pass http://odoo_${OE_CONFIG};
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Gzip compression
    gzip on;
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF

    # Validate Nginx configuration before reloading
    if nginx -t; then
        systemctl reload nginx
        echo "==> Nginx site configured and reloaded."
    else
        echo "Error: Nginx configuration test failed." >&2
        exit 1
    fi

    # Automated TLS Certificate Provisioning with Certbot
    if [[ "$ENABLE_SSL" == "True" && "$WEBSITE_NAME" != "_" ]]; then
        echo "==> Provisioning TLS certificate with Certbot for ${WEBSITE_NAME}..."
        certbot --nginx -d "$WEBSITE_NAME" --noninteractive --agree-tos --email "$ADMIN_EMAIL" --redirect
        systemctl reload nginx
        echo "==> TLS certificate provisioned and HTTPS redirect enabled."
    fi
fi

# Disarm error trap on clean completion
trap - ERR

#===============================================================================
# DEPLOYMENT SUMMARY & SECURITY GUIDANCE
#===============================================================================
echo ""
echo "================================================================================"
echo " Odoo Instance '${OE_CONFIG}' Deployed Successfully!"
echo "================================================================================"
echo " Specifications:"
echo "   - Instance Name:            ${OE_CONFIG}"
echo "   - System Service Account:   ${OE_USER}"
echo "   - PostgreSQL Role:          ${OE_USER}"
echo "   - Odoo Core Version:        ${OE_VERSION}"
echo "   - HTTP Port:                ${OE_PORT}"
echo "   - Longpolling/WS Port:      ${LONGPOLLING_PORT}"
echo "   - Application Home:         ${OE_HOME}"
echo "   - Custom Addons Directory:  ${OE_HOME}/custom/addons"
echo "   - Virtual Environment:      ${OE_HOME_VENV}"
echo "   - Configuration File:       ${CONF_FILE} (0640 root:${OE_USER})"
echo "   - Application Log:          ${LOG_FILE}"
echo "   - Logrotate Config:         ${LOGROTATE_CONF}"
if [[ "$INSTALL_NGINX" == "True" ]]; then
echo "   - Nginx Site Config:        ${NGINX_SITE_CONF}"
echo "   - Domain / Hostname:        ${WEBSITE_NAME}"
fi
echo ""
echo " Database Superadmin Password:"
echo "   ${OE_SUPERADMIN}"
echo "   (Stored securely in ${CONF_FILE}. Restrict access to this credential.)"
echo ""
echo " Operational Service Commands:"
echo "   - Status:   sudo systemctl status ${OE_CONFIG}.service"
echo "   - Start:    sudo systemctl start ${OE_CONFIG}.service"
echo "   - Stop:     sudo systemctl stop ${OE_CONFIG}.service"
echo "   - Restart:  sudo systemctl restart ${OE_CONFIG}.service"
echo "   - Logs:     sudo journalctl -u ${OE_CONFIG}.service -f"
echo ""
echo " Post-Installation Security Checklist:"
echo "   1. Navigate to your instance and create your initial database."
echo "   2. Edit ${CONF_FILE} and configure:"
echo "        db_name = <your_database>"
echo "        dbfilter = ^<your_database>$"
echo "        list_db = False"
echo "   3. Restart the service: sudo systemctl restart ${OE_CONFIG}.service"
echo "   This locks down the database manager and prevents cross-instance exposure."
echo "================================================================================"
