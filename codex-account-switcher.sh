#!/usr/bin/env bash
set -euo pipefail

umask 077

APP_NAME="${CODEX_APP_NAME:-Codex}"
SWITCHER_HOME="${SWITCHER_HOME:-$HOME/Library/Application Support/CodexAccountSwitcher}"
PROFILES_DIR="$SWITCHER_HOME/profiles"
ACTIVE_FILE="$SWITCHER_HOME/active-profile"
ACTIVE_STATE_FILE="$SWITCHER_HOME/active-state-profile"
LOCK_DIR="$SWITCHER_HOME/.lock"

CODEX_AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
CODEX_APP_SUPPORT="${CODEX_APP_SUPPORT:-$HOME/Library/Application Support/Codex}"

usage() {
  cat <<'USAGE'
Codex Account Manager: Clanked Edition

Usage:
  codex-account-switcher.sh capture <profile>
  codex-account-switcher.sh import-home <profile> <codex-home>
  codex-account-switcher.sh replace-auth <profile> <codex-home>
  codex-account-switcher.sh switch <profile> [--no-open]
  codex-account-switcher.sh make-active <profile>
  codex-account-switcher.sh make-state <profile>
  codex-account-switcher.sh list [--plain]
  codex-account-switcher.sh active
  codex-account-switcher.sh active-state
  codex-account-switcher.sh rename <old-profile> <new-profile>
  codex-account-switcher.sh import-auth <profile> <auth-json>
  codex-account-switcher.sh export-profile <profile> <zip-path>
  codex-account-switcher.sh delete <profile>
  codex-account-switcher.sh open-folder

Environment overrides:
  SWITCHER_HOME       Profile storage directory
  CODEX_AUTH_FILE     Codex CLI auth file, default ~/.codex/auth.json
  CODEX_APP_SUPPORT   Codex Desktop state directory, default ~/Library/Application Support/Codex
  CODEX_APP_NAME      macOS app name, default Codex
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*" >&2
}

ensure_store() {
  mkdir -p "$PROFILES_DIR"
}

with_lock() {
  ensure_store
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another switch is already running"
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

validate_profile_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "profile name is required"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
    fail "profile name may only contain letters, numbers, dot, dash, and underscore"
}

profile_dir() {
  printf '%s/%s\n' "$PROFILES_DIR" "$1"
}

profile_auth_file() {
  printf '%s/auth/auth.json\n' "$(profile_dir "$1")"
}

profile_app_support_dir() {
  printf '%s/app-support/Codex\n' "$(profile_dir "$1")"
}

active_profile() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    sed -n '1p' "$ACTIVE_FILE"
  fi
}

active_state_profile() {
  if [[ -f "$ACTIVE_STATE_FILE" ]]; then
    sed -n '1p' "$ACTIVE_STATE_FILE"
  fi
}

atomic_copy_file() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] || fail "source file is missing: $src"
  mkdir -p "$(dirname "$dst")"
  local tmp="${dst}.tmp.$$.$RANDOM"
  cp -p "$src" "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst"
}

atomic_write_text() {
  local dst="$1"
  local tmp="${dst}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$dst")"
  cat > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || fail "jq is required to validate Codex account identity"
}

normalize_identity_value() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]//g'
}

