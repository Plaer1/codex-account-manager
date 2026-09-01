#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/codex-account-transaction-test.XXXXXX)"
FAKE_BIN="$TEST_ROOT/bin"
trap 'case "$TEST_ROOT" in /tmp/codex-account-transaction-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

STORE_ROOT="$TEST_ROOT/store"
LIVE_ROOT="$TEST_ROOT/live"
mkdir -p "$STORE_ROOT/profiles/upduck1/auth" "$STORE_ROOT/profiles/upduck2/auth" "$LIVE_ROOT" "$FAKE_BIN"

make_token() {
  local subject="$1"
  local email="$2"
  local payload
  payload="$(printf '{"sub":"%s","email":"%s"}' "$subject" "$email" | base64 | tr -d '\n=' | tr '/+' '_-')"
  printf 'header.%s.signature\n' "$payload"
}

write_auth() {
  local path="$1"
  local subject="$2"
  local email="$3"
  local token
  token="$(make_token "$subject" "$email")"
  printf '{"auth_mode":"chatgpt","tokens":{"id_token":"%s","access_token":"%s","refresh_token":"refresh-%s"},"last_refresh":"2026-08-31T00:00:00Z"}\n' \
    "$token" "$token" "$subject" > "$path"
  chmod 600 "$path"
}

write_identity() {
  local path="$1"
  local subject="$2"
  local email="$3"
  printf '{"subjectID":"%s","email":"%s","accountID":"shared-team"}\n' "$subject" "$email" > "$path"
  chmod 600 "$path"
}

write_auth "$STORE_ROOT/profiles/upduck1/auth/auth.json" "subject-upduck1" "upduck1@example.com"
write_identity "$STORE_ROOT/profiles/upduck1/identity.json" "subject-upduck1" "upduck1@example.com"
write_auth "$STORE_ROOT/profiles/upduck2/auth/auth.json" "subject-upduck2" "upduck2@example.com"
write_identity "$STORE_ROOT/profiles/upduck2/identity.json" "subject-upduck2" "upduck2@example.com"
printf 'name=upduck1\n' > "$STORE_ROOT/profiles/upduck1/profile.env"
printf 'name=upduck2\n' > "$STORE_ROOT/profiles/upduck2/profile.env"
printf 'upduck1\n' > "$STORE_ROOT/active-profile"

write_auth "$LIVE_ROOT/auth.json" "subject-upduck1" "upduck1@example.com"
outgoing_before="$(shasum -a 256 "$LIVE_ROOT/auth.json" | awk '{print $1}')"

run_switch() {
  SWITCHER_HOME="$STORE_ROOT" \
  CODEX_AUTH_FILE="$LIVE_ROOT/auth.json" \
  CODEX_APP_SUPPORT="$TEST_ROOT/app-support" \
  CODEX_APP_NAME="Codex Transaction Test" \
  "$PROJECT_ROOT/codex-account-switcher.sh" switch "$1" --no-open
}

run_switch upduck2 >/dev/null
outgoing_after="$(shasum -a 256 "$STORE_ROOT/profiles/upduck1/auth/auth.json" | awk '{print $1}')"
[[ "$outgoing_before" == "$outgoing_after" ]] || {
  echo "FAIL: outgoing live auth was not persisted" >&2
  exit 1
}
cmp -s "$STORE_ROOT/profiles/upduck2/auth/auth.json" "$LIVE_ROOT/auth.json" || {
  echo "FAIL: target auth was not installed as the live auth" >&2
  exit 1
}
[[ "$(sed -n '1p' "$STORE_ROOT/active-profile")" == "upduck2" ]]

# A stale marker may follow the verified live identity, but it must never cause
# a different profile's auth to be overwritten.
printf 'upduck1\n' > "$STORE_ROOT/active-profile"
run_switch upduck1 >/dev/null
[[ "$(sed -n '1p' "$STORE_ROOT/active-profile")" == "upduck1" ]]

# A profile with an anchored identity cannot be activated if its saved auth is
# actually another user.
write_auth "$STORE_ROOT/profiles/upduck1/auth/auth.json" "subject-bryant" "bryant@example.com"
write_auth "$LIVE_ROOT/auth.json" "subject-upduck1" "upduck1@example.com"
printf 'upduck1\n' > "$STORE_ROOT/active-profile"
if run_switch upduck1 >/dev/null 2>&1; then
  echo "FAIL: identity-mismatched target was activated" >&2
  exit 1
fi
[[ "$(jq -r '.tokens.id_token' "$LIVE_ROOT/auth.json")" == "$(jq -r '.tokens.id_token' "$STORE_ROOT/profiles/upduck1/auth/auth.json")" ]] && {
  echo "FAIL: failed switch changed the live auth" >&2
  exit 1
}

# If Codex refuses to quit, no auth write is allowed to happen.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/pgrep"
chmod +x "$FAKE_BIN/sleep" "$FAKE_BIN/pgrep"
write_auth "$STORE_ROOT/profiles/upduck1/auth/auth.json" "subject-upduck1" "upduck1@example.com"
write_auth "$LIVE_ROOT/auth.json" "subject-upduck1" "upduck1@example.com"
printf 'upduck1\n' > "$STORE_ROOT/active-profile"
live_before="$(shasum -a 256 "$LIVE_ROOT/auth.json" | awk '{print $1}')"
outgoing_before="$(shasum -a 256 "$STORE_ROOT/profiles/upduck1/auth/auth.json" | awk '{print $1}')"
if PATH="$FAKE_BIN:$PATH" run_switch upduck2 >/dev/null 2>&1; then
  echo "FAIL: switch succeeded while Codex was still running" >&2
  exit 1
fi
live_after="$(shasum -a 256 "$LIVE_ROOT/auth.json" | awk '{print $1}')"
[[ "$live_before" == "$live_after" ]]
outgoing_after="$(shasum -a 256 "$STORE_ROOT/profiles/upduck1/auth/auth.json" | awk '{print $1}')"
[[ "$outgoing_before" == "$outgoing_after" ]]

# Re-auth can replace a mismatched saved profile only when the new login has
# the stored identity. It does not touch the live account for an inactive row.
write_auth "$TEST_ROOT/fresh-auth.json" "subject-upduck1" "upduck1@example.com"
mkdir -p "$TEST_ROOT/fresh-home"
cp -p "$TEST_ROOT/fresh-auth.json" "$TEST_ROOT/fresh-home/auth.json"
SWITCHER_HOME="$STORE_ROOT" \
CODEX_AUTH_FILE="$LIVE_ROOT/auth.json" \
CODEX_APP_SUPPORT="$TEST_ROOT/app-support" \
CODEX_APP_NAME="Codex Transaction Test" \
"$PROJECT_ROOT/codex-account-switcher.sh" replace-auth upduck1 "$TEST_ROOT/fresh-home" >/dev/null
cmp -s "$STORE_ROOT/profiles/upduck1/auth/auth.json" "$TEST_ROOT/fresh-home/auth.json"
[[ -s "$STORE_ROOT/profiles/upduck1/auth/recovery"/auth-before-reauth-*.json ]]

if SWITCHER_HOME="$STORE_ROOT" CODEX_AUTH_FILE="$LIVE_ROOT/auth.json" "$PROJECT_ROOT/codex-account-switcher.sh" restore-reference-auth upduck1 >/dev/null 2>&1; then
  echo "FAIL: removed restore-reference-auth command is still supported" >&2
  exit 1
fi

printf '%s\n' 'Switcher auth transaction tests passed'
