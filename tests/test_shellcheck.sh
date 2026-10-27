#!/usr/bin/env bash
# Test 2: Static analysis using ShellCheck
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "Warning: ShellCheck is not installed. Skipping shellcheck test."
    exit 0
fi

echo "==> [TEST] Running ShellCheck static analysis..."
find "$SCRIPT_DIR" -maxdepth 2 -name "*.sh" -print0 | while IFS= read -r -d '' script; do
    echo "  Checking $(basename "$script")..."
    shellcheck -x "$script"
done

echo "OK: All shell scripts passed ShellCheck validation with zero warnings."
