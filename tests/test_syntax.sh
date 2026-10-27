#!/usr/bin/env bash
# Test 1: Bash syntax validation using `bash -n`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> [TEST] Validating shell syntax with 'bash -n'..."
find "$SCRIPT_DIR" -maxdepth 2 -name "*.sh" -print0 | while IFS= read -r -d '' script; do
    echo "  Checking $(basename "$script")..."
    bash -n "$script"
done

echo "OK: All shell scripts passed syntax validation."
