#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build/linux"

command -v bash >/dev/null 2>&1 || { echo 'error: bash is required' >&2; exit 1; }
PYTHON3="${CODEX_MANAGER_PYTHON:-/usr/bin/python3}"
command -v "$PYTHON3" >/dev/null 2>&1 || { echo 'error: Python 3 is required' >&2; exit 1; }
"$PYTHON3" -c 'from PySide6 import QtWidgets' 2>/dev/null || {
  echo 'error: Python PySide6 is required to build the Linux UI' >&2
  exit 1
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/lib" "$BUILD_DIR/resources"
cp "$ROOT_DIR/codex-account-switcher.sh" "$BUILD_DIR/"
cp "$ROOT_DIR/lib/"*.sh "$BUILD_DIR/lib/"
cp "$ROOT_DIR/resources/AppIconClanked.png" "$BUILD_DIR/resources/"
cp "$ROOT_DIR/install-linux.sh" "$BUILD_DIR/"
cp "$ROOT_DIR/codex-account-manager" "$BUILD_DIR/"
cp "$ROOT_DIR/ui-linux.py" "$ROOT_DIR/linux_services.py" "$ROOT_DIR/tray-indicator.py" "$BUILD_DIR/"
cp "$ROOT_DIR/LICENSE" "$BUILD_DIR/"
chmod 755 "$BUILD_DIR/codex-account-switcher.sh" "$BUILD_DIR/codex-account-manager" "$BUILD_DIR/install-linux.sh" "$BUILD_DIR/ui-linux.py" "$BUILD_DIR/tray-indicator.py"

printf 'Built Linux package: %s\n' "$BUILD_DIR"
