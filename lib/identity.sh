#!/usr/bin/env bash

json_value() {
  local json_file="$1"
  shift
  require_python3
  python3 - "$json_file" "$@" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        data = json.load(stream)
except (OSError, ValueError):
    raise SystemExit(0)

for path in sys.argv[2:]:
    value = data
    for part in path.split("."):
        if not isinstance(value, dict):
            value = None
            break
        value = value.get(part)
    if value is not None and value != "":
        if isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":")))
        else:
            print(value)
        break
PY
}

normalize_identity_value() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]//g'
}

jwt_claim() {
  local jwt="$1"
  local claim="$2"
  [[ -n "$jwt" ]] || return 0
  require_python3
  printf '%s' "$jwt" | python3 -c '
import base64
import json
import sys

token = sys.stdin.read().strip()
try:
    encoded = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    key = sys.argv[1]
    value = claims.get(key, "") if isinstance(claims, dict) else ""
    if value is not None and not isinstance(value, (dict, list)):
        print(value)
except (IndexError, ValueError, TypeError, json.JSONDecodeError):
    pass
' "$claim"
}

auth_identity_key() {
  local auth_file="$1"
  [[ -s "$auth_file" ]] || return 1
  require_python3

  local id_token access_token subject email api_key
  id_token="$(json_value "$auth_file" tokens.id_token tokens.idToken)"
  access_token="$(json_value "$auth_file" tokens.access_token tokens.accessToken)"
  subject="$(jwt_claim "$id_token" sub)"
  [[ -n "$subject" ]] || subject="$(jwt_claim "$access_token" sub)"
  if [[ -n "$subject" ]]; then
    printf 'subject:%s\n' "$(normalize_identity_value "$subject")"
    return 0
  fi

  email="$(jwt_claim "$id_token" email)"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" email)"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" 'https://api.openai.com/profile/email')"
  if [[ -n "$email" ]]; then
    printf 'email:%s\n' "$(normalize_identity_value "$email")"
    return 0
  fi

  api_key="$(json_value "$auth_file" OPENAI_API_KEY)"
  if [[ -n "$api_key" ]]; then
    printf 'api:%s\n' "$(printf '%s' "$api_key" | hash_text)"
    return 0
  fi
  return 1
}

profile_identity_key() {
  local name="$1"
  local identity_file="$(profile_dir "$name")/identity.json"
  local subject email
  if [[ -s "$identity_file" ]]; then
    subject="$(json_value "$identity_file" subjectID)"
    subject="$(normalize_identity_value "$subject")"
    if [[ -n "$subject" && "$subject" != "-" ]]; then
      printf 'subject:%s\n' "$subject"
      return 0
    fi
    email="$(json_value "$identity_file" email)"
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
  require_python3

  local id_token access_token subject email account_id tmp
  id_token="$(json_value "$auth_file" tokens.id_token tokens.idToken)"
  access_token="$(json_value "$auth_file" tokens.access_token tokens.accessToken)"
  subject="$(jwt_claim "$id_token" sub)"
  [[ -n "$subject" ]] || subject="$(jwt_claim "$access_token" sub)"
  email="$(jwt_claim "$id_token" email)"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" email)"
  [[ -n "$email" ]] || email="$(jwt_claim "$access_token" 'https://api.openai.com/profile/email')"
  account_id="$(json_value "$auth_file" tokens.account_id tokens.accountId)"
  if [[ -z "$account_id" ]]; then
    account_id="$(jwt_claim "$access_token" chatgpt_account_id)"
  fi

  if [[ -z "$subject" && -z "$email" ]]; then
    # API-key profiles have no stable ChatGPT identity anchor. They are still
    # protected by comparing the hashed key through profile_identity_key.
    return 0
  fi

  tmp="${identity_file}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$identity_file")"
  python3 - "$tmp" "$subject" "$email" "$account_id" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"subjectID": sys.argv[2], "email": sys.argv[3], "accountID": sys.argv[4]}, stream)
    stream.write("\n")
PY
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
  local live_key recorded candidate count dir
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
