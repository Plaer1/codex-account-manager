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
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  case "$dst" in
    ""|"/"|"$HOME"|"$HOME/"|"$HOME/Library"|"$HOME/Library/Application Support"|"$config_home"|"$data_home")
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

auth_issued_at() {
  local token issued
  token="$(json_value "$1" tokens.access_token tokens.accessToken)"
  issued="$(jwt_claim "$token" iat)"
  if [[ "$issued" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$issued"
  else
    printf '0\n'
  fi
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

  local saved_auth recovery_dir live_issued saved_issued
  saved_auth="$(profile_auth_file "$name")"
  if cmp -s "$CODEX_AUTH_FILE" "$saved_auth"; then
    return 0
  fi
  recovery_dir="$(profile_dir "$name")/auth/recovery"
  mkdir -p "$recovery_dir"
  atomic_copy_file "$CODEX_AUTH_FILE" "$recovery_dir/live-before-save-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"
  live_issued="$(auth_issued_at "$CODEX_AUTH_FILE")"
  saved_issued="$(auth_issued_at "$saved_auth")"
  if [[ "$live_issued" -gt 0 && "$saved_issued" -gt "$live_issued" ]]; then
    log "kept newer saved credentials for '$name'; archived the older live credentials"
    return 0
  fi
  atomic_copy_file "$saved_auth" "$recovery_dir/saved-before-save-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"
  atomic_copy_file "$CODEX_AUTH_FILE" "$saved_auth"
  update_auth_timestamp "$name"
}
