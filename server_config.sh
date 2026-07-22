#!/bin/bash
################################################################################
# Script for Configuring server to install multiple Odoo instances.
# Modified by: Ameer Almughalis
#-------------------------------------------------------------------------------
# This script will configure the Odoo requirements so 
# odoo_install.sh can install multiple Odoo instances.
#-------------------------------------------------------------------------------
# How to use:
# sudo chmod +x server_config.sh
# sudo ./server_config.sh
################################################################################

set -eo pipefail

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root or with sudo." >&2
    exit 1
fi

# Installs PostgreSQL V16 instead of defaults (e.g., V12 for Ubuntu 20/22) - this improves performance
INSTALL_POSTGRESQL_SIXTEEN="True"

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
apt-get update
apt-get upgrade -y
apt-get install -y libpq-dev curl gnupg2 lsb-release ca-certificates software-properties-common

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing PostgreSQL V16 due to user's choice ----"
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg --yes
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    apt-get update
    apt-get install -y postgresql-16 postgresql-client-16
else
    echo -e "\n---- Installing standard PostgreSQL version ----"
    apt-get install -y postgresql postgresql-contrib postgresql-server-dev-all
fi

# Ensure PostgreSQL service is enabled and running
echo -e "\n---- Enabling and starting PostgreSQL service ----"
systemctl enable postgresql
systemctl start postgresql

#--------------------------------------------------
# Install Python3 & Build Dependencies
#--------------------------------------------------
echo -e "\n--- Installing Python 3, pip3, and system dependencies ---"
apt-get install -y python3 python3-pip python3-cffi python3-dev python3-venv python3-wheel python3-setuptools \
    git build-essential wget gdebi-core \
    libxslt1-dev libzip-dev libldap2-dev libsasl2-dev libpng-dev libjpeg-dev libssl-dev libxml2-dev

#--------------------------------------------------
# Install Node.js & npm & rtlcss
#--------------------------------------------------
echo -e "\n---- Installing Node.js, npm, and rtlcss for LTR/RTL support ----"
apt-get install -y nodejs npm
npm install -g rtlcss

#--------------------------------------------------
# Install wkhtmltopdf
#--------------------------------------------------
echo -e "\n---- Installing wkhtmltopdf ----"
WKHTMLTOX_DEB="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
WKHTMLTOX_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/$WKHTMLTOX_DEB"

if [ ! -f "$WKHTMLTOX_DEB" ]; then
    echo "Downloading $WKHTMLTOX_DEB..."
    wget -q "$WKHTMLTOX_URL" || true
fi

if [ -f "$WKHTMLTOX_DEB" ]; then
    apt-get install -y ./$WKHTMLTOX_DEB || apt-get install -f -y
else
    echo "Falling back to apt repository wkhtmltopdf..."
    apt-get install -y wkhtmltopdf
fi

# Link binaries if present in /usr/local/bin
if [ -f /usr/local/bin/wkhtmltopdf ]; then
    ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
    ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
fi

#--------------------------------------------------
# Install Nginx & Configure Global Websocket Map
#--------------------------------------------------
echo -e "\n---- Installing Nginx ----"
apt-get install -y nginx

# Add global Nginx connection upgrade map for Odoo websockets (prevents duplicate map definitions across multiple instances)
echo -e "\n---- Setting up global Nginx websocket map configuration ----"
cat <<'EOF' > /etc/nginx/conf.d/odoo_websocket_map.conf
# Global Odoo websocket connection upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

systemctl enable nginx
systemctl restart nginx

#--------------------------------------------------
# Install SSL with certbot
#--------------------------------------------------
echo -e "\n---- Installing certbot ----"
apt-get update -y
apt-get install -y snapd
snap install core; snap refresh core
snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

echo -e "\n==========================================================="
echo -e " Server configuration finished successfully!"
echo -e " You can now run ./odoo_install.sh to install Odoo instances."
echo -e "==========================================================="
