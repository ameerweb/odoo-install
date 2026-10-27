#!/usr/bin/env bash
# Test 3: Preflight input validation & compatibility gates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/odoo_install.sh"

echo "==> [TEST] Testing preflight input validation & compatibility gates..."

run_preflight_test() {
    local test_name="$1"
    local expected_msg="$2"
    shift 2
    local overrides=("$@")

    local tmp_script
    tmp_script="$(mktemp)"
    cp "$INSTALL_SCRIPT" "$tmp_script"

    local env_vars=()
    # Replace variable assignments with test overrides or collect as env vars
    for override in "${overrides[@]}"; do
        local var_name="${override%%=*}"
        if grep -q "^${var_name}=" "$tmp_script"; then
            sed -i "s|^${var_name}=.*|${override}|" "$tmp_script"
        else
            env_vars+=("$override")
        fi
    done

    # Bypass root check and mock os-release & external services for test environment
    sed -i 's/(( EUID != 0 ))/false/' "$tmp_script"
    # shellcheck disable=SC2016
    sed -i 's/\. \/etc\/os-release/ID=ubuntu; VERSION_ID="${TEST_VERSION_ID:-24.04}"/' "$tmp_script"
    # Allow running in testing environment without requiring live daemons
    sed -i 's/for cmd in git python3 curl psql systemctl openssl;/for cmd in git python3 curl openssl;/' "$tmp_script"
    sed -i 's/if sudo -u postgres psql.*/if false; then/' "$tmp_script"
    # Cut execution right after preflight output
    sed -i '/==> Preflight checks passed successfully/a exit 0' "$tmp_script"

    local output
    output="$(env "${env_vars[@]}" bash "$tmp_script" 2>&1 || true)"
    rm -f "$tmp_script"

    if echo "$output" | grep -qi "$expected_msg"; then
        echo "  [PASS] $test_name (matched: '$expected_msg')"
    else
        echo "  [FAIL] $test_name" >&2
        echo "         Expected to match: '$expected_msg'" >&2
        echo "         Actual output:     $output" >&2
        exit 1
    fi
}

# 1. Reserved system user rejection
run_preflight_test "Reserved username 'root' rejection" \
    "reserved system user" \
    'OE_USER="root"'

run_preflight_test "Reserved username 'postgres' rejection" \
    "reserved system user" \
    'OE_USER="postgres"'

# 2. Invalid username format
run_preflight_test "Invalid characters in OE_USER" \
    "invalid characters" \
    'OE_USER="odoo@tenant"'

# 3. Privileged port (< 1024) rejection
run_preflight_test "Privileged port (80) rejection" \
    "unprivileged range" \
    'OE_PORT="80"'

# 4. Out of range port (> 65535) rejection
run_preflight_test "Out-of-range port (70000) rejection" \
    "unprivileged range" \
    'OE_PORT="70000"'

# 5. Duplicate port collision between HTTP and Longpolling
run_preflight_test "Duplicate port collision rejection" \
    "must be distinct" \
    'OE_PORT="8069"' 'LONGPOLLING_PORT="8069"'

# 6. Compatibility gate: Odoo 20 on Ubuntu 22.04 rejection
run_preflight_test "Odoo 20 on Ubuntu 22.04 compatibility gate rejection" \
    "Odoo 20.0 requires Python >= 3.12" \
    'OE_VERSION="20.0"' 'TEST_VERSION_ID=22.04'

# 7. SSL with catch-all domain rejection
run_preflight_test "SSL enabled with '_' website rejection" \
    "valid public DNS domain is required" \
    'INSTALL_NGINX="True"' 'ENABLE_SSL="True"' 'WEBSITE_NAME="_"'

# 8. SSL with placeholder email rejection
run_preflight_test "SSL enabled with default email rejection" \
    "real ADMIN_EMAIL is required" \
    'INSTALL_NGINX="True"' 'ENABLE_SSL="True"' 'WEBSITE_NAME="odoo.example.com"' 'ADMIN_EMAIL="odoo@example.com"'

echo "OK: All preflight validation and compatibility gate tests passed."
