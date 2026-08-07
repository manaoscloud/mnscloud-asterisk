#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/rollback-asterisk.sh --ref <known-good-release-tag-or-commit>

Rolls Asterisk back to an explicit known-good ref, reapplies managed runtime
configuration, and validates the running service.
USAGE
}

REF=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf '[rollback-asterisk] ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REF" ]] || { printf '[rollback-asterisk] ERROR: --ref is required\n' >&2; usage >&2; exit 2; }
exec bash "${SCRIPT_DIR}/update-asterisk.sh" --ref "$REF"
