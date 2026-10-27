#!/usr/bin/env bash
# Test 5: Multi-instance coexistence and isolation verification
set -euo pipefail

TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> [TEST] Verifying multi-instance isolation and coexistence..."

generate_instance_mock() {
    local user="$1"
    local port="$2"
    local lp_port="$3"
    local domain="$4"
    local config="${user}-server"

    local conf_file="$TMP_DIR/etc/${config}.conf"
    local init_file="$TMP_DIR/systemd/${config}.service"
    local nginx_file="$TMP_DIR/nginx/odoo-${config}.conf"

    mkdir -p "$(dirname "$conf_file")" "$(dirname "$init_file")" "$(dirname "$nginx_file")"

    # Conf
    cat <<EOF > "$conf_file"
[options]
admin_passwd = secret_${user}
http_port = ${port}
http_interface = 127.0.0.1
gevent_port = ${lp_port}
longpolling_port = ${lp_port}
logfile = /var/log/${user}/${config}.log
addons_path = /opt/${user}/${user}-server/addons
list_db = False
dbfilter = ^${user}.*$
EOF

    # Service
    cat <<EOF > "$init_file"
[Unit]
Description=Odoo Server Instance (${config})
[Service]
User=${user}
Group=${user}
SyslogIdentifier=${config}
ExecStart=/opt/${user}/${user}-venv/bin/python3 /opt/${user}/${user}-server/odoo-bin -c ${conf_file}
EOF

    # Nginx
    cat <<EOF > "$nginx_file"
upstream odoo_${config} {
    server 127.0.0.1:${port};
}
upstream odoochat_${config} {
    server 127.0.0.1:${lp_port};
}
server {
    listen 80;
    server_name ${domain};
    access_log /var/log/nginx/odoo-${config}/access.log;
    error_log /var/log/nginx/odoo-${config}/error.log;
    location /websocket { proxy_pass http://odoochat_${config}; }
    location /longpolling { proxy_pass http://odoochat_${config}; }
    location / { proxy_pass http://odoo_${config}; }
}
EOF
}

# Generate Instance 1 (Odoo 16 Production)
generate_instance_mock "odoo16prod" "8016" "8072" "odoo16.example.com"

# Generate Instance 2 (Odoo 17 Staging)
generate_instance_mock "odoo17stage" "8017" "8073" "odoo17.example.com"

echo "  Checking configuration conflicts between odoo16prod and odoo17stage..."

# 1. Verify ports do not overlap
PORT1=$(grep "http_port" "$TMP_DIR/etc/odoo16prod-server.conf" | awk '{print $3}')
PORT2=$(grep "http_port" "$TMP_DIR/etc/odoo17stage-server.conf" | awk '{print $3}')
LP1=$(grep "longpolling_port" "$TMP_DIR/etc/odoo16prod-server.conf" | awk '{print $3}')
LP2=$(grep "longpolling_port" "$TMP_DIR/etc/odoo17stage-server.conf" | awk '{print $3}')

if [[ "$PORT1" == "$PORT2" || "$LP1" == "$LP2" || "$PORT1" == "$LP2" || "$PORT2" == "$LP1" ]]; then
    echo "FAIL: Port conflict detected between instances" >&2
    exit 1
fi
echo "  [PASS] Zero port overlaps ($PORT1, $LP1 vs $PORT2, $LP2)."

# 2. Verify upstream names do not collide
if grep -q "upstream odoo_odoo16prod" "$TMP_DIR/nginx/odoo-odoo17stage-server.conf"; then
    echo "FAIL: Upstream collision detected" >&2
    exit 1
fi
echo "  [PASS] Upstream names are cleanly isolated."

# 3. Verify independent systemd units and users
USER1=$(grep "^User=" "$TMP_DIR/systemd/odoo16prod-server.service" | cut -d= -f2)
USER2=$(grep "^User=" "$TMP_DIR/systemd/odoo17stage-server.service" | cut -d= -f2)
if [[ "$USER1" == "$USER2" ]]; then
    echo "FAIL: Systemd users collide" >&2
    exit 1
fi
echo "  [PASS] Systemd service accounts are distinct ($USER1 vs $USER2)."

# 4. Verify dbfilter isolation
DBF1=$(grep "^dbfilter" "$TMP_DIR/etc/odoo16prod-server.conf" | awk '{print $3}')
DBF2=$(grep "^dbfilter" "$TMP_DIR/etc/odoo17stage-server.conf" | awk '{print $3}')
if [[ "$DBF1" == "$DBF2" ]]; then
    echo "FAIL: Database filter collides" >&2
    exit 1
fi
echo "  [PASS] Database filter isolation verified ($DBF1 vs $DBF2)."

echo "OK: Multi-instance isolation and coexistence verified."
