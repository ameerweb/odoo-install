#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu 20.04, 22.04, and 24.04
# Author: Yenthe Van Ginneken
# Modified by: Ameer Almughalis
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu server because of the different xmlrpc_ports.
#-------------------------------------------------------------------------------
# How to use:
# sudo chmod +x odoo_install.sh
# ./odoo_install.sh
################################################################################

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
# Set the website name
WEBSITE_NAME="_"
# Set the default Odoo longpolling port
LONGPOLLING_PORT="8072"
# Set to True to install certbot and enable SSL
ENABLE_SSL="True"
# Provide an email to register the SSL certificate
ADMIN_EMAIL="odoo@example.com"

INIT_FILE=/etc/systemd/system/$OE_CONFIG.service

# Helper: pip install with optional --break-system-packages (Ubuntu 24.04 / PEP 668)
pip_install() {
  if $OE_HOME_VENV/bin/pip3 help install 2>/dev/null | grep -q -- '--break-system-packages'; then
    $OE_HOME_VENV/bin/pip3 install --break-system-packages "$@"
  else
    $OE_HOME_VENV/bin/pip3 install "$@"
  fi
}

# Check Odoo version and install appropriate Python version
echo -e "\n---- Checking Odoo version ----"
if [[ $OE_VERSION == "17.0" || $OE_VERSION > "17.0" ]]; then
    echo -e "\n---- Installing Python 3.10+ ----"
    sudo apt-get update
    # Ubuntu 22.04 has python3.10, 24.04 has 3.12. We generally use the system default python3 for venv.
    sudo apt-get install -y python3 python3-venv python3-dev
    PYTHON_BIN=python3
else
    echo -e "\n---- Installing Python 3 ----"
    sudo apt-get update
    sudo apt-get install -y python3 python3-venv python3-dev
    PYTHON_BIN=python3
fi

echo -e "\n---- Creating the ODOO PostgreSQL User ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

echo -e "\n---- Configure Python venv ----"
sudo $PYTHON_BIN -m venv $OE_HOME_VENV
sudo $OE_HOME_VENV/bin/pip3 install wheel

echo -e "\n---- Install Python packages/requirements ----"
sudo $OE_HOME_VENV/bin/pip3 install -r https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt

echo -e "\n---- Create ODOO system user ----"
if ! id "$OE_USER" &>/dev/null; then
    sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
    sudo adduser $OE_USER sudo
else
    echo "User $OE_USER already exists."
fi

echo -e "\n---- Create Log directory ----"
sudo mkdir -p /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_SERVER

if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    sudo $OE_HOME_VENV/bin/pip3 install psycopg2-binary pdfminer.six
    echo -e "\n--- Create symlink for node"
    sudo ln -s /usr/bin/nodejs /usr/bin/node || true
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir -p $OE_HOME/enterprise/addons"
    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an official Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        echo " "
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done
    echo -e "\n---- Added Enterprise code under $OE_HOME/enterprise/addons ----"
    echo -e "\n---- Installing Enterprise specific libraries ----"
    sudo $OE_HOME_VENV/bin/pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

echo -e "\n---- Create custom module directory ----"
sudo mkdir -p $OE_HOME/custom
sudo mkdir -p $OE_HOME/custom/addons
sudo mkdir -p $OE_HOME/backups

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME

echo -e "* Create server config file"
sudo touch /etc/${OE_CONFIG}.conf

echo -e "* Creating server config file"
sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' > /etc/${OE_CONFIG}.conf"
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
if [[ $OE_VERSION > "11.0" ]]; then
    sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

if [ $IS_ENTERPRISE = "True" ]; then
    sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME}/addons\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'addons_path=${OE_HOME_SERVER}/addons,${OE_HOME}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo su root -c "echo '#!/bin/sh' > $OE_HOME_SERVER/start.sh"
sudo su root -c "echo 'sudo -u $OE_USER $OE_HOME_VENV/bin/python3 $OE_HOME_SERVER/odoo-bin --config=/etc/${OE_CONFIG}.conf' >>  $OE_HOME_SERVER/start.sh"
sudo chmod 755 $OE_HOME_SERVER/start.sh

#--------------------------------------------------
# Adding ODOO as a daemon (initscript)
#--------------------------------------------------
sudo touch $INIT_FILE
sudo chmod 0700 $INIT_FILE

echo -e "* Create systemd unit file"
cat <<EOF | sudo tee $INIT_FILE
[Unit]
Description=ODOO Application Server
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
PermissionsStartOnly=true
User=$OE_USER
Group=$OE_USER
SyslogIdentifier=$OE_CONFIG
ExecStart=$OE_HOME_VENV/bin/python3 $OE_HOME_SERVER/odoo-bin -c /etc/$OE_CONFIG.conf
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

echo -e "* Enabling Systemd File"
sudo systemctl daemon-reload
sudo systemctl enable $OE_CONFIG.service

echo -e "-- Starting ODOO Server --"
sudo systemctl start $OE_CONFIG.service

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
    cat <<EOF > /tmp/nginx_odoo
server {
    listen 80;
    server_name $WEBSITE_NAME;

    # Proxy headers
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;

    # Log files
    access_log /var/log/nginx/$OE_USER-access.log;
    error_log /var/log/nginx/$OE_USER-error.log;

    # Timeouts
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Redirect websocket requests to odoo gevent port
    location /websocket {
        proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    }

    # Redirect requests to odoo backend server
    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$OE_PORT;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    }

    # Common gzip
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
    gzip on;
}
EOF
    sudo mv /tmp/nginx_odoo /etc/nginx/sites-available/$WEBSITE_NAME
    sudo ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo service nginx reload
    sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"
    echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_NAME"
else
    echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable SSL with certbot
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ] && [ $WEBSITE_NAME != "_" ]; then
    sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
    sudo service nginx reload
    echo "SSL/HTTPS is enabled!"
else
    echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
fi

echo -e "* Starting Odoo Service"
sudo systemctl restart $OE_CONFIG.service
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuration file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_HOME"
echo "Addons folder: $OE_HOME/custom/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: systemctl start $OE_CONFIG.service"
echo "Stop Odoo service: systemctl stop $OE_CONFIG.service"
echo "Restart Odoo service: systemctl restart $OE_CONFIG.service"
if [ $INSTALL_NGINX = "True" ]; then
    echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
fi
echo "-----------------------------------------------------------"
