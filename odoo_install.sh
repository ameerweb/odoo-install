#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu 22.04 and 24.04
# Author: Yenthe Van Ginneken
# Modified by: Ameer Almughalis
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu server because of unique ports, users, and Nginx upstreams.
#-------------------------------------------------------------------------------
# How to use:
# sudo chmod +x odoo_install.sh
# sudo ./odoo_install.sh
################################################################################

set -euo pipefail
umask 027

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root or with sudo." >&2
    exit 1
fi

OE_USER="odoo"
OE_HOME="/opt/${OE_USER}"
OE_HOME_SERVER="${OE_HOME}/${OE_USER}-server"
OE_HOME_VENV="${OE_HOME}/${OE_USER}-venv"

# Set the default Odoo port
OE_PORT="8016"
# Choose the Odoo version to install (e.g., 17.0, 16.0, 15.0)
OE_VERSION="17.0"
# Set to True to install the Odoo enterprise version
IS_ENTERPRISE="False"
# Set to True to install Nginx
INSTALL_NGINX="True"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True", a random password will be generated
OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
# Set the website domain / name (use "_" for default catch-all)
WEBSITE_NAME="_"
# Set the default Odoo longpolling / websocket port
LONGPOLLING_PORT="8072"
# Set to True to install certbot and enable SSL
ENABLE_SSL="True"
# Provide an email to register the SSL certificate
ADMIN_EMAIL="odoo@example.com"
# Odoo controls database manager access. Set to False after provisioning a
# database and configuring db_name/dbfilter for this instance.
LIST_DB="True"
INIT_FILE="/etc/systemd/system/${OE_CONFIG}.service"

if [[ ! "$OE_USER" =~ ^[a-z_][a-z0-9_-]*$ || ! "$OE_VERSION" =~ ^[0-9]+\.0$ || ! "$OE_PORT" =~ ^[0-9]+$ || ! "$LONGPOLLING_PORT" =~ ^[0-9]+$ ]]; then
    echo 'Invalid instance settings.' >&2; exit 1
fi
if (( OE_PORT < 1024 || OE_PORT > 65535 || LONGPOLLING_PORT < 1024 || LONGPOLLING_PORT > 65535 || OE_PORT == LONGPOLLING_PORT )); then
    echo 'Use distinct unprivileged ports.' >&2; exit 1
