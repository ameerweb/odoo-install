#!/bin/bash
################################################################################
# Script for installing Odoo on Ubuntu 16.04, 18.04, 20.04 and 22.04 (could be used for other version too)
# Author: Yenthe Van Ginneken
# modifyied by : Ameer Almughalis
#-------------------------------------------------------------------------------
# This script will install Odoo on your Ubuntu server. It can install multiple Odoo instances
# in one Ubuntu because of the different xmlrpc_ports
#-------------------------------------------------------------------------------
# how to use
# sudo chmod +x odoo-install.sh
# ./odoo-install
################################################################################

OE_USER="odoo"
OE_HOME="/opt/${OE_USER}"
OE_HOME_SERVER="${OE_HOME}/${OE_USER}-server"
OE_HOME_VENV="${OE_HOME}/${OE_USER}-venv"

# Set the default Odoo port (you still have to use -c /etc/odoo-server.conf for example to use this.)
OE_PORT="8016"
# Choose the Odoo version which you want to install. For example: 16.0, 15.0, 14.0 or saas-22. When using 'master' the master version will be installed.
# IMPORTANT! This script contains extra libraries that are specifically needed for Odoo 16.0
OE_VERSION="16.0"
# Set this to True if you want to install the Odoo enterprise version!
IS_ENTERPRISE="False"
# Set this to True if you want to install Nginx!
INSTALL_NGINX="True"
# Set the superadmin password - if GENERATE_RANDOM_PASSWORD is set to "True" we will automatically generate a random password, otherwise we use this one
OE_SUPERADMIN="admin"
# Set to "True" to generate a random password, "False" to use the variable in OE_SUPERADMIN
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
# Set the website name
WEBSITE_NAME="_"
# Set the default Odoo longpolling port (you still have to use -c /etc/odoo-server.conf for example to use this.)
LONGPOLLING_PORT="8072"
# Set to "True" to install certbot and have ssl enabled, "False" to use http
ENABLE_SSL="True"
# Provide Email to register ssl certificate
ADMIN_EMAIL="odoo@example.com"
# 
INIT_FILE=/etc/systemd/system/$OE_CONFIG.service


echo -e "\n---- Creating the ODOO PostgreSQL User  ----"
sudo su - postgres -c "createuser -s $OE_USER" 2> /dev/null || true

echo -e "\n---- Configure python venv  ----"
sudo python3 -m venv $OE_HOME_VENV
sudo $OE_HOME_VENV/bin/pip3 install wheel

echo -e "\n---- Install python packages/requirements ----"
sudo $OE_HOME_VENV/bin/pip3 install -r https://github.com/odoo/odoo/raw/${OE_VERSION}/requirements.txt


echo -e "\n---- Create ODOO system user ----"
sudo adduser --system --quiet --shell=/bin/bash --home=$OE_HOME --gecos 'ODOO' --group $OE_USER
#The user should also be added to the sudo'ers group.
sudo adduser $OE_USER sudo

echo -e "\n---- Create Log directory ----"
sudo mkdir /var/log/$OE_USER
sudo chown $OE_USER:$OE_USER /var/log/$OE_USER

#--------------------------------------------------
# Install ODOO
#--------------------------------------------------
echo -e "\n==== Installing ODOO Server ===="
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo $OE_HOME_SERVER

# TODO: if [ $IS_ENTERPRISE = "True" ]; section NEED to be updated 
if [ $IS_ENTERPRISE = "True" ]; then
    # Odoo Enterprise install!
    sudo pip3 install psycopg2-binary pdfminer.six
    echo -e "\n--- Create symlink for node"
    sudo ln -s /usr/bin/nodejs /usr/bin/node
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise"
    sudo su $OE_USER -c "mkdir $OE_HOME/enterprise/addons"

    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    while [[ $GITHUB_RESPONSE == *"Authentication"* ]]; do
        echo "------------------------WARNING------------------------------"
        echo "Your authentication with Github has failed! Please try again."
        printf "In order to clone and install the Odoo enterprise version you \nneed to be an offical Odoo partner and you need access to\nhttp://github.com/odoo/enterprise.\n"
        echo "TIP: Press ctrl+c to stop this script."
        echo "-------------------------------------------------------------"
        echo " "
        GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
    done

    echo -e "\n---- Added Enterprise code under $OE_HOME/enterprise/addons ----"
    echo -e "\n---- Installing Enterprise specific libraries ----"
    sudo -H pip3 install num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
    sudo npm install -g less
    sudo npm install -g less-plugin-clean-css
