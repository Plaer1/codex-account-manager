#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/bin/codex-account-manager"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPLICATIONS_DIR="$DATA_HOME/applications"
DESKTOP_FILE="$APPLICATIONS_DIR/codex-account-manager.desktop"

command -v python3 >/dev/null 2>&1 || { echo 'error: Python 3 is required' >&2; exit 1; }
mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/resources" "$APPLICATIONS_DIR"
cp "$PACKAGE_DIR/codex-account-switcher.sh" "$INSTALL_DIR/"
cp "$PACKAGE_DIR/codex-account-manager" "$INSTALL_DIR/"
cp "$PACKAGE_DIR/ui-linux.py" "$PACKAGE_DIR/linux_services.py" "$PACKAGE_DIR/tray-indicator.py" "$INSTALL_DIR/"
cp "$PACKAGE_DIR/lib/"*.sh "$INSTALL_DIR/lib/"
cp "$PACKAGE_DIR/resources/AppIconClanked.png" "$INSTALL_DIR/resources/"
chmod 700 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/codex-account-switcher.sh" "$INSTALL_DIR/codex-account-manager" "$INSTALL_DIR/ui-linux.py" "$INSTALL_DIR/tray-indicator.py"
chmod 644 "$INSTALL_DIR/lib/"*.sh "$INSTALL_DIR/resources/AppIconClanked.png"

for rc_file in "$HOME/.profile" "$HOME/.bashrc"; do
  touch "$rc_file"
  python3 - "$rc_file" <<'PY'
import sys

path = sys.argv[1]
marker = "# Codex Account Manager"
path_line = 'export PATH="$HOME/bin/codex-account-manager:$PATH"'
try:
    with open(path, encoding="utf-8") as stream:
        lines = stream.readlines()
except FileNotFoundError:
    lines = []

kept_marker = False
kept_path = False
normalized = []
for line in lines:
    text = line.rstrip("\r\n")
    if text == marker:
        if kept_marker:
            continue
        kept_marker = True
    elif text == path_line:
        if kept_path:
            continue
        kept_path = True
    normalized.append(line)

if not kept_path:
    if normalized and not normalized[-1].endswith("\n"):
        normalized[-1] += "\n"
    if normalized and normalized[-1].strip():
        normalized.append("\n")
    if not kept_marker:
        normalized.append(marker + "\n")
    normalized.append(path_line + "\n")

with open(path, "w", encoding="utf-8") as stream:
    stream.writelines(normalized)
PY
done

escape_desktop_arg() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '%s' "$value"
}

exec_path="$(escape_desktop_arg "$INSTALL_DIR/codex-account-manager")"
icon_path="$(escape_desktop_arg "$INSTALL_DIR/resources/AppIconClanked.png")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Codex Account Manager
Comment=Manage local Codex account profiles
TryExec=$INSTALL_DIR/codex-account-manager
Exec="$exec_path"
Icon=$icon_path
Terminal=false
Categories=Utility;
EOF
chmod 644 "$DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
fi

printf 'Installed command: %s/codex-account-manager\n' "$INSTALL_DIR"
printf 'Installed desktop entry: %s\n' "$DESKTOP_FILE"
printf 'Open a new shell or run: source ~/.profile\n'
