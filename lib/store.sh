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

require_python3() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate Codex account identity"
}