jwt_claim() {
  local jwt="$1"
  local claim="$2"
  [[ -n "$jwt" ]] || return 0
  local payload encoded
  encoded="$(printf '%s' "$jwt" | awk -F. '{print $2}')"
  [[ -n "$encoded" ]] || return 0
  encoded="$(printf '%s' "$encoded" | tr '_-' '/+')"
  while (( ${#encoded} % 4 != 0 )); do
    encoded="${encoded}="
  done
  if ! payload="$(printf '%s' "$encoded" | base64 -D 2>/dev/null)"; then
    payload="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)"
  fi
  [[ -n "$payload" ]] || return 0
  printf '%s' "$payload" | jq -r "$claim // empty" 2>/dev/null || true
}

auth_identity_key() {
  local auth_file="$1"
  [[ -s "$auth_file" ]] || return 1
  require_jq

  local id_token access_token subject email api_key
  id_token="$(jq -r '.tokens.id_token // .tokens.idToken // empty' "$auth_file" 2>/dev/null || true)"
  access_token="$(jq -r '.tokens.access_token // .tokens.accessToken // empty' "$auth_file" 2>/dev/null || true)"
  subject="$(jwt_claim "$id_token" '.sub')"
  [[ -n "$subject" ]] || subject="$(jwt_claim "$access_token" '.sub')"
  if [[ -n "$subject" ]]; then
    printf 'subject:%s\n' "$(normalize_identity_value "$subject")"
    return 0
  fi

  email="$(jwt_claim "$id_token" '.email')"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" '.email')"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" '."https://api.openai.com/profile/email"')"
  if [[ -n "$email" ]]; then
    printf 'email:%s\n' "$(normalize_identity_value "$email")"
    return 0
  fi

  api_key="$(jq -r '.OPENAI_API_KEY // empty' "$auth_file" 2>/dev/null || true)"
  if [[ -n "$api_key" ]]; then
    printf 'api:%s\n' "$(printf '%s' "$api_key" | shasum -a 256 | awk '{print $1}')"
    return 0
  fi
  return 1
}

profile_identity_key() {
  local name="$1"
  local identity_file="$(profile_dir "$name")/identity.json"
  local subject email
  if [[ -s "$identity_file" ]]; then
    require_jq
    subject="$(jq -r '.subjectID // empty' "$identity_file" 2>/dev/null || true)"
    subject="$(normalize_identity_value "$subject")"
    if [[ -n "$subject" && "$subject" != "-" ]]; then
      printf 'subject:%s\n' "$subject"
      return 0
    fi
    email="$(jq -r '.email // empty' "$identity_file" 2>/dev/null || true)"
    email="$(normalize_identity_value "$email")"
    if [[ -n "$email" && "$email" != "-" ]]; then
      printf 'email:%s\n' "$email"
      return 0
    fi
  fi
  auth_identity_key "$(profile_auth_file "$name")"
}

profile_auth_matches_file() {
  local name="$1"
  local auth_file="$2"
  local expected actual
  expected="$(profile_identity_key "$name" 2>/dev/null || true)"
  actual="$(auth_identity_key "$auth_file" 2>/dev/null || true)"
  [[ -n "$expected" && -n "$actual" && "$expected" == "$actual" ]]
}

write_identity_anchor_from_auth() {
  local name="$1"
  local auth_file="$2"
  local identity_file="$(profile_dir "$name")/identity.json"
  [[ -s "$auth_file" ]] || fail "auth.json is missing or empty"
  require_jq

  local id_token access_token subject email account_id payload
  id_token="$(jq -r '.tokens.id_token // .tokens.idToken // empty' "$auth_file" 2>/dev/null || true)"
  access_token="$(jq -r '.tokens.access_token // .tokens.accessToken // empty' "$auth_file" 2>/dev/null || true)"
  subject="$(jwt_claim "$id_token" '.sub')"
  [[ -n "$subject" ]] || subject="$(jwt_claim "$access_token" '.sub')"
  email="$(jwt_claim "$id_token" '.email')"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" '.email')"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" '."https://api.openai.com/profile/email"')"
  account_id="$(jq -r '.tokens.account_id // .tokens.accountId // empty' "$auth_file" 2>/dev/null || true)"
  if [[ -z "$account_id" ]]; then
    account_id="$(jwt_claim "$access_token" '.chatgpt_account_id')"
  fi

  if [[ -z "$subject" && -z "$email" ]]; then
    # API-key profiles have no stable ChatGPT identity anchor. They are still
    # protected by comparing the hashed key through profile_identity_key.
    return 0
  fi

  local tmp="${identity_file}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$identity_file")"
  jq -n --arg subject "$subject" --arg email "$email" --arg account "$account_id" \
    '{subjectID:$subject,email:$email,accountID:$account}' > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$identity_file"
}

validate_saved_profile_auth() {
  local name="$1"
  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -s "$(profile_auth_file "$name")" ]] || fail "profile '$name' has no usable auth.json"
  profile_auth_matches_file "$name" "$(profile_auth_file "$name")" || \
    fail "profile '$name' is identity-mismatched; re-authenticate that profile before switching"
}

resolve_live_profile() {
  local live_key recorded candidate count
  live_key="$(auth_identity_key "$CODEX_AUTH_FILE" 2>/dev/null || true)"
  [[ -n "$live_key" ]] || return 1

  recorded="$(active_profile || true)"
  if [[ -n "$recorded" && -d "$(profile_dir "$recorded")" ]] && \
     profile_auth_matches_file "$recorded" "$CODEX_AUTH_FILE"; then
    printf '%s\n' "$recorded"
    return 0
  fi

  candidate=""
  count=0
  while IFS= read -r dir; do
    local name
    name="$(basename "$dir")"
    if profile_auth_matches_file "$name" "$CODEX_AUTH_FILE"; then
      candidate="$name"
      count=$((count + 1))
    fi
  done < <(find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
  [[ "$count" -eq 1 ]] || return 1
  printf '%s\n' "$candidate"
}

persist_live_auth() {
  local name
  name="$(resolve_live_profile 2>/dev/null || true)"
  [[ -n "$name" ]] || fail "live auth does not uniquely match a saved profile; refusing to overwrite any account"
  save_auth_into_profile "$name"
  printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
}

update_auth_timestamp() {
  local name="$1"
  local env_file="$(profile_dir "$name")/profile.env"
  local tmp="${env_file}.tmp.$$.$RANDOM"
  if [[ -f "$env_file" ]]; then
    grep -v '^auth_saved_at=' "$env_file" || true
  else
    printf 'name=%s\n' "$name"
  fi > "$tmp"
  printf 'auth_saved_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$env_file"
}

assert_safe_sync_target() {
  local dst="$1"
  case "$dst" in
    ""|"/"|"$HOME"|"$HOME/"|"$HOME/Library"|"$HOME/Library/Application Support")
      fail "refusing to sync into unsafe target: $dst"
      ;;
  esac
}

