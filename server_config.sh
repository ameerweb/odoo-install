#!/usr/bin/env bash
################################################################################
# Script for configuring a host server for isolated multi-instance Odoo setups.
# Original Author: Yenthe Van Ginneken
# Modified & Hardened by: Ameer Haider
#-------------------------------------------------------------------------------
# This script prepares an Ubuntu host with PostgreSQL, Python build dependencies,
# Nginx (official stable channel), Certbot, and Qt-patched wkhtmltopdf for RTL/Arabic.
#
# Run once per server before running odoo_install.sh.
# Usage:
#   sudo bash server_config.sh
################################################################################

set -euo pipefail

# 1. Privileges and OS Verification
if (( EUID != 0 )); then
    echo "Error: This script must be run as root (sudo)." >&2
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || ! "${VERSION_ID:-}" =~ ^(22\.04|24\.04)$ ]]; then
    echo "Error: Only Ubuntu 22.04 LTS (Jammy) and 24.04 LTS (Noble) are supported." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Configuring host server on Ubuntu ${VERSION_ID} (${VERSION_CODENAME})..."

# 2. Package Index Synchronization
# Refresh package lists without performing an unrequested full system upgrade
echo "==> Synchronizing APT package indexes..."
apt-get update

# 3. Base Dependencies, PostgreSQL, and Build Libraries
echo "==> Installing PostgreSQL, Python build tools, fonts, and base utilities..."
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release git sudo build-essential logrotate \
    postgresql postgresql-contrib libpq-dev \
    python3 python3-pip python3-dev python3-venv python3-wheel python3-setuptools \
    libxslt1-dev libzip-dev libldap2-dev libsasl2-dev \
    libpng-dev libjpeg-dev libssl-dev libxml2-dev \
    nodejs npm \
    fontconfig libfreetype6 libx11-6 libxcb1 libxext6 libxrender1 \
    xfonts-75dpi xfonts-base fonts-dejavu-core fonts-noto-core

# Ensure PostgreSQL service is active and enabled on boot
systemctl enable --now postgresql

# Install rtlcss for Right-To-Left web interface styling support in Odoo
echo "==> Installing Node.js rtlcss for RTL layout compilation..."
npm install -g rtlcss

# 4. Qt-patched wkhtmltopdf for Arabic/RTL Reports
# Ubuntu default packages lack patched Qt WebKit, breaking headers, footers, and Arabic shaping.
echo "==> Verifying Qt-patched wkhtmltopdf..."
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64)
        WKHTMLTOX_DEB="wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
        WKHTMLTOX_SHA256="4f723b2691ad8638a9df960e0421d346d7315083e3583a334f33362280ddba15"
        ;;
    arm64)
        WKHTMLTOX_DEB="wkhtmltox_0.12.6.1-3.jammy_arm64.deb"
        WKHTMLTOX_SHA256="2095f20256661ebf0983b9311168596c9d012666e21a94bc24f304db6ac69ec5"
        ;;
    *)
        echo "Error: Unsupported architecture: $ARCH. wkhtmltopdf requires amd64 or arm64." >&2
        exit 1
        ;;
esac

CURRENT_WK_VER="$(wkhtmltopdf --version 2>&1 || true)"
wk_ver_pattern="0.12.6"
wk_qt_pattern="with patched qt"
if [[ "$CURRENT_WK_VER" =~ $wk_ver_pattern && "$CURRENT_WK_VER" =~ $wk_qt_pattern ]]; then
    echo "Qt-patched wkhtmltopdf is already installed ($CURRENT_WK_VER)."
