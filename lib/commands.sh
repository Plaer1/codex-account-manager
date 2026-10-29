cmd_capture() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock
  [[ -s "$CODEX_AUTH_FILE" ]] || fail "current Codex auth file is missing or empty"
  if [[ -s "$(profile_auth_file "$name")" ]]; then
    profile_auth_matches_file "$name" "$CODEX_AUTH_FILE" || \
      fail "live auth belongs to a different account; refusing to overwrite profile '$name'"
  fi
  log "quitting $APP_NAME before capture"
  quit_codex
  capture_into_profile "$name"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
  if [[ -d "$(profile_app_support_dir "$name")" ]]; then
    printf '%s\n' "$name" | atomic_write_text "$ACTIVE_STATE_FILE"
  else
    rm -f "$ACTIVE_STATE_FILE"
  fi
  log "captured current Codex state as '$name'"
}

cmd_save_auth() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock
  validate_saved_profile_auth "$name"
  profile_auth_matches_file "$name" "$CODEX_AUTH_FILE" || \
    fail "live auth belongs to a different account; refusing to overwrite profile '$name'"
  log "quitting $APP_NAME before saving auth"
  quit_codex
  save_auth_into_profile "$name"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
  open_codex
  log "saved current Codex auth token into '$name'"
}

cmd_make_active() {
  local name="${1:-}"
  validate_profile_name "$name"
  # Account activation is deliberately separate from Desktop state selection.
  cmd_switch "$name"
}

cmd_make_state() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock
  [[ -d "$(profile_app_support_dir "$name")" ]] || \
    fail "profile '$name' has no Codex Desktop state; capture it first"

  log "quitting $APP_NAME before changing the current machine state"
  quit_codex
  if [[ -s "$CODEX_AUTH_FILE" ]] && resolve_live_profile >/dev/null 2>&1; then
    persist_live_auth
  else
    log "no uniquely matched saved live auth; changing Desktop state without an auth write"
  fi
  restore_state_from_profile "$name"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_STATE_FILE"
  log "made '$name' the current machine state"
  open_codex
}

restore_state_from_profile() {
  local name="$1"
  local app_src
  app_src="$(profile_app_support_dir "$name")"

  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -d "$app_src" ]] || fail "profile '$name' has no Codex Desktop state; capture it first"

  sync_dir_if_present "$app_src" "$CODEX_APP_SUPPORT"
}

switch_transaction_exit() {
  local status=$?
  if [[ "${SWITCH_TRANSACTION_ACTIVE:-0}" == "1" ]]; then
    SWITCH_TRANSACTION_ACTIVE=0
    if [[ -s "${SWITCH_TRANSACTION_DIR:-}/live-auth.json" ]]; then
      mkdir -p "$(dirname "$CODEX_AUTH_FILE")"
      cp -p "$SWITCH_TRANSACTION_DIR/live-auth.json" "$CODEX_AUTH_FILE" 2>/dev/null || true
      chmod 600 "$CODEX_AUTH_FILE" 2>/dev/null || true
    fi
    if [[ -n "${SWITCH_TRANSACTION_OUTGOING:-}" && -s "${SWITCH_TRANSACTION_DIR:-}/outgoing-auth.json" ]]; then
      cp -p "$SWITCH_TRANSACTION_DIR/outgoing-auth.json" "$(profile_auth_file "$SWITCH_TRANSACTION_OUTGOING")" 2>/dev/null || true
      chmod 600 "$(profile_auth_file "$SWITCH_TRANSACTION_OUTGOING")" 2>/dev/null || true
    fi
    if [[ -n "${SWITCH_TRANSACTION_OUTGOING:-}" ]]; then
      if [[ -s "${SWITCH_TRANSACTION_DIR:-}/outgoing-profile.env" ]]; then
        cp -p "$SWITCH_TRANSACTION_DIR/outgoing-profile.env" "$(profile_dir "$SWITCH_TRANSACTION_OUTGOING")/profile.env" 2>/dev/null || true
        chmod 600 "$(profile_dir "$SWITCH_TRANSACTION_OUTGOING")/profile.env" 2>/dev/null || true
      elif [[ "${SWITCH_TRANSACTION_OUTGOING_ENV_MISSING:-0}" == "1" ]]; then
        rm -f "$(profile_dir "$SWITCH_TRANSACTION_OUTGOING")/profile.env"
      fi
    fi
    if [[ -s "${SWITCH_TRANSACTION_DIR:-}/active-profile" ]]; then
      cp -p "$SWITCH_TRANSACTION_DIR/active-profile" "$ACTIVE_FILE" 2>/dev/null || true
      chmod 600 "$ACTIVE_FILE" 2>/dev/null || true
    elif [[ "${SWITCH_TRANSACTION_ACTIVE_FILE_MISSING:-0}" == "1" ]]; then
      rm -f "$ACTIVE_FILE"
    fi
    rm -rf "$SWITCH_TRANSACTION_DIR" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
  exit "$status"
}

