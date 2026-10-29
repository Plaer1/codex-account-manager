#!/usr/bin/env bash

PLATFORM="${CODEX_MANAGER_PLATFORM:-$(uname -s)}"
APP_NAME="${CODEX_APP_NAME:-Codex}"

case "$PLATFORM" in
  Darwin)
    SWITCHER_HOME="${SWITCHER_HOME:-$HOME/Library/Application Support/CodexAccountSwitcher}"
    CODEX_APP_SUPPORT="${CODEX_APP_SUPPORT:-$HOME/Library/Application Support/Codex}"
    CODEX_DESKTOP_ID="${CODEX_DESKTOP_ID:-}"
    ;;
  Linux)
    SWITCHER_HOME="${SWITCHER_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/CodexAccountSwitcher}"
    CODEX_APP_SUPPORT="${CODEX_APP_SUPPORT:-${XDG_CONFIG_HOME:-$HOME/.config}/Codex}"
    CODEX_DESKTOP_ID="${CODEX_DESKTOP_ID:-chatgpt}"
    ;;
  *)
    fail "unsupported operating system: $PLATFORM"
    ;;
esac

PROFILES_DIR="$SWITCHER_HOME/profiles"
ACTIVE_FILE="$SWITCHER_HOME/active-profile"
ACTIVE_STATE_FILE="$SWITCHER_HOME/active-state-profile"
LOCK_DIR="$SWITCHER_HOME/.lock"
CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"

open_codex() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
  elif command -v gtk-launch >/dev/null 2>&1; then
    gtk-launch "$CODEX_DESKTOP_ID" >/dev/null 2>&1 || log "warning: could not launch desktop app '$CODEX_DESKTOP_ID'"
  else
    log "warning: gtk-launch is unavailable; start Codex from the desktop menu"
  fi
}

codex_is_running() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    pgrep -x "$APP_NAME" >/dev/null 2>&1
  else
    local process_name
    for process_name in chatgpt ChatGPT codex Codex; do
      if pgrep -x "$process_name" >/dev/null 2>&1; then
        return 0
      fi
    done
    return 1
  fi
}

quit_codex() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in {1..40}; do
      if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.25
    done
    fail "$APP_NAME did not quit; no auth or machine-state files were changed"
  elif codex_is_running; then
    fail "close Codex from the desktop first; no auth or machine-state files were changed"
  fi
}

open_path() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    /usr/bin/open "$1"
  else
    xdg-open "$1" >/dev/null 2>&1 || fail "could not open folder: $1"
  fi
}

archive_profile() {
  local source_dir="$1"
  local archive_path="$2"
  if [[ "$PLATFORM" == "Darwin" ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$source_dir" "$archive_path"
  else
    command -v zip >/dev/null 2>&1 || fail "zip is required to export profiles on Linux"
    (cd "$(dirname "$source_dir")" && zip -qr "$archive_path" "$(basename "$source_dir")")
  fi
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    fail "sha256sum or shasum is required to verify API-key profiles"
  fi
}