fi
if [[ "$WEBSITE_NAME" != _ && ! "$WEBSITE_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo 'WEBSITE_NAME must be a DNS name.' >&2; exit 1
fi
if [[ "$INSTALL_NGINX" == True && "$WEBSITE_NAME" == _ ]]; then
    echo 'Set a unique WEBSITE_NAME for each public instance.' >&2; exit 1
fi
if [[ "$INSTALL_NGINX" == True && "$ENABLE_SSL" == True && "$ADMIN_EMAIL" == odoo@example.com ]]; then
    echo 'Set ADMIN_EMAIL to a real address before enabling SSL.' >&2; exit 1
fi
if [[ -e "$INIT_FILE" || -e "/etc/${OE_CONFIG}.conf" || -e "$OE_HOME" ]]; then
    echo "Instance $OE_CONFIG already exists; refusing to overwrite it." >&2; exit 1
fi
if ss -ltnH "( sport = :$OE_PORT or sport = :$LONGPOLLING_PORT )" | grep -q .; then
    echo 'An Odoo port is already in use.' >&2; exit 1
fi
if [[ "$INSTALL_NGINX" == True && -e "/etc/nginx/conf.d/odoo-${OE_CONFIG}.conf" ]]; then
    echo 'Nginx site already exists.' >&2; exit 1
fi

# Install packages inside the isolated virtual environment.
pip_install() {
  "$OE_HOME_VENV/bin/pip" install "$@"
}

# Check Python prerequisites
echo -e "\n---- Checking Python environment ----"
apt-get update
apt-get install -y python3 python3-venv python3-dev git curl

# Ensure PostgreSQL service is active before role check/creation
echo -e "\n---- Ensuring PostgreSQL Service is active ----"
systemctl start postgresql

echo -e "\n---- Checking / Creating PostgreSQL User ----"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OE_USER'" | grep -q 1; then
    echo "Creating PostgreSQL role: $OE_USER"
    sudo -u postgres createuser --createdb --no-superuser --no-createrole "$OE_USER"
else
    echo "PostgreSQL user role '$OE_USER' already exists."
fi

echo -e "\n---- Create ODOO system user ----"
if ! id "$OE_USER" &>/dev/null; then
    adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"
else
    echo "System user $OE_USER already exists."
fi

echo -e "\n---- Configure Python venv ----"
mkdir -p "$OE_HOME"
python3 -m venv "$OE_HOME_VENV"
pip_install wheel

echo -e "\n---- Install Odoo Python Requirements ----"
curl --fail --show-error --silent --location "https://raw.githubusercontent.com/odoo/odoo/${OE_VERSION}/requirements.txt" -o "$OE_HOME/requirements.txt"
pip_install -r "$OE_HOME/requirements.txt"

echo -e "\n---- Create Log directory ----"
mkdir -p "/var/log/$OE_USER"
chown -R "$OE_USER:$OE_USER" "/var/log/$OE_USER"

echo -e "\n---- Configure automatic Odoo log rotation (30 daily files) ----"
cat <<EOF > "/etc/logrotate.d/${OE_CONFIG}"
/var/log/${OE_USER}/${OE_CONFIG}.log {
    daily
    rotate 30
    copytruncate
    delaycompress
    compress
    notifempty
    missingok
}
EOF
chmod 644 "/etc/logrotate.d/${OE_CONFIG}"

#--------------------------------------------------
# Install ODOO Server Core
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server Core ===="
if [ -d "$OE_HOME_SERVER" ]; then
    echo "Directory $OE_HOME_SERVER already exists. Updating source..."
    git -C "$OE_HOME_SERVER" pull --ff-only
else
    git clone --depth 1 --branch "$OE_VERSION" https://www.github.com/odoo/odoo "$OE_HOME_SERVER"
fi

if [ "$IS_ENTERPRISE" = "True" ]; then
    echo -e "\n==== Installing ODOO Enterprise Addons ===="
    pip_install psycopg2-binary pdfminer.six num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    
    mkdir -p "$OE_HOME/enterprise/addons"
    if [ -d "$OE_HOME/enterprise/addons/.git" ]; then
        git -C "$OE_HOME/enterprise/addons" pull --ff-only
    else
        git clone --depth 1 --branch "$OE_VERSION" https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons"
    fi
fi

echo -e "\n---- Creating Custom Addons & Backups directories ----"
mkdir -p "$OE_HOME/custom/addons"
mkdir -p "$OE_HOME/backups"

echo -e "\n---- Setting permissions on Odoo home folder ----"
chown -R "$OE_USER:$OE_USER" "$OE_HOME"

#--------------------------------------------------
# Create Odoo Configuration File
#--------------------------------------------------
echo -e "\n---- Creating Server Config File ----"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
    echo "* Generating random superadmin password..."
    OE_SUPERADMIN=$(openssl rand -hex 24)
fi

# Build correct addons path
if [ "$IS_ENTERPRISE" = "True" ]; then
    ADDONS_PATH="${OE_HOME}/enterprise/addons,${OE_HOME_SERVER}/addons,${OE_HOME}/custom/addons"
else
    ADDONS_PATH="${OE_HOME_SERVER}/addons,${OE_HOME}/custom/addons"
fi

cat <<EOF > "/etc/${OE_CONFIG}.conf"
[options]
; This is the password that allows database operations:
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
http_interface = 127.0.0.1
workers = 2
max_cron_threads = 1
gevent_port = ${LONGPOLLING_PORT}
longpolling_port = ${LONGPOLLING_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path = ${ADDONS_PATH}
list_db = ${LIST_DB}
EOF

if [ "$INSTALL_NGINX" = "True" ]; then
    echo "proxy_mode = True" >> "/etc/${OE_CONFIG}.conf"
fi

chown "$OE_USER:$OE_USER" "/etc/${OE_CONFIG}.conf"
chmod 640 "/etc/${OE_CONFIG}.conf"

#--------------------------------------------------
# Create Startup Helper Script
#--------------------------------------------------
echo -e "\n---- Creating start.sh helper ----"
cat <<EOF > "$OE_HOME_SERVER/start.sh"
#!/bin/sh
sudo -u $OE_USER $OE_HOME_VENV/bin/python3 $OE_HOME_SERVER/odoo-bin -c /etc/${OE_CONFIG}.conf
EOF
chmod 755 "$OE_HOME_SERVER/start.sh"
chown "$OE_USER:$OE_USER" "$OE_HOME_SERVER/start.sh"

#--------------------------------------------------
# Adding ODOO as Systemd Daemon
#--------------------------------------------------
echo -e "\n---- Creating Systemd Service Unit ----"
cat <<EOF > "$INIT_FILE"
[Unit]
Description=ODOO Application Server ($OE_CONFIG)
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
PermissionsStartOnly=true
User=$OE_USER
Group=$OE_USER
UMask=0027
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ReadWritePaths=$OE_HOME /var/log/$OE_USER
SyslogIdentifier=$OE_CONFIG
ExecStart=$OE_HOME_VENV/bin/python3 $OE_HOME_SERVER/odoo-bin -c /etc/$OE_CONFIG.conf
StandardOutput=journal+console
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$INIT_FILE"
systemctl daemon-reload
systemctl enable "$OE_CONFIG.service"

echo -e "\n---- Starting ODOO Service ----"
systemctl restart "$OE_CONFIG.service"

#--------------------------------------------------
# Configure Nginx reverse proxy for this Odoo instance
#--------------------------------------------------
if [ "$INSTALL_NGINX" = "True" ]; then
    echo -e "\n---- Configuring Nginx ----"
    # Keep each instance's Nginx logs in its own directory, outside the
    # distribution's /var/log/nginx/*.log rotation rule.
    install -d -m 0755 "/var/log/nginx/odoo-${OE_CONFIG}"
    # Add this instance's access and error logs to logrotate as well.
    cat <<EOF >> "/etc/logrotate.d/${OE_CONFIG}"
/var/log/nginx/odoo-${OE_CONFIG}/access.log /var/log/nginx/odoo-${OE_CONFIG}/error.log {
    daily
    rotate 30
    copytruncate
    delaycompress
    compress
    notifempty
    missingok
}
EOF
    logrotate --debug "/etc/logrotate.d/${OE_CONFIG}" >/dev/null
    
    # Ensure global websocket map exists in conf.d
    mkdir -p /etc/nginx/conf.d
    cat <<'EOF' > /etc/nginx/conf.d/odoo_websocket_map.conf
# Global Odoo websocket connection upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

    # Determine site config filename
    if [ "$WEBSITE_NAME" = "_" ] || [ -z "$WEBSITE_NAME" ]; then
        NGINX_SITE="$OE_CONFIG"
        SERVER_DOMAIN="_"
    else
        NGINX_SITE="$WEBSITE_NAME"
        SERVER_DOMAIN="$WEBSITE_NAME"
    fi

    # Create instance-specific Nginx site.
    cat <<EOF > "/etc/nginx/conf.d/odoo-${OE_CONFIG}.conf"
# Odoo Server Upstreams (Instance-specific to support multi-instance)
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

    # Log files
    access_log /var/log/nginx/odoo-${OE_CONFIG}/access.log;
    error_log /var/log/nginx/odoo-${OE_CONFIG}/error.log;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Redirect websocket requests to odoo gevent/longpolling port
    location /websocket {
        proxy_pass http://odoochat_${OE_CONFIG};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Redirect requests to odoo backend server
    location / {
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
        proxy_pass http://odoo_${OE_CONFIG};

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
        proxy_cookie_flags session_id samesite=lax secure;
    }

    # Common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
EOF

    # nginx.org packages include conf.d directly.

    if nginx -t; then
        systemctl reload nginx
        echo "Nginx configured successfully at /etc/nginx/conf.d/odoo-${OE_CONFIG}.conf"
    else
        echo "Nginx configuration check failed." >&2; exit 1
    fi

    # Certbot SSL Setup
    if [ "$ENABLE_SSL" = "True" ] && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
        echo -e "\n---- Enabling SSL with Certbot ----"
        certbot --nginx -d "$WEBSITE_NAME" --noninteractive --agree-tos --email "$ADMIN_EMAIL" --redirect
        systemctl reload nginx
    fi
fi

# Ensure final permissions on home folder
chown -R "$OE_USER:$OE_USER" "$OE_HOME"

echo -e "\n-----------------------------------------------------------"
echo -e " Done! The Odoo server instance is installed and running."
echo -e " Specifications:"
echo -e " Port: $OE_PORT"
echo -e " Longpolling Port: $LONGPOLLING_PORT"
echo -e " System Service: $OE_CONFIG.service"
echo -e " Configuration File: /etc/${OE_CONFIG}.conf"
echo -e " Log File: /var/log/$OE_USER/${OE_CONFIG}.log"
echo -e " Log Rotation: /etc/logrotate.d/${OE_CONFIG} (30 days retention)"
echo -e " PostgreSQL User: $OE_USER"
echo -e " Code Location: $OE_HOME_SERVER"
echo -e " Custom Addons Folder: $OE_HOME/custom/addons"
echo -e " Database Superadmin Password: $OE_SUPERADMIN"
echo -e " Start Command: systemctl start $OE_CONFIG.service"
echo -e " Stop Command: systemctl stop $OE_CONFIG.service"
echo -e " Restart Command: systemctl restart $OE_CONFIG.service"
if [ "$INSTALL_NGINX" = "True" ]; then
    echo -e " Nginx Config File: /etc/nginx/conf.d/odoo-${OE_CONFIG}.conf"
fi
echo -e "-----------------------------------------------------------"
