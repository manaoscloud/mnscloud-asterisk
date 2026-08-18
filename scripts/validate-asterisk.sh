#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASTERISK_BIN="${ASTERISK_BIN:-asterisk}"
AST_PJSIP_CONFIG="${AST_PJSIP_CONFIG:-/etc/asterisk/pjsip.conf}"
AST_EXTENSIONS_CONFIG="${AST_EXTENSIONS_CONFIG:-/etc/asterisk/extensions.conf}"
AST_DB_CONFIG_FILE="${AST_DB_CONFIG_FILE:-/etc/mnscloud/pabx/db.conf}"

fail() {
  printf '[validate-asterisk] ERROR: %s\n' "$*" >&2
  exit 1
}

wait_for() {
  local description="$1"
  local attempts="${2:-12}"
  local delay="${3:-2}"
  shift 3
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  fail "$description"
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "required runtime state is missing or empty: ${path}"
}

printf '[validate-asterisk] checking shell scripts\n'
for script in \
  "${SCRIPT_DIR}"/*.sh \
  "${SCRIPT_DIR}"/lib/*.sh; do
  bash -n "$script"
done

[[ "${EUID}" -eq 0 ]] || fail 'run this validation as root.'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required.'
command -v "$ASTERISK_BIN" >/dev/null 2>&1 || fail "${ASTERISK_BIN} is required."

require_file '/etc/mnscloud/pabx/api.base'
require_file '/etc/mnscloud/pabx/node.uuid'
require_file '/etc/mnscloud/pabx/api.token'
require_file "$AST_DB_CONFIG_FILE"
require_file "$AST_PJSIP_CONFIG"
require_file "$AST_EXTENSIONS_CONFIG"

grep -Eq '^[[:space:]]*endpoint_identifier_order[[:space:]]*=' "$AST_PJSIP_CONFIG" ||
  fail "PJSIP endpoint identifier order is missing: ${AST_PJSIP_CONFIG}"
grep -Eq '^[[:space:]]*switch[[:space:]]*=>[[:space:]]*Realtime' "$AST_EXTENSIONS_CONFIG" ||
  fail "Realtime dialplan switch is missing: ${AST_EXTENSIONS_CONFIG}"

wait_for 'asterisk.service is not active.' 15 2 systemctl is-active --quiet asterisk
wait_for 'Asterisk CLI cannot query core version.' 15 2 "$ASTERISK_BIN" -rx 'core show version'
wait_for 'res_pjsip.so is not loaded.' 15 2 bash -c "\"$ASTERISK_BIN\" -rx 'module show like res_pjsip.so' | grep -q 'res_pjsip.so'"
wait_for 'res_config_odbc.so is not loaded.' 15 2 bash -c "\"$ASTERISK_BIN\" -rx 'module show like res_config_odbc.so' | grep -q 'res_config_odbc.so'"

printf '[validate-asterisk] Asterisk runtime validation OK\n'
