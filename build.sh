#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
  Darwin) exec "$ROOT_DIR/build-app.sh" "$@" ;;
  Linux) exec "$ROOT_DIR/build-linux.sh" "$@" ;;
  *) printf 'error: unsupported build platform: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
