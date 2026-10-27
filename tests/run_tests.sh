#!/usr/bin/env bash
# Master test suite runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================================================"
echo " Running Automated Test Suite for Odoo Multi-Instance Installer"
echo "================================================================================"

FAILED=0

for test_script in "$SCRIPT_DIR"/test_*.sh; do
    echo ""
    echo "--- Running $(basename "$test_script") ---"
    if bash "$test_script"; then
        echo "--> SUCCESS: $(basename "$test_script")"
    else
        echo "--> FAILED: $(basename "$test_script")" >&2
        FAILED=1
    fi
done

echo ""
echo "================================================================================"
if [[ "$FAILED" -eq 0 ]]; then
    echo " ALL TESTS PASSED SUCCESSFULLY!"
    echo "================================================================================"
    exit 0
else
    echo " SOME TESTS ENCOUNTERED FAILURES!" >&2
    echo "================================================================================"
    exit 1
fi
