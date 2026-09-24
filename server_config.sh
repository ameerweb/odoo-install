#!/usr/bin/env bash
################################################################################
# Script for configuring a server to run multiple isolated Odoo instances.
# Modified by: Ameer Almughalis
#-------------------------------------------------------------------------------
# Run this script once before odoo_install.sh.
# How to use:
# sudo chmod +x server_config.sh
# sudo ./server_config.sh
################################################################################

set -euo pipefail
# Ensure the script is run as root and on a supported Ubuntu release.
if (( EUID != 0 )); then echo 'Run as root (sudo).' >&2; exit 1; fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ! ${VERSION_ID:-} =~ ^(22\.04|24\.04)$ ]]; then
    echo 'Only Ubuntu 22.04 and 24.04 LTS are supported.' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
#--------------------------------------------------
# Update server and install PostgreSQL, Python and build dependencies
#--------------------------------------------------
apt-get update
apt-get upgrade -y
#--------------------------------------------------
# Install PostgreSQL Server
# Install Python 3 and Build Dependencies
# Install Node.js and npm for rtlcss
# Install wkhtmltopdf from the Ubuntu package repository
#--------------------------------------------------
apt-get install -y ca-certificates curl gnupg lsb-release postgresql postgresql-contrib \
    python3 python3-pip python3-dev python3-venv python3-wheel python3-setuptools \
    git sudo build-essential libpq-dev libxslt1-dev libzip-dev libldap2-dev libsasl2-dev \
    libpng-dev libjpeg-dev libssl-dev libxml2-dev nodejs npm wkhtmltopdf logrotate
# Ensure PostgreSQL is enabled before instances create their own roles.
systemctl enable --now postgresql
# Install Node.js rtlcss support for right-to-left layouts.
npm install -g rtlcss

#--------------------------------------------------
# Install Nginx and Configure Global Websocket Map
# Install current stable Nginx from the signed nginx.org repository
# Ubuntu's apt install nginx can provide the distribution's 1.24 build.
#--------------------------------------------------
install -d -m 0755 /usr/share/keyrings
key_tmp=$(mktemp)
trap 'rm -f "$key_tmp"' EXIT
curl --fail --show-error --silent --location https://nginx.org/keys/nginx_signing.key -o "$key_tmp"
gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg "$key_tmp"
chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg
printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu %s nginx\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/nginx.list
cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
EOF
# Refresh successfully before selecting a version; do not use stale indexes
# when a repository cannot be reached.
apt-get -o APT::Update::Error-Mode=any update

# Select the newest package published in the nginx.org STABLE repository for
# this Ubuntu release and architecture. No release number is hardcoded here.
# Explicit selection prevents falling back to Ubuntu's distribution package.
nginx_versions=$(apt-cache madison nginx | awk -F '|' '
    $3 ~ /https:\/\/nginx[.]org\/packages\/ubuntu[[:space:]]/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
    }')
nginx_version=""
for version in $nginx_versions; do
    if [[ -z "$nginx_version" ]] || dpkg --compare-versions "$version" gt "$nginx_version"; then
        nginx_version="$version"
    fi
done
if [[ -z "$nginx_version" ]]; then
    echo 'No Nginx stable package found at nginx.org for this host. Installation stopped.' >&2
    exit 1
fi
echo "Installing latest nginx.org stable package: $nginx_version"
apt-get install -y "nginx=$nginx_version"
installed_version=$(dpkg-query -W -f='${Version}' nginx)
if [[ "$installed_version" != "$nginx_version" ]]; then
    echo "Expected Nginx $nginx_version, but found $installed_version." >&2
    exit 1
fi
echo "Installed $(nginx -v 2>&1)"
apt-cache policy nginx
systemctl enable --now nginx
nginx -t
# Add a single global websocket map shared by all instances.
install -d -m 0755 /etc/nginx/conf.d
cat > /etc/nginx/conf.d/odoo_websocket_map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF
nginx -t && systemctl reload nginx
#--------------------------------------------------
# Install SSL with certbot
#--------------------------------------------------
apt-get install -y certbot python3-certbot-nginx
echo 'Host ready. Review nginx -v and apt-cache policy nginx.'