else
    echo "Installing Qt-patched wkhtmltopdf ($WKHTMLTOX_DEB)..."
    TMP_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap 'rm -rf "$TMP_DIR"' EXIT

    WKHTMLTOX_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/${WKHTMLTOX_DEB}"
    curl --fail --show-error --silent --location "$WKHTMLTOX_URL" -o "$TMP_DIR/$WKHTMLTOX_DEB"

    # Cryptographic integrity check
    ACTUAL_SHA256="$(sha256sum "$TMP_DIR/$WKHTMLTOX_DEB" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" != "$WKHTMLTOX_SHA256" ]]; then
        echo "Error: SHA-256 verification failed for $WKHTMLTOX_DEB!" >&2
        echo "Expected: $WKHTMLTOX_SHA256" >&2
        echo "Actual:   $ACTUAL_SHA256" >&2
        exit 1
    fi

    echo "SHA-256 verified. Installing package..."
    apt-get install -y --no-install-recommends "$TMP_DIR/$WKHTMLTOX_DEB" || apt-get install -f -y

    # Ensure symlinks exist in standard execution paths
    if [[ -f /usr/local/bin/wkhtmltopdf && ! -f /usr/bin/wkhtmltopdf ]]; then
        ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf
    fi
    if [[ -f /usr/local/bin/wkhtmltoimage && ! -f /usr/bin/wkhtmltoimage ]]; then
        ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
    fi

    rm -rf "$TMP_DIR"
    trap - EXIT
fi

echo "Verified: $(wkhtmltopdf --version 2>&1)"

# 5. Official Nginx Stable Repository & Global WebSocket Upgrade Map
echo "==> Configuring official nginx.org stable repository..."
install -d -m 0755 /usr/share/keyrings
KEY_TMP="$(mktemp)"
trap 'rm -f "$KEY_TMP"' EXIT

curl --fail --show-error --silent --location https://nginx.org/keys/nginx_signing.key -o "$KEY_TMP"
gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg "$KEY_TMP"
chmod 0644 /usr/share/keyrings/nginx-archive-keyring.gpg
rm -f "$KEY_TMP"
trap - EXIT

printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu %s nginx\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/nginx.list

cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: nginx
Pin: origin nginx.org
Pin-Priority: 900
EOF

# Refresh repository cache with the new Nginx repository
apt-get -o APT::Update::Error-Mode=any update

# Select newest stable package published by nginx.org for this distribution
NGINX_VERSIONS=$(apt-cache madison nginx | awk -F '|' '
    $3 ~ /https:\/\/nginx[.]org\/packages\/ubuntu[[:space:]]/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
    }')

SELECTED_NGINX=""
for ver in $NGINX_VERSIONS; do
    if [[ -z "$SELECTED_NGINX" ]] || dpkg --compare-versions "$ver" gt "$SELECTED_NGINX"; then
        SELECTED_NGINX="$ver"
    fi
done

if [[ -z "$SELECTED_NGINX" ]]; then
    echo "Error: No stable Nginx package found at nginx.org for $VERSION_CODENAME. Aborting." >&2
    exit 1
fi

echo "==> Installing nginx.org stable package: $SELECTED_NGINX"
apt-get install -y --no-install-recommends "nginx=$SELECTED_NGINX"

INSTALLED_NGINX="$(dpkg-query -W -f='${Version}' nginx)"
if [[ "$INSTALLED_NGINX" != "$SELECTED_NGINX" ]]; then
    echo "Error: Expected Nginx $SELECTED_NGINX, but installed $INSTALLED_NGINX." >&2
    exit 1
fi

systemctl enable --now nginx

# Ensure global WebSocket connection upgrade mapping exists for multi-instance upstreams
install -d -m 0755 /etc/nginx/conf.d
cat > /etc/nginx/conf.d/odoo_websocket_map.conf <<'EOF'
# Global Odoo WebSocket connection upgrade map
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

nginx -t && systemctl reload nginx

# 6. Certbot Installation for SSL/TLS Automation
echo "==> Installing Certbot and Nginx plugin..."
apt-get install -y --no-install-recommends certbot python3-certbot-nginx

echo ""
echo "================================================================================"
echo " Host configuration completed successfully!"
echo " - Distribution: Ubuntu ${VERSION_ID} (${VERSION_CODENAME})"
echo " - Nginx Version: $(nginx -v 2>&1)"
echo " - wkhtmltopdf:   $(wkhtmltopdf --version 2>&1)"
echo " - PostgreSQL:    $(systemctl is-active postgresql)"
echo " You may now configure and execute ./odoo_install.sh for each instance."
echo "================================================================================"
