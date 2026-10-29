#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

usage() {
  cat <<'USAGE'
Codex Account Manager: Clanked Edition

Usage:
  codex-account-manager [interactive]
  codex-account-manager capture <profile>
  codex-account-manager import-home <profile> <codex-home>
  codex-account-manager replace-auth <profile> <codex-home>
  codex-account-manager switch <profile> [--no-open]
  codex-account-manager make-active <profile>
  codex-account-manager make-state <profile>
  codex-account-manager list [--plain]
  codex-account-manager active
  codex-account-manager active-state
  codex-account-manager rename <old-profile> <new-profile>
  codex-account-manager import-auth <profile> <auth-json>
  codex-account-manager export-profile <profile> <zip-path>
  codex-account-manager delete <profile>
  codex-account-manager open-folder

The macOS build provides the SwiftUI app. Linux uses the Qt desktop UI; pass
"interactive" to open the terminal menu instead.
Linux account changes require Codex to be closed first.

Environment overrides:
  SWITCHER_HOME       Profile storage directory
  CODEX_AUTH_FILE     Codex CLI auth file, default ~/.codex/auth.json
  CODEX_APP_SUPPORT   Codex Desktop state directory (macOS or XDG config)
  CODEX_APP_NAME      macOS app name, default Codex
  CODEX_DESKTOP_ID    Linux desktop application id, default chatgpt
USAGE
}

source "$ROOT_DIR/lib/platform.sh"
source "$ROOT_DIR/lib/store.sh"
source "$ROOT_DIR/lib/identity.sh"
source "$ROOT_DIR/lib/profiles.sh"
source "$ROOT_DIR/lib/commands.sh"

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    interactive) cmd_interactive "$@" ;;
    capture) cmd_capture "$@" ;;
    import-home) cmd_import_home "$@" ;;
    save-auth) cmd_save_auth "$@" ;;
    replace-auth) cmd_replace_auth "$@" ;;
    make-active|make-default) cmd_make_active "$@" ;;
    make-state) cmd_make_state "$@" ;;
    switch) cmd_switch "$@" ;;
    list) cmd_list "$@" ;;
    active) cmd_active ;;
    verified-active) resolve_live_profile ;;
    profile-valid) validate_saved_profile_auth "$@" ;;
    record-active) cmd_record_active "$@" ;;
    active-state) cmd_active_state ;;
    rename) cmd_rename "$@" ;;
    import-auth) cmd_import_auth "$@" ;;
    export-profile) cmd_export_profile "$@" ;;
    delete) cmd_delete "$@" ;;
    open-folder) cmd_open_folder ;;
    -h|--help|help|"") usage ;;
    *) fail "unknown command: $command" ;;
  esac
}

main "$@"