cmd_switch() {
  local name="${1:-}"
  local no_open="${2:-}"
  validate_profile_name "$name"
  [[ "$no_open" == "" || "$no_open" == "--no-open" ]] || fail "unknown option: $no_open"

  with_lock
  validate_saved_profile_auth "$name"
  [[ -s "$CODEX_AUTH_FILE" ]] || fail "current Codex auth file is missing or empty; log in or use Re-authenticate first"
  local outgoing_profile
  outgoing_profile="$(resolve_live_profile 2>/dev/null || true)"
  [[ -n "$outgoing_profile" ]] || \
    fail "live auth does not uniquely match a saved profile; refusing to discard it"

  log "quitting $APP_NAME"
  quit_codex
  # Shutdown may rotate credentials. Snapshot only the final live auth so a
  # failed transaction never restores the pre-shutdown refresh token.
  outgoing_profile="$(resolve_live_profile 2>/dev/null || true)"
  [[ -n "$outgoing_profile" ]] || fail "live auth changed during shutdown; refusing to overwrite it"

  SWITCH_TRANSACTION_DIR="$SWITCHER_HOME/.transaction.$$"
  mkdir "$SWITCH_TRANSACTION_DIR"
  chmod 700 "$SWITCH_TRANSACTION_DIR" 2>/dev/null || true
  atomic_copy_file "$CODEX_AUTH_FILE" "$SWITCH_TRANSACTION_DIR/live-auth.json"
  atomic_copy_file "$(profile_auth_file "$outgoing_profile")" "$SWITCH_TRANSACTION_DIR/outgoing-auth.json"
  if [[ -f "$(profile_dir "$outgoing_profile")/profile.env" ]]; then
    atomic_copy_file "$(profile_dir "$outgoing_profile")/profile.env" "$SWITCH_TRANSACTION_DIR/outgoing-profile.env"
  else
    SWITCH_TRANSACTION_OUTGOING_ENV_MISSING=1
  fi
  if [[ -f "$ACTIVE_FILE" ]]; then
    atomic_copy_file "$ACTIVE_FILE" "$SWITCH_TRANSACTION_DIR/active-profile"
  else
    SWITCH_TRANSACTION_ACTIVE_FILE_MISSING=1
  fi
  SWITCH_TRANSACTION_OUTGOING="$outgoing_profile"
  SWITCH_TRANSACTION_ACTIVE=1
  trap 'switch_transaction_exit' EXIT

  log "saving the refreshed outgoing auth before switching to '$name'"
  save_auth_into_profile "$outgoing_profile"
  log "installing '$name' as the live Codex auth"
  atomic_copy_file "$(profile_auth_file "$name")" "$CODEX_AUTH_FILE"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"

  SWITCH_TRANSACTION_ACTIVE=0
  rm -rf "$SWITCH_TRANSACTION_DIR"
  trap - EXIT
  rmdir "$LOCK_DIR" 2>/dev/null || true

  if [[ "$no_open" != "--no-open" ]]; then
    log "opening $APP_NAME"
    open_codex
  fi
}

