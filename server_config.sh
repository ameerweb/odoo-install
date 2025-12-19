#!/bin/bash
################################################################################
# Script for Configuring server to install multiple Odoo instances.
# Modified by: Ameer Almughalis
#-------------------------------------------------------------------------------
# This script will configure the Odoo requirements so 
# install_script.sh can install multiple Odoo instances.
#-------------------------------------------------------------------------------
# How to use:
# sudo chmod +x server_config.sh
# ./server_config.sh
################################################################################

# Installs PostgreSQL V16 instead of defaults (e.g., V12 for Ubuntu 20/22) - this improves performance
INSTALL_POSTGRESQL_SIXTEEN="True"

# Exit immediately if a command exits with a non-zero status
set -e

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install libpq-dev -y

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ "$INSTALL_POSTGRESQL_SIXTEEN" = "True" ]; then
    echo -e "\n---- Installing postgreSQL V16 due to the user's choice ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update
    sudo apt-get install postgresql-16 -y
    
    # Install pgvector for Enterprise AI features (optional but recommended for modern Odoo)
    # sudo apt-get install -y postgresql-16-pgvector
else
    echo -e "\n---- Installing the default postgreSQL version based on Linux version ----"
    sudo apt-get install postgresql postgresql-server-dev-all -y
fi

#--------------------------------------------------
# Install Python3 & pip3
#--------------------------------------------------
echo -e "\n--- Installing Python 3 + pip3 ---"
sudo apt-get install python3 python3-pip -y
sudo apt-get install git python3-cffi build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi -y

#--------------------------------------------------
# Install Node.js & npm & rtlcss
#--------------------------------------------------
echo -e "\n---- Installing Node.js, npm, and rtlcss for LTR support ----"
sudo apt-get install nodejs npm -y
sudo npm install -g rtlcss

#--------------------------------------------------
# Install wkhtmltopdf
#--------------------------------------------------
echo -e "\n---- Installing wkhtmltopdf ----"

# Install the patched version of wkhtmltopdf.
echo "Downloading and installing wkhtmltopdf with patched QT..."

WKHTMLTOX_DEB="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
WKHTMLTOX_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/$WKHTMLTOX_DEB"

# Download the package if it doesn't already exist.
if [ ! -f "$WKHTMLTOX_DEB" ]; then
    echo "Downloading $WKHTMLTOX_DEB..."
    wget "$WKHTMLTOX_URL"
fi

# Install the package and its dependencies.
sudo apt-get install -y ./$WKHTMLTOX_DEB

# Link binaries
sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf || true
sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage || true


#--------------------------------------------------
# Install Nginx 
#--------------------------------------------------
echo -e "\n---- Installing Nginx ----"
sudo apt install nginx -y

#--------------------------------------------------
# Install SSL with certbot
#--------------------------------------------------
echo -e "\n---- Installing certbot ----"
sudo apt-get update -y
sudo apt install snapd -y
sudo snap install core; sudo snap refresh core
sudo snap install --classic certbot
# Link certbot command
sudo ln -s /snap/bin/certbot /usr/bin/certbot || true

echo -e "\n---- Server configuration finished successfully ----"
