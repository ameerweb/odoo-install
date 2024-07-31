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

# Installs PostgreSQL V14 instead of defaults (e.g., V12 for Ubuntu 20/22) - this improves performance
INSTALL_POSTGRESQL_FOURTEEN="True"

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n---- Update Server ----"
# universe package is for Ubuntu 18.x
sudo add-apt-repository universe
sudo add-apt-repository "deb http://mirrors.kernel.org/ubuntu/ xenial main"
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install libpq-dev -y

#--------------------------------------------------
# Install PostgreSQL Server
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL Server ----"
if [ $INSTALL_POSTGRESQL_FOURTEEN = "True" ]; then
    echo -e "\n---- Installing postgreSQL V14 due to the user it's choice ----"
    sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    sudo apt-get update
    sudo apt-get install postgresql-14 -y
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
sudo dpkg -i wkhtmltox_0.12.5-1.jammy_amd64.deb
sudo ln -s /usr/local/bin/wkhtmltopdf /usr/bin
sudo ln -s /usr/local/bin/wkhtmltoimage /usr/bin

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
sudo apt-get install python3-certbot-nginx -y

echo -e "\n---- Server configuration finished successfully ----"