cmd_replace_auth() {
  local name="${1:-}"
  local codex_home="${2:-}"
  validate_profile_name "$name"
  [[ -n "$codex_home" ]] || fail "Codex home path is required"
  [[ -s "$codex_home/auth.json" ]] || fail "Codex home auth.json is missing or empty"
  with_lock
  local saved_auth="$(profile_auth_file "$name")"
  local recovery_dir="$(profile_dir "$name")/auth/recovery"
  local timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -s "$saved_auth" ]] || fail "profile '$name' has no saved auth.json"
  local expected_identity actual_identity
  expected_identity="$(profile_identity_key "$name" 2>/dev/null || true)"
  actual_identity="$(auth_identity_key "$codex_home/auth.json" 2>/dev/null || true)"
  [[ -n "$expected_identity" && -n "$actual_identity" && "$expected_identity" == "$actual_identity" ]] || \
    fail "the newly logged-in account does not match profile '$name'; refusing to replace its auth"
  mkdir -p "$recovery_dir"
  if [[ -s "$saved_auth" ]]; then
    atomic_copy_file "$saved_auth" "$recovery_dir/auth-before-reauth-$timestamp-$$.json"
  fi

  # The marker can lag a manual login or a VS Code refresh. Use live identity.
  if profile_auth_matches_file "$name" "$CODEX_AUTH_FILE"; then
    log "quitting $APP_NAME before replacing the active auth"
    quit_codex
    if [[ -s "$CODEX_AUTH_FILE" ]]; then
      atomic_copy_file "$CODEX_AUTH_FILE" "$recovery_dir/live-auth-before-reauth-$timestamp-$$.json"
    fi
    atomic_copy_file "$codex_home/auth.json" "$saved_auth"
    atomic_copy_file "$codex_home/auth.json" "$CODEX_AUTH_FILE"
    cmp -s "$codex_home/auth.json" "$saved_auth" && cmp -s "$codex_home/auth.json" "$CODEX_AUTH_FILE" || \
      fail "auth changed during replacement; fresh login is retained in $codex_home"
    update_auth_timestamp "$name"
    printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
    open_codex
  else
    atomic_copy_file "$codex_home/auth.json" "$saved_auth"
    update_auth_timestamp "$name"
  fi
  log "updated the auth token for '$name'"
}

cmd_list() {
  local plain="${1:-}"
  [[ "$plain" == "" || "$plain" == "--plain" ]] || fail "unknown option: $plain"
  ensure_store
  local active
  active="$(active_profile || true)"

  find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | while IFS= read -r dir; do
    local name
    name="$(basename "$dir")"
    if [[ "$plain" == "--plain" ]]; then
      printf '%s\n' "$name"
    elif [[ "$name" == "$active" ]]; then
      printf '* %s\n' "$name"
    else
      printf '  %s\n' "$name"
    fi
  done
}

cmd_active() {
  active_profile || true
}

cmd_record_active() {
  local name="${1:-}"
  validate_profile_name "$name"
  ensure_store
  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
}

cmd_active_state() {
  active_state_profile || true
}

cmd_rename() {
  local old_name="${1:-}"
  local new_name="${2:-}"
  validate_profile_name "$old_name"
  validate_profile_name "$new_name"
  with_lock

  local old_dir new_dir
  old_dir="$(profile_dir "$old_name")"
  new_dir="$(profile_dir "$new_name")"

  [[ -d "$old_dir" ]] || fail "profile '$old_name' does not exist"
  [[ ! -e "$new_dir" ]] || fail "profile '$new_name' already exists"

  mv "$old_dir" "$new_dir"
  {
    printf 'name=%s\n' "$new_name"
    if [[ -f "$new_dir/profile.env" ]]; then
      grep -v '^name=' "$new_dir/profile.env" || true
    fi
  } > "$new_dir/profile.env.tmp"
  mv "$new_dir/profile.env.tmp" "$new_dir/profile.env"

  local active
  active="$(active_profile || true)"
  if [[ "$active" == "$old_name" ]]; then
    printf '%s\n' "$new_name" > "$ACTIVE_FILE"
  fi

  local active_state
  active_state="$(active_state_profile || true)"
  if [[ "$active_state" == "$old_name" ]]; then
    printf '%s\n' "$new_name" > "$ACTIVE_STATE_FILE"
  fi

  log "renamed profile '$old_name' to '$new_name'"
}

cmd_import_auth() {
  local name="${1:-}"
  local auth_json="${2:-}"
  validate_profile_name "$name"
  [[ -n "$auth_json" ]] || fail "auth.json path is required"
  [[ -s "$auth_json" ]] || fail "auth.json file is missing or empty"
  with_lock

  local dir
  dir="$(profile_dir "$name")"
  [[ ! -e "$dir" ]] || fail "profile '$name' already exists"

  mkdir -p "$dir/auth" "$dir/app-support"
  atomic_copy_file "$auth_json" "$(profile_auth_file "$name")"
  write_identity_anchor_from_auth "$name" "$auth_json"

  {
    printf 'name=%s\n' "$name"
    printf 'captured_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'auth_file=%s\n' "$auth_json"
    printf 'app_support=%s\n' "$CODEX_APP_SUPPORT"
    printf 'imported_auth_only=true\n'
  } > "$dir/profile.env"

  log "imported auth.json as profile '$name'"
}