fi

echo -e "\n---- Create custom module directory ----"
sudo mkdir /var/log/$OE_USER
sudo mkdir $OE_HOME/custom
sudo mkdir $OE_HOME/custom/addons
sudo mkdir $OE_HOME/backups

echo -e "\n---- Setting permissions on home folder ----"
sudo chown -R $OE_USER:$OE_USER $OE_HOME
sudo chown -R $OE_USER:$OE_USER $OE_HOME/*

echo -e "* Create server config file"

sudo touch /etc/${OE_CONFIG}.conf
echo -e "* Creating server config file"
sudo su root -c "printf '[options] \n; This is the password that allows database operations:\n' >> /etc/${OE_CONFIG}.conf"
if [ $GENERATE_RANDOM_PASSWORD = "True" ]; then
    echo -e "* Generating random admin password"
    OE_SUPERADMIN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
fi
sudo su root -c "printf 'admin_passwd = ${OE_SUPERADMIN}\n' >> /etc/${OE_CONFIG}.conf"
if [ $OE_VERSION > "11.0" ];then
    sudo su root -c "printf 'http_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
else
    sudo su root -c "printf 'xmlrpc_port = ${OE_PORT}\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo su root -c "printf 'logfile = /var/log/${OE_USER}/${OE_CONFIG}.log\n' >> /etc/${OE_CONFIG}.conf"

if [ $IS_ENTERPRISE = "True" ]; then
    sudo su root -c "printf 'addons_path=${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons\n' >> /etc/${OE_CONFIG}.conf"
else-
    sudo su root -c "printf 'addons_path=${OE_HOME_SERVER}/addons,${OE_HOME_SERVER}/custom/addons\n' >> /etc/${OE_CONFIG}.conf"
fi
sudo chown $OE_USER:$OE_USER /etc/${OE_CONFIG}.conf
sudo chmod 640 /etc/${OE_CONFIG}.conf

echo -e "* Create startup file"
sudo su root -c "echo '#!/bin/sh' >> $OE_HOME_SERVER/start.sh"
sudo su root -c "echo 'sudo -u $OE_USER $OE_HOME_SERVER/odoo-bin --config=/etc/${OE_CONFIG}.conf' >>  $OE_HOME_SERVER/start.sh"
sudo chmod 755 $OE_HOME_SERVER/start.sh

#--------------------------------------------------
# Adding ODOO as a deamon (initscript)
#--------------------------------------------------
sudo touch $INIT_FILE
sudo chmod 0700 $INIT_FILE

echo -e "* Create systemd unit file"
echo '[Unit]' >> $INIT_FILE
echo 'Description=ODOO Application Server' >> $INIT_FILE
echo 'Requires=postgresql.service' >> $INIT_FILE
echo 'After=network.target postgresql.service' >> $INIT_FILE
echo '[Install]' >> $INIT_FILE
echo "Alias=$OE_CONFIG.service" >> $INIT_FILE
echo '[Service]' >> $INIT_FILE
echo 'Type=simple' >> $INIT_FILE
echo 'PermissionsStartOnly=true' >> $INIT_FILE
echo "User=$OE_USER" >> $INIT_FILE
echo "Group=$OE_USER" >> $INIT_FILE
echo "SyslogIdentifier=$OE_CONFIG" >> $INIT_FILE
echo "ExecStart=$OE_HOME_VENV/bin/python3 $OE_HOME_SERVER/odoo-bin -c /etc/$OE_CONFIG.conf" >> $INIT_FILE
echo 'StandardOutput=journal+console' >> $INIT_FILE
echo '[Install]' >> $INIT_FILE
echo 'WantedBy=multi-user.target' >> $INIT_FILE

echo -e "* Enabling Systemd File"
sudo systemctl enable $INIT_FILE

echo -e "-- Starting ODOO Server --"
sudo systemctl start $OE_CONFIG.service

#--------------------------------------------------
# Install Nginx if needed
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ]; then
  cat <<EOF > ~/odoo
server {
  listen 80;

  # set proper server name after domain set
  server_name $WEBSITE_NAME;

  # Add Headers for odoo proxy mode
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP \$remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST \$remote_addr;

  #   odoo    log files
  access_log  /var/log/nginx/$OE_USER-access.log;
  error_log       /var/log/nginx/$OE_USER-error.log;

  #   increase    proxy   buffer  size
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;

  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;

  #   force   timeouts    if  the backend dies
  proxy_next_upstream error   timeout invalid_header  http_500    http_502
  http_503;

  types {
    text/less less;
    text/scss scss;
  }

  #   enable  data    compression
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:$OE_PORT;
    # by default, do not forward anything
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:$LONGPOLLING_PORT;
  }

  location ~* .(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:$OE_PORT;
    add_header Cache-Control "public, no-transform";
  }

  # cache some static data in memory for 60mins.
  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404      1m;
    proxy_buffering    on;
    expires 864000;
    proxy_pass    http://127.0.0.1:$OE_PORT;
  }
}
EOF

  sudo mv ~/odoo /etc/nginx/sites-available/$WEBSITE_NAME
  sudo ln -s /etc/nginx/sites-available/$WEBSITE_NAME /etc/nginx/sites-enabled/$WEBSITE_NAME
  sudo rm /etc/nginx/sites-enabled/default
  sudo service nginx reload
  sudo su root -c "printf 'proxy_mode = True\n' >> /etc/${OE_CONFIG}.conf"
  echo "Done! The Nginx server is up and running. Configuration can be found at /etc/nginx/sites-available/$WEBSITE_NAME"
else
  echo "Nginx isn't installed due to choice of the user!"
fi

#--------------------------------------------------
# Enable ssl with certbot
#--------------------------------------------------
if [ $INSTALL_NGINX = "True" ] && [ $ENABLE_SSL = "True" ] && [ $ADMIN_EMAIL != "odoo@example.com" ]  && [ $WEBSITE_NAME != "_" ];then
  sudo certbot --nginx -d $WEBSITE_NAME --noninteractive --agree-tos --email $ADMIN_EMAIL --redirect
  sudo service nginx reload
  echo "SSL/HTTPS is enabled!"
else
  echo "SSL/HTTPS isn't enabled due to choice of the user or because of a misconfiguration!"
  if $ADMIN_EMAIL = "odoo@example.com";then 
    echo "Certbot does not support registering odoo@example.com. You should use real e-mail address."
  fi
  if $WEBSITE_NAME = "_";then
    echo "Website name is set as _. Cannot obtain SSL Certificate for _. You should use real website address."
  fi
fi

echo -e "* Starting Odoo Service"
sudo systemctl start $OE_CONFIG.service
echo "-----------------------------------------------------------"
echo "Done! The Odoo server is up and running. Specifications:"
echo "Port: $OE_PORT"
echo "User service: $OE_USER"
echo "Configuraton file location: /etc/${OE_CONFIG}.conf"
echo "Logfile location: /var/log/$OE_USER"
echo "User PostgreSQL: $OE_USER"
echo "Code location: $OE_USER"
echo "Addons folder: $OE_USER/$OE_CONFIG/addons/"
echo "Password superadmin (database): $OE_SUPERADMIN"
echo "Start Odoo service: systemctl start $OE_CONFIG.service"
echo "Stop Odoo service: systemctl stop $OE_CONFIG.service"
echo "Restart Odoo service: systemctl restart $OE_CONFIG.service"
if [ $INSTALL_NGINX = "True" ]; then
  echo "Nginx configuration file: /etc/nginx/sites-available/$WEBSITE_NAME"
fi
echo "-----------------------------------------------------------"