sync_dir_if_present() {
  local src="$1"
  local dst="$2"
  assert_safe_sync_target "$dst"

  if [[ -d "$src" && -d "$dst" ]]; then
    local src_real dst_real
    src_real="$(cd "$src" && pwd -P)"
    dst_real="$(cd "$dst" && pwd -P)"
    [[ "$src_real" != "$dst_real" ]] || fail "refusing to sync a directory onto itself: $src"
  fi

  mkdir -p "$(dirname "$dst")"
  if [[ ! -d "$src" ]]; then
    rm -rf "$dst"
    return 0
  fi

  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --checksum --delete \
      --exclude 'Cache/' \
      --exclude 'Code Cache/' \
      --exclude 'Crashpad/' \
      --exclude 'DawnGraphiteCache/' \
      --exclude 'DawnWebGPUCache/' \
      --exclude 'GPUCache/' \
      "$src"/ "$dst"/
  else
    local tmp="$dst.tmp.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    cp -pR "$src"/. "$tmp"/
    rm -rf "$dst"
    mv "$tmp" "$dst"
  fi
}

capture_into_profile() {
  local name="$1"
  validate_profile_name "$name"
  ensure_store

  local dir env_file env_tmp
  dir="$(profile_dir "$name")"
  env_file="$dir/profile.env"
  env_tmp="$dir/profile.env.tmp"
  mkdir -p "$dir/auth" "$dir/app-support"

  [[ -s "$CODEX_AUTH_FILE" ]] || fail "current Codex auth file is missing or empty"
  if [[ -s "$(profile_auth_file "$name")" ]]; then
    profile_auth_matches_file "$name" "$CODEX_AUTH_FILE" || \
      fail "live auth belongs to a different account; refusing to overwrite profile '$name'"
  else
    write_identity_anchor_from_auth "$name" "$CODEX_AUTH_FILE"
  fi
  atomic_copy_file "$CODEX_AUTH_FILE" "$(profile_auth_file "$name")"
  sync_dir_if_present "$CODEX_APP_SUPPORT" "$(profile_app_support_dir "$name")"

  {
    printf 'name=%s\n' "$name"
    printf 'captured_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'auth_file=%s\n' "$CODEX_AUTH_FILE"
    printf 'app_support=%s\n' "$CODEX_APP_SUPPORT"
    if [[ -f "$env_file" ]]; then
      grep -Ev '^(name|captured_at|auth_file|app_support|auth_saved_at|state_saved_at)=' "$env_file" || true
    fi
  } > "$env_tmp"
  mv "$env_tmp" "$env_file"
}

save_auth_into_profile() {
  local name="$1"
  validate_profile_name "$name"
  ensure_store

  [[ -d "$(profile_dir "$name")" ]] || fail "profile '$name' does not exist"
  [[ -s "$CODEX_AUTH_FILE" ]] || fail "current Codex auth file is missing or empty"
  validate_saved_profile_auth "$name"
  profile_auth_matches_file "$name" "$CODEX_AUTH_FILE" || \
    fail "live auth belongs to a different account; refusing to overwrite profile '$name'"

  atomic_copy_file "$CODEX_AUTH_FILE" "$(profile_auth_file "$name")"
  update_auth_timestamp "$name"
}

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
  /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
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
  /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
}

quit_codex() {
  /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  fail "$APP_NAME did not quit; no auth or machine-state files were changed"
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

  log "quitting $APP_NAME"
  quit_codex

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
    /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
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

  if [[ "$(active_profile || true)" == "$name" ]]; then
    log "quitting $APP_NAME before replacing the active auth"
    quit_codex
    if [[ -s "$CODEX_AUTH_FILE" ]]; then
      atomic_copy_file "$CODEX_AUTH_FILE" "$recovery_dir/live-auth-before-reauth-$timestamp-$$.json"
    fi
    atomic_copy_file "$codex_home/auth.json" "$saved_auth"
    atomic_copy_file "$codex_home/auth.json" "$CODEX_AUTH_FILE"
    update_auth_timestamp "$name"
    printf '%s\n' "$name" | atomic_write_text "$ACTIVE_FILE"
    /usr/bin/open -a "$APP_NAME" >/dev/null 2>&1 || log "warning: could not open $APP_NAME"
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
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$dir" "$zip_path"
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
  /usr/bin/open "$SWITCHER_HOME"
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    capture) cmd_capture "$@" ;;
    import-home) cmd_import_home "$@" ;;
    save-auth) cmd_save_auth "$@" ;;
    replace-auth) cmd_replace_auth "$@" ;;
    make-active|make-default) cmd_make_active "$@" ;;
    make-state) cmd_make_state "$@" ;;
    switch) cmd_switch "$@" ;;
    list) cmd_list "$@" ;;
    active) cmd_active ;;
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