cmd_import_home() {
  local name="${1:-}"
  local codex_home="${2:-}"
  validate_profile_name "$name"
  [[ -n "$codex_home" ]] || fail "Codex home path is required"
  [[ -s "$codex_home/auth.json" ]] || fail "Codex home auth.json is missing or empty"
  with_lock

  local dir
  dir="$(profile_dir "$name")"
  [[ ! -e "$dir" ]] || fail "profile '$name' already exists"

  mkdir -p "$dir/auth" "$dir/app-support"
  atomic_copy_file "$codex_home/auth.json" "$(profile_auth_file "$name")"
  write_identity_anchor_from_auth "$name" "$codex_home/auth.json"

  {
    printf 'name=%s\n' "$name"
    printf 'captured_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'auth_file=%s\n' "$codex_home/auth.json"
    printf 'app_support=%s\n' "$CODEX_APP_SUPPORT"
    printf 'imported_from_codex_login=true\n'
  } > "$dir/profile.env"

  log "added Codex account as profile '$name'"
}

cmd_export_profile() {
  local name="${1:-}"
  local zip_path="${2:-}"
  validate_profile_name "$name"
  [[ -n "$zip_path" ]] || fail "zip path is required"
  ensure_store

  local dir
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || fail "profile '$name' does not exist"

  mkdir -p "$(dirname "$zip_path")"
  rm -f "$zip_path"
  archive_profile "$dir" "$zip_path"
  chmod 600 "$zip_path" 2>/dev/null || true
  log "exported profile '$name' to '$zip_path'"
}

cmd_delete() {
  local name="${1:-}"
  validate_profile_name "$name"
  with_lock

  local dir
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || fail "profile '$name' does not exist"

  local active
  active="$(active_profile || true)"
  local active_state
  active_state="$(active_state_profile || true)"
  if [[ "$active" == "$name" || "$active_state" == "$name" ]]; then
    fail "cannot delete the active profile or current machine state profile; change it first"
  fi

  rm -rf "$dir"
  log "deleted profile '$name'"
}

cmd_open_folder() {
  ensure_store
  open_path "$SWITCHER_HOME"
}

cmd_interactive() {
  local choice name new_name codex_home archive_path confirmation
  while true; do
    printf '\nCodex Account Manager\n'
    printf '  1) List profiles\n'
    printf '  2) Capture current account\n'
    printf '  3) Import account from Codex home\n'
    printf '  4) Make account active\n'
    printf '  5) Make desktop state active\n'
    printf '  6) Rename profile\n'
    printf '  7) Export profile backup\n'
    printf '  8) Delete profile\n'
    printf '  0) Quit\n'
    if ! IFS= read -r -p 'Choose an action: ' choice; then
      return 0
    fi

    case "$choice" in
      1) cmd_list ;;
      2)
        IFS= read -r -p 'New profile name: ' name || return 0
        cmd_capture "$name"
        ;;
      3)
        IFS= read -r -p 'Profile name: ' name || return 0
        IFS= read -r -p 'Codex home [~/.codex]: ' codex_home || return 0
        codex_home="${codex_home:-$HOME/.codex}"
        codex_home="${codex_home/#\~/$HOME}"
        cmd_import_home "$name" "$codex_home"
        ;;
      4)
        cmd_list
        IFS= read -r -p 'Profile to make active: ' name || return 0
        cmd_make_active "$name"
        ;;
      5)
        cmd_list
        IFS= read -r -p 'Profile whose desktop state to use: ' name || return 0
        cmd_make_state "$name"
        ;;
      6)
        cmd_list
        IFS= read -r -p 'Current profile name: ' name || return 0
        IFS= read -r -p 'New profile name: ' new_name || return 0
        cmd_rename "$name" "$new_name"
        ;;
      7)
        cmd_list
        IFS= read -r -p 'Profile to export: ' name || return 0
        IFS= read -r -p 'Backup zip path: ' archive_path || return 0
        cmd_export_profile "$name" "$archive_path"
        ;;
      8)
        cmd_list
        IFS= read -r -p 'Profile to delete: ' name || return 0
        IFS= read -r -p "Delete '$name'? Type yes to confirm: " confirmation || return 0
        if [[ "$confirmation" == yes ]]; then
          cmd_delete "$name"
        else
          log 'delete cancelled'
        fi
        ;;
      0|q|Q) return 0 ;;
      *) log 'choose one of the listed numbers' ;;
    esac
  done
}
