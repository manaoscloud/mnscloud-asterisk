#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[install-asterisk]"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/install-base.sh" "$@"
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/env.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/.env"

NODE_UUID_FILE="/etc/mnscloud/pabx/node.uuid"
API_TOKEN_FILE="/etc/mnscloud/pabx/api.token"
API_BASE_FILE="/etc/mnscloud/pabx/api.base"
AST_DB_CONFIG_FILE="/etc/mnscloud/pabx/db.conf"
DEFAULT_API_BASE="https://api.publichost.cloud"
NODE_UUID=""
API_BASE=""
API_TOKEN=""
AST_DB_HOST="${AST_DB_HOST:-}"
AST_DB_PORT="${AST_DB_PORT:-3306}"
AST_DB_NAME="${AST_DB_NAME:-}"
AST_DB_USER="${AST_DB_USER:-}"
AST_DB_PASS="${AST_DB_PASS:-}"
AST_CONTROL_PORT="5038"
AST_CONTROL_ALLOWED_IPS=""
AST_CONTROL_SECRET_FILE="/etc/mnscloud/pabx/asterisk-ami.secret"
AST_CONTROL_SECRET=""
API_VALIDATED_PUBLIC_IP=""
AST_LOCAL_IP="${AST_LOCAL_IP:-${ASTERISK_LOCAL_IP:-}}"
AST_PUBLIC_IP="${AST_PUBLIC_IP:-${ASTERISK_PUBLIC_IP:-}}"
AST_AUTO_DISCOVER_PUBLIC_IP="${AST_AUTO_DISCOVER_PUBLIC_IP:-${ASTERISK_AUTO_DISCOVER_PUBLIC_IP:-1}}"
ASTERISK_VERSION="${ASTERISK_VERSION:-22-current}"
ASTERISK_SOURCE_URL="${ASTERISK_SOURCE_URL:-https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz}"
ASTERISK_SRC_DIR="${ASTERISK_SRC_DIR:-/usr/src/mnscloud-asterisk}"
ASTERISK_G72X_SOURCE_URL="${ASTERISK_G72X_SOURCE_URL:-https://github.com/arkadijs/asterisk-g72x.git}"
ASTERISK_G72X_SOURCE_REF="${ASTERISK_G72X_SOURCE_REF:-55a7b8246c8ad3f32e50a033529e5a52c11a5592}"
ASTERISK_G72X_BUNDLED_SOURCE_DIR="${ASTERISK_G72X_BUNDLED_SOURCE_DIR:-${PROJECT_ROOT}/codecs/asterisk-g72x}"
ASTERISK_G72X_BUILD_DIR="${ASTERISK_G72X_BUILD_DIR:-/usr/src/mnscloud-asterisk-g72x}"
ASTERISK_EXTERNAL_INCLUDE_DIR="${ASTERISK_EXTERNAL_INCLUDE_DIR:-/usr/src/mnscloud-asterisk-include}"

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-base)
        API_BASE="${2:-}"
        shift 2
        ;;
      --node-uuid)
        NODE_UUID="${2:-}"
        shift 2
        ;;
      --runtime-token | --install-token)
        API_TOKEN="${2:-}"
        shift 2
        ;;
      --db-host)
        AST_DB_HOST="${2:-}"
        shift 2
        ;;
      --db-port)
        AST_DB_PORT="${2:-}"
        shift 2
        ;;
      --db-name)
        AST_DB_NAME="${2:-}"
        shift 2
        ;;
      --db-user)
        AST_DB_USER="${2:-}"
        shift 2
        ;;
      --db-pass)
        AST_DB_PASS="${2:-}"
        shift 2
        ;;
      --dry-run)
        shift
        ;;
      *)
        err "Unknown argument: $1"
        exit 2
        ;;
    esac
  done
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    info "Loading variables from ${ENV_FILE}"
    info "Asterisk DB credentials are not loaded from .env; use ${AST_DB_CONFIG_FILE}."
  fi
}

normalize_url() {
  local value="$1"
  value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s#/*$##')"
  printf "%s" "$value"
}

sql_literal_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

url_encode() {
  local value="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg v "$value" '$v|@uri'
    return 0
  fi
  printf "%s" "$value"
}

validate_api_base() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(:[0-9]+)?(/[^[:space:]]*)?$ ]]
}

prompt_api_base() {
  local value=""
  if [[ -t 0 ]]; then
    read -r -p "Enter the MNSCloud API base URL [${DEFAULT_API_BASE}]: " value
  fi
  value="${value:-${DEFAULT_API_BASE}}"
  normalize_url "$value"
}

ensure_api_base_file() {
  local dir value
  dir="$(dirname "${API_BASE_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"

  if [[ -n "${API_BASE}" ]]; then
    API_BASE="$(normalize_url "${API_BASE}")"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved to ${API_BASE_FILE}: ${API_BASE}"
  elif [[ -f "${API_BASE_FILE}" ]]; then
    value="$(tr -d '[:space:]' < "${API_BASE_FILE}")"
    API_BASE="$(normalize_url "$value")"
    ok "API base carregada de ${API_BASE_FILE}: ${API_BASE}"
  else
    API_BASE="$(prompt_api_base)"
    validate_api_base "${API_BASE}" || { err "URL base da API invalida: ${API_BASE}"; return 1; }
    write_file "${API_BASE_FILE}" "${API_BASE}"
    ok "API base saved to ${API_BASE_FILE}: ${API_BASE}"
  fi

  validate_api_base "${API_BASE}" || { err "URL base da API invalida em ${API_BASE_FILE}: ${API_BASE}"; return 1; }
  run "chown root:root '${API_BASE_FILE}'"
  run "chmod 0640 '${API_BASE_FILE}'"
}

detect_asterisk_os() {
  [[ -r /etc/os-release ]] || { err "Could not read /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12|debian:13) echo "debian"; return 0 ;;
  esac
  err "Unsupported operating system for Asterisk. Supported in this version: Debian 12/13."
  exit 2
}

generate_uuid() {
  [[ -r /proc/sys/kernel/random/uuid ]] && tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid && return 0
  command -v uuidgen >/dev/null 2>&1 && uuidgen | tr '[:upper:]' '[:lower:]'
}

generate_secret_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
    return 0
  fi
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

ensure_control_secret() {
  local dir
  dir="$(dirname "${AST_CONTROL_SECRET_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -f "${AST_CONTROL_SECRET_FILE}" ]]; then
    AST_CONTROL_SECRET="$(tr -d '[:space:]' < "${AST_CONTROL_SECRET_FILE}")"
  else
    AST_CONTROL_SECRET="$(generate_secret_32)"
    write_file "${AST_CONTROL_SECRET_FILE}" "${AST_CONTROL_SECRET}"
  fi
  if getent group asterisk >/dev/null 2>&1; then
    run "chown root:asterisk '${AST_CONTROL_SECRET_FILE}'"
  else
    run "chown root:root '${AST_CONTROL_SECRET_FILE}'"
  fi
  run "chmod 0640 '${AST_CONTROL_SECRET_FILE}'"
}

quote_config_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

load_asterisk_db_config() {
  [[ -f "${AST_DB_CONFIG_FILE}" ]] || return 1
  # shellcheck disable=SC1090
  source "${AST_DB_CONFIG_FILE}"
  AST_DB_HOST="${AST_DB_HOST:-}"
  AST_DB_PORT="${AST_DB_PORT:-3306}"
  AST_DB_NAME="${AST_DB_NAME:-}"
  AST_DB_USER="${AST_DB_USER:-}"
  AST_DB_PASS="${AST_DB_PASS:-}"
  [[ -n "${AST_DB_HOST}" && -n "${AST_DB_PORT}" && -n "${AST_DB_NAME}" && -n "${AST_DB_USER}" && -n "${AST_DB_PASS}" ]]
}

prompt_asterisk_db_config() {
  if $DRY_RUN; then
    AST_DB_HOST="${AST_DB_HOST:-db.example.local}"
    AST_DB_PORT="${AST_DB_PORT:-3306}"
    AST_DB_NAME="${AST_DB_NAME:-clouddb}"
    AST_DB_USER="${AST_DB_USER:-asterisk_rt}"
    AST_DB_PASS="${AST_DB_PASS:-dry-run-password}"
    log DRY "prompt Asterisk MariaDB credentials"
    return 0
  fi

  [[ -r /dev/tty && -w /dev/tty ]] || {
    err "Interactive terminal is unavailable and ${AST_DB_CONFIG_FILE} does not contain valid credentials."
    return 1
  }

  local value
  while true; do
    read -r -p "Enter the Asterisk MariaDB host: " AST_DB_HOST </dev/tty
    read -r -p "Enter the Asterisk MariaDB port [3306]: " value </dev/tty
    AST_DB_PORT="${value:-3306}"
    read -r -p "Enter the Asterisk MariaDB database name: " AST_DB_NAME </dev/tty
    read -r -p "Enter the Asterisk MariaDB user: " AST_DB_USER </dev/tty
    read -r -p "Enter the Asterisk MariaDB password: " AST_DB_PASS </dev/tty

    if [[ -n "${AST_DB_HOST}" && "${AST_DB_PORT}" =~ ^[0-9]+$ && -n "${AST_DB_NAME}" && -n "${AST_DB_USER}" && -n "${AST_DB_PASS}" ]]; then
      return 0
    fi
    warn "Incomplete database data or invalid port. Enter the values again."
  done
}

write_asterisk_db_config() {
  local dir
  dir="$(dirname "${AST_DB_CONFIG_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  write_file "${AST_DB_CONFIG_FILE}" "AST_DB_HOST=$(quote_config_value "${AST_DB_HOST}")
AST_DB_PORT=$(quote_config_value "${AST_DB_PORT}")
AST_DB_NAME=$(quote_config_value "${AST_DB_NAME}")
AST_DB_USER=$(quote_config_value "${AST_DB_USER}")
AST_DB_PASS=$(quote_config_value "${AST_DB_PASS}")"
  if getent group asterisk >/dev/null 2>&1; then
    run "chown root:asterisk '${AST_DB_CONFIG_FILE}'"
  else
    run "chown root:root '${AST_DB_CONFIG_FILE}'"
  fi
  run "chmod 0640 '${AST_DB_CONFIG_FILE}'"
}

mysql_client_bin() {
  if command -v mariadb >/dev/null 2>&1; then
    echo "mariadb"
    return 0
  fi
  if command -v mysql >/dev/null 2>&1; then
    echo "mysql"
    return 0
  fi
  return 1
}

validate_mariadb_connection() {
  local client output rc
  if $DRY_RUN; then
    log DRY "validate MariaDB connection ${AST_DB_USER}@${AST_DB_HOST}:${AST_DB_PORT}/${AST_DB_NAME}"
    return 0
  fi
  client="$(mysql_client_bin)" || {
    err "MariaDB/MySQL client not found for connection validation."
    return 1
  }
  info "Validating Asterisk MariaDB connection at ${AST_DB_HOST}:${AST_DB_PORT}/${AST_DB_NAME}..."
  set +e
  output="$(MYSQL_PWD="${AST_DB_PASS}" "${client}" \
    --connect-timeout=8 \
    -h "${AST_DB_HOST}" \
    -P "${AST_DB_PORT}" \
    -u "${AST_DB_USER}" \
    "${AST_DB_NAME}" \
    -N -B -e "SELECT 1;" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 || "${output}" != "1" ]]; then
    err "Failed to validate Asterisk MariaDB connection: ${output}"
    return 1
  fi
  ok "Asterisk MariaDB connection validated."
}

ensure_asterisk_db_config() {
  local answer loaded=false
  if load_asterisk_db_config; then
    loaded=true
  fi

  while true; do
    if [[ "${loaded}" == "true" ]]; then
      ok "Asterisk DB credentials loaded from ${AST_DB_CONFIG_FILE}: ${AST_DB_USER}@${AST_DB_HOST}:${AST_DB_PORT}/${AST_DB_NAME}"
      if [[ -r /dev/tty && -w /dev/tty ]]; then
        read -r -p "Use these Asterisk DB credentials? [Y/n]: " answer </dev/tty
        if [[ "${answer,,}" =~ ^n ]]; then
          prompt_asterisk_db_config
          write_asterisk_db_config
        fi
      fi
    else
      prompt_asterisk_db_config
      write_asterisk_db_config
    fi

    if validate_mariadb_connection; then
      return 0
    fi

    [[ -r /dev/tty && -w /dev/tty ]] || return 1
    warn "Mandatory MariaDB validation failed. Enter the credentials again."
    loaded=false
  done
}

ensure_api_token_file() {
  local dir
  dir="$(dirname "${API_TOKEN_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -n "${API_TOKEN}" ]]; then
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "PABX API token saved to ${API_TOKEN_FILE}"
  elif [[ -f "${API_TOKEN_FILE}" ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "${API_TOKEN_FILE}")"
    ok "PABX API token loaded from ${API_TOKEN_FILE}"
  else
    API_TOKEN="$(generate_secret_32)"
    write_file "${API_TOKEN_FILE}" "${API_TOKEN}"
    ok "PABX API token created at ${API_TOKEN_FILE}"
  fi
  if getent group asterisk >/dev/null 2>&1; then
    run "chown root:asterisk '${API_TOKEN_FILE}'"
  else
    run "chown root:root '${API_TOKEN_FILE}'"
  fi
  run "chmod 0640 '${API_TOKEN_FILE}'"
}

ensure_node_uuid_file() {
  local dir compact
  dir="$(dirname "${NODE_UUID_FILE}")"
  [[ -d "$dir" ]] || run "mkdir -p '${dir}'"
  if [[ -n "${NODE_UUID}" ]]; then
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID saved to ${NODE_UUID_FILE}: ${NODE_UUID}"
  elif [[ -f "${NODE_UUID_FILE}" ]]; then
    NODE_UUID="$(tr -d '[:space:]' < "${NODE_UUID_FILE}")"
    ok "Node UUID loaded from ${NODE_UUID_FILE}: ${NODE_UUID}"
  else
    NODE_UUID="$(generate_uuid)"
    write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
    ok "Node UUID created at ${NODE_UUID_FILE}: ${NODE_UUID}"
  fi
  compact="${NODE_UUID//-/}"
  [[ "${compact}" =~ ^[0-9A-Fa-f]{32}$ ]] || { err "Node UUID invalido em ${NODE_UUID_FILE}: ${NODE_UUID}"; return 1; }
  compact="$(echo "${compact}" | tr '[:upper:]' '[:lower:]')"
  NODE_UUID="${compact:0:8}-${compact:8:4}-${compact:12:4}-${compact:16:4}-${compact:20:12}"
  write_file "${NODE_UUID_FILE}" "${NODE_UUID}"
  if getent group asterisk >/dev/null 2>&1; then
    run "chown root:asterisk '${NODE_UUID_FILE}'"
  else
    run "chown root:root '${NODE_UUID_FILE}'"
  fi
  run "chmod 0640 '${NODE_UUID_FILE}'"
}

install_packages_debian() {
  run "apt-get update -y"
  run "apt-get install -y --no-install-recommends build-essential git curl wget ca-certificates gnupg pkg-config autoconf automake libtool bison flex make patch libedit-dev libjansson-dev libxml2-dev libsqlite3-dev uuid-dev libssl-dev libcurl4-openssl-dev libnewt-dev libncurses5-dev libncurses-dev unixodbc unixodbc-dev odbc-mariadb default-mysql-client libbcg729-0 libbcg729-dev sngrep tcpdump ngrep dnsutils iputils-ping traceroute mtr-tiny netcat-openbsd jq"
  if apt-cache show asterisk-codec-bcg729 >/dev/null 2>&1; then
    if ! run "apt-get install -y --no-install-recommends asterisk-codec-bcg729"; then
      warn "Optional package asterisk-codec-bcg729 could not be installed. The installer will try to build codec_g729.so via asterisk-g72x + libbcg729."
    fi
  else
    warn "Package asterisk-codec-bcg729 was not found in the configured repositories. The installer will try to build codec_g729.so via asterisk-g72x + libbcg729."
  fi
}

enable_menuselect_module() {
  local module="$1" rc
  if $DRY_RUN; then
    log DRY "cd '${ASTERISK_SRC_DIR}' && menuselect/menuselect --enable '${module}' menuselect.makeopts"
    return 0
  fi
  info "ENABLE: Asterisk module ${module}"
  set +e
  (cd "${ASTERISK_SRC_DIR}" && menuselect/menuselect --enable "${module}" menuselect.makeopts) 2>&1 | tee -a "${LOG_FILE}"
  rc="${PIPESTATUS[0]}"
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    warn "Asterisk module was not enabled by menuselect: ${module}. It may not exist in this version or may depend on a missing library."
  fi
}

enable_asterisk_modules() {
  local module
  local modules=(
    res_odbc
    res_config_odbc
    res_sorcery_realtime
    res_realtime
    pbx_realtime
    cdr_adaptive_odbc
    cel_odbc
    app_dial
    app_stack
    format_g729
    format_h264
    func_odbc
    func_realtime
    res_pjsip
    res_pjsip_endpoint_identifier_ip
    res_pjsip_outbound_registration
    res_pjsip_registrar
    res_pjsip_authenticator_digest
  )
  for module in "${modules[@]}"; do
    enable_menuselect_module "${module}"
  done
}

install_asterisk_from_source() {
  if command -v asterisk >/dev/null 2>&1 && [[ "${ASTERISK_FORCE_BUILD:-false}" != "true" ]]; then
    ok "Asterisk is already installed: $(asterisk -V 2>/dev/null || true)"
    return 0
  fi
  run "rm -rf '${ASTERISK_SRC_DIR}'"
  run "mkdir -p '${ASTERISK_SRC_DIR}'"
  run "curl -fsSL '${ASTERISK_SOURCE_URL}' -o '${ASTERISK_SRC_DIR}/asterisk.tar.gz'"
  run "tar -xzf '${ASTERISK_SRC_DIR}/asterisk.tar.gz' -C '${ASTERISK_SRC_DIR}' --strip-components=1"
  run "cd '${ASTERISK_SRC_DIR}' && ./configure --with-jansson-bundled --with-pjproject-bundled"
  run "cd '${ASTERISK_SRC_DIR}' && make menuselect.makeopts"
  enable_asterisk_modules
  run "cd '${ASTERISK_SRC_DIR}' && make -j\$(nproc)"
  run "cd '${ASTERISK_SRC_DIR}' && make install"
  run "cd '${ASTERISK_SRC_DIR}' && make install-headers || true"
  run "cd '${ASTERISK_SRC_DIR}' && make config"
  run "ldconfig"
}

ensure_asterisk_source_tree() {
  if [[ -f "${ASTERISK_SRC_DIR}/include/asterisk/asterisk.h" || -f "${ASTERISK_SRC_DIR}/include/asterisk.h" ]]; then
    return 0
  fi
  info "Asterisk source not found in ${ASTERISK_SRC_DIR}; downloading to build external modules."
  run "rm -rf '${ASTERISK_SRC_DIR}'"
  run "mkdir -p '${ASTERISK_SRC_DIR}'"
  run "curl -fsSL '${ASTERISK_SOURCE_URL}' -o '${ASTERISK_SRC_DIR}/asterisk.tar.gz'"
  run "tar -xzf '${ASTERISK_SRC_DIR}/asterisk.tar.gz' -C '${ASTERISK_SRC_DIR}' --strip-components=1"
  run "cd '${ASTERISK_SRC_DIR}' && ./configure --with-jansson-bundled --with-pjproject-bundled"
}

prepare_asterisk_external_includes() {
  if [[ -f "${ASTERISK_EXTERNAL_INCLUDE_DIR}/asterisk/asterisk.h" ]]; then
    printf '%s\n' "${ASTERISK_EXTERNAL_INCLUDE_DIR}"
    return 0
  fi
  ensure_asterisk_source_tree || return 1
  run "rm -rf '${ASTERISK_EXTERNAL_INCLUDE_DIR}'"
  run "mkdir -p '${ASTERISK_EXTERNAL_INCLUDE_DIR}/asterisk'"
  if [[ -d "${ASTERISK_SRC_DIR}/include/asterisk" ]]; then
    run "cp -a '${ASTERISK_SRC_DIR}/include/asterisk/.' '${ASTERISK_EXTERNAL_INCLUDE_DIR}/asterisk/'"
  fi
  if compgen -G "${ASTERISK_SRC_DIR}/include/*.h" >/dev/null; then
    run "cp -a '${ASTERISK_SRC_DIR}'/include/*.h '${ASTERISK_EXTERNAL_INCLUDE_DIR}/asterisk/'"
  fi
  if [[ -f "${ASTERISK_EXTERNAL_INCLUDE_DIR}/asterisk/asterisk.h" ]]; then
    printf '%s\n' "${ASTERISK_EXTERNAL_INCLUDE_DIR}"
    return 0
  fi
  return 1
}

asterisk_include_dir() {
  local dir
  for dir in "${ASTERISK_EXTERNAL_INCLUDE_DIR}" /usr/include "${ASTERISK_SRC_DIR}/include"; do
    if [[ -f "${dir}/asterisk/asterisk.h" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

asterisk_module_dir() {
  local dir="/usr/lib/asterisk/modules"
  if [[ -d "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  printf '%s\n' "$dir"
}

asterisk_module_exists() {
  local module="$1"
  [[ -f "$(asterisk_module_dir)/${module}.so" ]]
}

build_asterisk_g729_codec() {
  if asterisk_module_exists "codec_g729"; then
    ok "codec_g729.so ja existe no Asterisk."
    return 0
  fi

  local include_dir module_dir codec_so
  if ! include_dir="$(asterisk_include_dir)"; then
    prepare_asterisk_external_includes || true
    if ! include_dir="$(asterisk_include_dir)"; then
      warn "Asterisk headers not found; skipping codec_g729.so build."
      return 1
    fi
  fi
  if [[ ! -f /usr/include/bcg729/encoder.h || ! -f /usr/include/bcg729/decoder.h ]]; then
    warn "bcg729 headers not found in /usr/include/bcg729; skipping codec_g729.so build."
    return 1
  fi

  module_dir="$(asterisk_module_dir)"
  run "rm -rf '${ASTERISK_G72X_BUILD_DIR}'"
  if [[ -f "${ASTERISK_G72X_BUNDLED_SOURCE_DIR}/codec_g72x.c" ]]; then
    info "Compilando codec_g729.so a partir do fonte local ${ASTERISK_G72X_BUNDLED_SOURCE_DIR}..."
    run "cp -a '${ASTERISK_G72X_BUNDLED_SOURCE_DIR}' '${ASTERISK_G72X_BUILD_DIR}'"
  else
    info "Local asterisk-g72x source not found; downloading ${ASTERISK_G72X_SOURCE_URL} (${ASTERISK_G72X_SOURCE_REF})..."
    run "git clone --depth 1 '${ASTERISK_G72X_SOURCE_URL}' '${ASTERISK_G72X_BUILD_DIR}'"
    run "cd '${ASTERISK_G72X_BUILD_DIR}' && git fetch --depth 1 origin '${ASTERISK_G72X_SOURCE_REF}' && git checkout '${ASTERISK_G72X_SOURCE_REF}'"
  fi
  run "cd '${ASTERISK_G72X_BUILD_DIR}' && bash ./autogen.sh"
  run "cd '${ASTERISK_G72X_BUILD_DIR}' && ./configure --prefix=/usr --libdir=/usr/lib --with-bcg729 --with-asterisk-includes='${include_dir}'"
  run "cd '${ASTERISK_G72X_BUILD_DIR}' && make -j\$(nproc)"
  codec_so="$(find "${ASTERISK_G72X_BUILD_DIR}" -path "*/codec_g729.so" -print -quit 2>/dev/null || true)"
  if [[ -z "$codec_so" ]]; then
    warn "Build asterisk-g72x terminou sem gerar codec_g729.so."
    return 1
  fi
  run "install -m 0755 '${codec_so}' '${module_dir}/codec_g729.so'"
  ok "codec_g729.so installed at ${module_dir}/codec_g729.so"
}

ensure_asterisk_user() {
  if ! getent group asterisk >/dev/null 2>&1; then run "groupadd --system asterisk"; fi
  if ! id asterisk >/dev/null 2>&1; then run "useradd --system --gid asterisk --home-dir /var/lib/asterisk --shell /usr/sbin/nologin asterisk"; fi
  run "mkdir -p /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/spool/asterisk/monitor/mnscloud /run/asterisk /etc/asterisk"
  run "chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /run/asterisk"
}

backup_once() { local file="$1"; [[ -f "$file" && ! -f "${file}.bkp" ]] && run "cp -a '${file}' '${file}.bkp'" || true; }

odbc_driver_name() {
  if odbcinst -q -d 2>/dev/null | grep -qi 'MariaDB Unicode'; then echo "MariaDB Unicode"; return 0; fi
  if odbcinst -q -d 2>/dev/null | grep -qi 'MariaDB'; then echo "MariaDB"; return 0; fi
  echo "MariaDB Unicode"
}

write_odbc_config() {
  local driver
  driver="$(odbc_driver_name)"
  backup_once "/etc/odbc.ini"
  write_file "/etc/odbc.ini" "[mnscloud_asterisk]
Driver=${driver}
Server=${AST_DB_HOST}
Port=${AST_DB_PORT}
Database=${AST_DB_NAME}
User=${AST_DB_USER}
Password=${AST_DB_PASS}
Option=3"
  if getent group asterisk >/dev/null 2>&1; then
    run "chown root:asterisk /etc/odbc.ini"
    run "chmod 0640 /etc/odbc.ini"
  else
    run "chmod 0644 /etc/odbc.ini"
  fi
}

validate_odbc_config() {
  local output rc
  if $DRY_RUN; then
    log DRY "validate ODBC DSN mnscloud_asterisk"
    return 0
  fi
  command -v isql >/dev/null 2>&1 || {
    err "isql not found for ODBC validation."
    return 1
  }
  info "Validating ODBC DSN mnscloud_asterisk..."
  set +e
  output="$(printf "SELECT 1;\n" | isql -b -v mnscloud_asterisk "${AST_DB_USER}" "${AST_DB_PASS}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    err "Failed to validate ODBC DSN mnscloud_asterisk: ${output}"
    return 1
  fi
  ok "DSN ODBC mnscloud_asterisk validado."
}

write_asterisk_configs() {
  local cfg media_api_base_sql media_node_uuid_sql media_token_sql
  media_api_base_sql="$(sql_literal_escape "${API_BASE}")"
  media_node_uuid_sql="$(sql_literal_escape "${NODE_UUID}")"
  media_token_sql="$(sql_literal_escape "$(url_encode "${API_TOKEN}")")"

  for cfg in asterisk.conf modules.conf pjsip.conf extconfig.conf sorcery.conf res_odbc.conf func_odbc.conf extensions.conf queues.conf logger.conf cdr_adaptive_odbc.conf cel_odbc.conf; do
    backup_once "/etc/asterisk/${cfg}"
  done

  write_file "/etc/asterisk/asterisk.conf" "[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /run/asterisk
astlogdir => /var/log/asterisk

[options]
runuser = asterisk
rungroup = asterisk
defaultlanguage = en"

  write_file "/etc/asterisk/modules.conf" "[modules]
autoload=yes
preload => res_odbc.so
preload => res_config_odbc.so
load => pbx_realtime.so
load => res_musiconhold.so
load => app_queue.so
load => res_pjsip_pubsub.so
load => res_pjsip_exten_state.so
load => res_pjsip_outbound_registration.so
load => res_pjsip_pidf_body_generator.so
load => res_pjsip_xpidf_body_generator.so
load => res_pjsip_dialog_info_body_generator.so
load => res_curl.so
load => res_http_media_cache.so
load => res_security_log.so
noload => codec_g729a.so
noload => codec_g729b.so
noload => chan_sip.so"

  write_file "/etc/asterisk/res_odbc.conf" "[mnscloud]
enabled => yes
dsn => mnscloud_asterisk
username => ${AST_DB_USER}
password => ${AST_DB_PASS}
pre-connect => yes
sanitysql => select 1"

  write_file "/etc/asterisk/func_odbc.conf" "[AST_RESOLVE_INTERNAL]
dsn=mnscloud
readsql=SELECT target.id FROM AsteriskEndpoint caller JOIN VoipPabxExtension caller_ext ON caller_ext.VpeUUID = caller.VoipPabxExtensionVpeUUID JOIN VoipPabxExtension target_ext ON target_ext.VoipPabxAccountVpaUUID = caller_ext.VoipPabxAccountVpaUUID AND target_ext.UserUsrUUID <=> caller_ext.UserUsrUUID AND target_ext.VpeUsername = '\${SQL_ESC(\${ARG2})}' AND target_ext.VpeEnabled = 1 AND target_ext.VpeDateDeleted IS NULL JOIN AsteriskEndpoint target ON target.VoipPabxExtensionVpeUUID = target_ext.VpeUUID WHERE '\${SQL_ESC(\${ARG1})}' LIKE CONCAT('PJSIP/', caller.id, '-%') AND caller_ext.VpeEnabled = 1 AND caller_ext.VpeDateDeleted IS NULL LIMIT 1

[AST_RESOLVE_INBOUND]
dsn=mnscloud
readsql=SELECT CASE WHEN r.VriRouteType = 'extension' AND target.id IS NOT NULL THEN CONCAT('PJSIP/', target.id) WHEN r.VriRouteType = 'external' AND NULLIF(TRIM(r.VriRouteTargetValue), '') IS NOT NULL THEN CASE WHEN TRIM(r.VriRouteTargetValue) REGEXP '^[A-Za-z]+/' THEN TRIM(r.VriRouteTargetValue) ELSE CONCAT('PJSIP/', TRIM(r.VriRouteTargetValue), '@', trunk_endpoint.id) END WHEN r.VriRouteType = 'external' AND x.VpxUUID IS NOT NULL THEN CONCAT('PJSIP/', COALESCE(NULLIF(TRIM(x.VpxDialPrefix), ''), ''), x.VpxNumber, '@', trunk_endpoint.id) WHEN r.VriRouteType = 'group' AND grp.VpgUUID IS NOT NULL THEN CONCAT('Local/', r.VriRouteTargetUUID, '@mnscloud-group') WHEN r.VriRouteType = 'queue' AND q.VpqUUID IS NOT NULL THEN CONCAT('Local/', r.VriRouteTargetUUID, '@mnscloud-queue') WHEN r.VriRouteType = 'ivr' AND ivr.VpiUUID IS NOT NULL THEN CONCAT('Local/', r.VriRouteTargetUUID, '@mnscloud-ivr') ELSE NULL END FROM AsteriskEndpoint trunk_endpoint JOIN VoipPabxTrunk trunk ON trunk.VptUUID = trunk_endpoint.VoipPabxTrunkVptUUID JOIN VoipPabxInboundRoute r ON r.VoipPabxAccountVpaUUID = trunk.VoipPabxAccountVpaUUID AND (r.VoipPabxTrunkVptUUID IS NULL OR r.VoipPabxTrunkVptUUID = trunk.VptUUID) LEFT JOIN VoipPabxExtension target_ext ON r.VriRouteType = 'extension' AND target_ext.VpeUUID = FuncUUIDToBin(r.VriRouteTargetUUID) AND target_ext.UserUsrUUID <=> r.UserUsrUUID AND target_ext.VpeDateDeleted IS NULL AND target_ext.VpeEnabled = 1 LEFT JOIN AsteriskEndpoint target ON target.VoipPabxExtensionVpeUUID = target_ext.VpeUUID LEFT JOIN VoipPabxExternal x ON r.VriRouteType = 'external' AND x.VpxUUID = FuncUUIDToBin(r.VriRouteTargetUUID) AND x.UserUsrUUID <=> r.UserUsrUUID AND x.VpxDateDeleted IS NULL AND x.VpxEnabled = 1 LEFT JOIN VoipPabxGroup grp ON r.VriRouteType = 'group' AND grp.VpgUUID = FuncUUIDToBin(r.VriRouteTargetUUID) AND grp.UserUsrUUID <=> r.UserUsrUUID AND grp.VpgDateDeleted IS NULL AND grp.VpgEnabled = 1 LEFT JOIN VoipPabxQueue q ON r.VriRouteType = 'queue' AND q.VpqUUID = FuncUUIDToBin(r.VriRouteTargetUUID) AND q.UserUsrUUID <=> r.UserUsrUUID AND q.VpqDateDeleted IS NULL AND q.VpqEnabled = 1 LEFT JOIN VoipPabxIvr ivr ON r.VriRouteType = 'ivr' AND ivr.VpiUUID = FuncUUIDToBin(r.VriRouteTargetUUID) AND ivr.UserUsrUUID <=> r.UserUsrUUID AND ivr.VpiDateDeleted IS NULL AND ivr.VpiEnabled = 1 WHERE '\${SQL_ESC(\${ARG1})}' LIKE CONCAT('PJSIP/', trunk_endpoint.id, '-%') AND '\${SQL_ESC(\${ARG2})}' REGEXP r.VriPattern AND r.VriEnabled = 1 AND r.VriDateDeleted IS NULL AND trunk.VptEnabled = 1 AND trunk.VptDateDeleted IS NULL ORDER BY r.VriPriority ASC, r.VriDateCreated ASC LIMIT 1

[AST_CHECK_INBOUND_BLACKLIST]
dsn=mnscloud
readsql=SELECT CASE n.VbnAction WHEN 'busy' THEN '17' ELSE '21' END FROM AsteriskEndpoint trunk_endpoint JOIN VoipPabxTrunk trunk ON trunk.VptUUID = trunk_endpoint.VoipPabxTrunkVptUUID JOIN VoipPabxAccount account ON account.VpaUUID = trunk.VoipPabxAccountVpaUUID JOIN VoipBlacklist b ON b.VbkUUID = account.VoipBlacklistVbkUUID AND b.UserUsrUUID <=> account.UserUsrUUID AND b.VbkEnabled = 1 AND b.VbkDateDeleted IS NULL JOIN VoipBlacklistNumber n ON n.VoipBlacklistVbkUUID = b.VbkUUID AND n.UserUsrUUID <=> account.UserUsrUUID AND n.VbnEnabled = 1 AND n.VbnDateDeleted IS NULL AND (n.VbnStartsAt IS NULL OR n.VbnStartsAt <= NOW(6)) AND (n.VbnExpiresAt IS NULL OR n.VbnExpiresAt >= NOW(6)) AND ((n.VbnMatchType = 'exact' AND n.VbnNormalizedNumber = FuncOnlyNumber('\${SQL_ESC(\${ARG2})}')) OR (n.VbnMatchType = 'prefix' AND FuncOnlyNumber('\${SQL_ESC(\${ARG2})}') LIKE CONCAT(n.VbnNormalizedNumber, '%')) OR (n.VbnMatchType = 'regex' AND FuncOnlyNumber('\${SQL_ESC(\${ARG2})}') REGEXP n.VbnNormalizedNumber)) WHERE '\${SQL_ESC(\${ARG1})}' LIKE CONCAT('PJSIP/', trunk_endpoint.id, '-%') AND account.VpaIsActive = 1 AND account.VpaDateDeleted IS NULL AND trunk.VptEnabled = 1 AND trunk.VptDateDeleted IS NULL ORDER BY n.VbnPriority ASC, n.VbnDateCreated ASC LIMIT 1

[AST_RESOLVE_OUTBOUND]
dsn=mnscloud
readsql=SELECT CONCAT('PJSIP/', dp.NormalizedNumber, '@', trunk_endpoint.id) FROM (SELECT caller_ext.VoipPabxAccountVpaUUID AS PabxUUID, caller_ext.UserUsrUUID AS UserUUID, rule.VoipPabxTrunkVptUUID AS TrunkUUID, IF(rule.VdrResultType = 'blocked', NULL, IF(rule.VdrReplacement IS NOT NULL AND TRIM(rule.VdrReplacement) <> '', IF(rule.VdrOperator = 'regex', REGEXP_REPLACE('\${SQL_ESC(\${ARG2})}', rule.VdrPattern, rule.VdrReplacement), rule.VdrReplacement), CONCAT(COALESCE(rule.VdrPrepend, ''), SUBSTRING('\${SQL_ESC(\${ARG2})}', IFNULL(rule.VdrStripDigits, 0) + 1)))) AS NormalizedNumber FROM AsteriskEndpoint caller JOIN VoipPabxExtension caller_ext ON caller_ext.VpeUUID = caller.VoipPabxExtensionVpeUUID JOIN VoipPabxAccount account ON account.VpaUUID = caller_ext.VoipPabxAccountVpaUUID JOIN VoipPabxDialPlan plan ON plan.VdpUUID = COALESCE(caller_ext.VoipPabxDialPlanVdpUUID, account.VoipPabxDialPlanVdpUUID) JOIN VoipPabxDialPlanRule rule ON rule.VoipPabxDialPlanVdpUUID = plan.VdpUUID AND rule.UserUsrUUID <=> caller_ext.UserUsrUUID WHERE '\${SQL_ESC(\${ARG1})}' LIKE CONCAT('PJSIP/', caller.id, '-%') AND caller_ext.VpeEnabled = 1 AND caller_ext.VpeDateDeleted IS NULL AND account.VpaIsActive = 1 AND account.VpaDateDeleted IS NULL AND plan.VdpEnabled = 1 AND plan.VdpDateDeleted IS NULL AND rule.VdrEnabled = 1 AND rule.VdrDateDeleted IS NULL AND rule.VdrDirection = 'outbound' AND rule.VdrResultType IN ('outbound', 'blocked') AND ((rule.VdrOperator = 'regex' AND '\${SQL_ESC(\${ARG2})}' REGEXP rule.VdrPattern) OR (rule.VdrOperator = 'exact' AND IF(rule.VdrCaseSensitive <> 0, '\${SQL_ESC(\${ARG2})}' = rule.VdrPattern, LOWER('\${SQL_ESC(\${ARG2})}') = LOWER(rule.VdrPattern))) OR (rule.VdrOperator = 'prefix' AND IF(rule.VdrCaseSensitive <> 0, '\${SQL_ESC(\${ARG2})}' LIKE CONCAT(rule.VdrPattern, '%'), LOWER('\${SQL_ESC(\${ARG2})}') LIKE CONCAT(LOWER(rule.VdrPattern), '%')))) ORDER BY rule.VdrPriority ASC, rule.VdrDateCreated ASC LIMIT 1) dp JOIN VoipPabxTrunk trunk ON trunk.VptUUID = dp.TrunkUUID AND trunk.UserUsrUUID <=> dp.UserUUID AND trunk.VoipPabxAccountVpaUUID = dp.PabxUUID JOIN AsteriskEndpoint trunk_endpoint ON trunk_endpoint.VoipPabxTrunkVptUUID = trunk.VptUUID WHERE dp.NormalizedNumber IS NOT NULL AND trunk.VptEnabled = 1 AND trunk.VptDateDeleted IS NULL AND trunk.VptDirection IN ('outbound', 'both') LIMIT 1

[AST_GROUP_DIAL]
dsn=mnscloud
readsql=SELECT GROUP_CONCAT(CONCAT('PJSIP/', endpoint.id) ORDER BY member.VgmPriority ASC, member.VgmDateCreated ASC SEPARATOR '&') FROM VoipPabxGroup grp JOIN VoipPabxGroupMember member ON member.VoipPabxGroupVpgUUID = grp.VpgUUID AND member.VgmDateDeleted IS NULL AND member.VgmEnabled = 1 JOIN VoipPabxExtension ext ON ext.VpeUUID = member.VoipPabxExtensionVpeUUID AND ext.VpeDateDeleted IS NULL AND ext.VpeEnabled = 1 JOIN AsteriskEndpoint endpoint ON endpoint.VoipPabxExtensionVpeUUID = ext.VpeUUID WHERE grp.VpgUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND grp.VpgDateDeleted IS NULL AND grp.VpgEnabled = 1

[AST_GROUP_TIMEOUT]
dsn=mnscloud
readsql=SELECT IFNULL(VpgRingTimeoutSeconds, 30) FROM VoipPabxGroup WHERE VpgUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND VpgDateDeleted IS NULL AND VpgEnabled = 1

[AST_QUEUE_DIAL]
dsn=mnscloud
readsql=SELECT GROUP_CONCAT(CONCAT('PJSIP/', endpoint.id) ORDER BY member.VqmPriority ASC, member.VqmDateCreated ASC SEPARATOR '&') FROM VoipPabxQueue qtarget JOIN VoipPabxQueueMember member ON member.VoipPabxQueueVpqUUID = qtarget.VpqUUID AND member.VqmDateDeleted IS NULL AND member.VqmEnabled = 1 JOIN VoipPabxExtension ext ON ext.VpeUUID = member.VoipPabxExtensionVpeUUID AND ext.VpeDateDeleted IS NULL AND ext.VpeEnabled = 1 JOIN AsteriskEndpoint endpoint ON endpoint.VoipPabxExtensionVpeUUID = ext.VpeUUID WHERE qtarget.VpqUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND qtarget.VpqDateDeleted IS NULL AND qtarget.VpqEnabled = 1

[AST_QUEUE_TIMEOUT]
dsn=mnscloud
readsql=SELECT IFNULL(VpqTimeoutSeconds, 30) FROM VoipPabxQueue WHERE VpqUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND VpqDateDeleted IS NULL AND VpqEnabled = 1

[AST_IVR_AUDIO]
dsn=mnscloud
readsql=SELECT CASE WHEN (CASE WHEN media.VmfDeliveryMode IN ('online','offline') THEN media.VmfDeliveryMode WHEN account.VpaMediaDeliveryMode IN ('online','offline') THEN account.VpaMediaDeliveryMode WHEN tenant_param.SprVoipPabxMediaDeliveryModeIsActive = 1 AND NULLIF(TRIM(tenant_param.SprVoipPabxMediaDeliveryMode), '') IS NOT NULL THEN tenant_param.SprVoipPabxMediaDeliveryMode WHEN master_param.SprVoipPabxMediaDeliveryModeIsActive = 1 AND NULLIF(TRIM(master_param.SprVoipPabxMediaDeliveryMode), '') IS NOT NULL THEN master_param.SprVoipPabxMediaDeliveryMode ELSE 'offline' END) = 'online' AND NULLIF(TRIM(media.VmfStorageObjectKey), '') IS NOT NULL AND COALESCE(media.VmfStorageStatus, 'empty') NOT IN ('empty','failed') THEN CONCAT('${media_api_base_sql}/api/v1/pabx/media/${media_node_uuid_sql}/', FuncUUIDFromBin(media.VmfUUID), '/content/', COALESCE(NULLIF(TRIM(media.VmfStoredFilename), ''), CONCAT(FuncUUIDFromBin(media.VmfUUID), '.wav')), '?token=${media_token_sql}') ELSE sync.VmsDialPath END FROM VoipPabxIvr ivr JOIN VoipPabxMediaFile media ON media.VmfUUID = ivr.VoipPabxMediaFileVmfUUID AND media.VmfDateDeleted IS NULL AND media.VmfEnabled = 1 JOIN VoipPabxAccount account ON account.VpaUUID = ivr.VoipPabxAccountVpaUUID LEFT JOIN SystemParameter tenant_param ON tenant_param.UserUsrUUID <=> media.UserUsrUUID AND tenant_param.SprDateDeleted IS NULL LEFT JOIN SystemParameter master_param ON master_param.UserUsrUUID IS NULL AND master_param.SprDateDeleted IS NULL LEFT JOIN VoipPabxMediaFileSync sync ON sync.VoipPabxMediaFileVmfUUID = media.VmfUUID AND sync.VoipPabxServerVpsUUID = account.VoipPabxServerVpsUUID AND sync.VmsDateDeleted IS NULL AND sync.VmsStatus = 'synced' WHERE ivr.VpiUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND ivr.VpiDateDeleted IS NULL AND ivr.VpiEnabled = 1 LIMIT 1

[AST_IVR_TIMEOUT]
dsn=mnscloud
readsql=SELECT IFNULL(VpiTimeoutSeconds, 10) FROM VoipPabxIvr WHERE VpiUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND VpiDateDeleted IS NULL AND VpiEnabled = 1

[AST_IVR_OPTION_TARGET]
dsn=mnscloud
readsql=SELECT CASE WHEN opt.VioRouteType = 'extension' AND target.id IS NOT NULL THEN CONCAT('PJSIP/', target.id) WHEN opt.VioRouteType = 'external' AND NULLIF(TRIM(opt.VioRouteTargetValue), '') IS NOT NULL AND trunk_endpoint.id IS NOT NULL THEN CASE WHEN TRIM(opt.VioRouteTargetValue) REGEXP '^[A-Za-z]+/' THEN TRIM(opt.VioRouteTargetValue) ELSE CONCAT('PJSIP/', TRIM(opt.VioRouteTargetValue), '@', trunk_endpoint.id) END WHEN opt.VioRouteType = 'external' AND x.VpxUUID IS NOT NULL AND trunk_endpoint.id IS NOT NULL THEN CONCAT('PJSIP/', COALESCE(NULLIF(TRIM(x.VpxDialPrefix), ''), ''), x.VpxNumber, '@', trunk_endpoint.id) WHEN opt.VioRouteType = 'group' AND grp.VpgUUID IS NOT NULL THEN CONCAT('Local/', opt.VioRouteTargetUUID, '@mnscloud-group') WHEN opt.VioRouteType = 'queue' AND q.VpqUUID IS NOT NULL THEN CONCAT('Local/', opt.VioRouteTargetUUID, '@mnscloud-queue') WHEN opt.VioRouteType = 'ivr' AND next_ivr.VpiUUID IS NOT NULL THEN CONCAT('Local/', opt.VioRouteTargetUUID, '@mnscloud-ivr') ELSE NULL END FROM VoipPabxIvrOption opt LEFT JOIN AsteriskEndpoint trunk_endpoint ON '\${SQL_ESC(\${ARG3})}' LIKE CONCAT('PJSIP/', trunk_endpoint.id, '-%') LEFT JOIN VoipPabxExtension target_ext ON opt.VioRouteType = 'extension' AND target_ext.VpeUUID = FuncUUIDToBin(opt.VioRouteTargetUUID) AND target_ext.UserUsrUUID <=> opt.UserUsrUUID AND target_ext.VpeDateDeleted IS NULL AND target_ext.VpeEnabled = 1 LEFT JOIN AsteriskEndpoint target ON target.VoipPabxExtensionVpeUUID = target_ext.VpeUUID LEFT JOIN VoipPabxExternal x ON opt.VioRouteType = 'external' AND x.VpxUUID = FuncUUIDToBin(opt.VioRouteTargetUUID) AND x.UserUsrUUID <=> opt.UserUsrUUID AND x.VpxDateDeleted IS NULL AND x.VpxEnabled = 1 LEFT JOIN VoipPabxGroup grp ON opt.VioRouteType = 'group' AND grp.VpgUUID = FuncUUIDToBin(opt.VioRouteTargetUUID) AND grp.UserUsrUUID <=> opt.UserUsrUUID AND grp.VpgDateDeleted IS NULL AND grp.VpgEnabled = 1 LEFT JOIN VoipPabxQueue q ON opt.VioRouteType = 'queue' AND q.VpqUUID = FuncUUIDToBin(opt.VioRouteTargetUUID) AND q.UserUsrUUID <=> opt.UserUsrUUID AND q.VpqDateDeleted IS NULL AND q.VpqEnabled = 1 LEFT JOIN VoipPabxIvr next_ivr ON opt.VioRouteType = 'ivr' AND next_ivr.VpiUUID = FuncUUIDToBin(opt.VioRouteTargetUUID) AND next_ivr.UserUsrUUID <=> opt.UserUsrUUID AND next_ivr.VpiDateDeleted IS NULL AND next_ivr.VpiEnabled = 1 WHERE opt.VoipPabxIvrVpiUUID = FuncUUIDToBin('\${SQL_ESC(\${ARG1})}') AND opt.VioDigit = '\${SQL_ESC(\${ARG2})}' AND opt.VioDateDeleted IS NULL AND opt.VioEnabled = 1 LIMIT 1"

  write_file "/etc/asterisk/extconfig.conf" "[settings]
ps_globals => odbc,mnscloud,AsteriskRealtimeGlobal
ps_transports => odbc,mnscloud,AsteriskRealtimeTransport
ps_endpoints => odbc,mnscloud,AsteriskRealtimeEndpoint
ps_auths => odbc,mnscloud,AsteriskRealtimeAuth
ps_aors => odbc,mnscloud,AsteriskRealtimeAor
ps_contacts => odbc,mnscloud,AsteriskRealtimeContact
ps_domain_aliases => odbc,mnscloud,AsteriskRealtimeDomainAlias
ps_endpoint_id_ips => odbc,mnscloud,AsteriskRealtimeEndpointIdentify
ps_registrations => odbc,mnscloud,AsteriskRealtimeRegistration
extensions => odbc,mnscloud,AsteriskExtension
queues => odbc,mnscloud,AsteriskQueue
queue_members => odbc,mnscloud,AsteriskQueueMember"

  write_file "/etc/asterisk/sorcery.conf" "[res_pjsip]
global=realtime,ps_globals
transport=realtime,ps_transports
endpoint=realtime,ps_endpoints
auth=realtime,ps_auths
aor=realtime,ps_aors
contact=realtime,ps_contacts
domain_alias=realtime,ps_domain_aliases

[res_pjsip_endpoint_identifier_ip]
identify=realtime,ps_endpoint_id_ips

[res_pjsip_outbound_registration]
registration=realtime,ps_registrations"

  write_file "/etc/asterisk/pjsip.conf" "[global]
type=global
endpoint_identifier_order=ip,username,anonymous
user_agent=MNSCloud Asterisk"

  write_file "/etc/asterisk/extensions.conf" "[general]
static=yes
writeprotect=yes
autofallthrough=yes

[globals]

[default]
exten => _X.,1,NoOp(MNSCloud Asterisk default context)
 same => n,Hangup(404)

[authenticated]
switch => Realtime/authenticated@extensions
exten => _X.,1,NoOp(mnscloud authenticated call from \${CHANNEL(name)} to \${EXTEN})
 same => n,Set(CALLER_CHANNEL=\${CHANNEL(name)})
 same => n,Set(TARGET_ENDPOINT=\${ODBC_AST_RESOLVE_INTERNAL(\${CALLER_CHANNEL},\${EXTEN})})
 same => n,ExecIf(\$[\"\${TARGET_ENDPOINT}\" != \"\"]?Set(TARGET_DIAL=PJSIP/\${TARGET_ENDPOINT}))
 same => n,GotoIf(\$[\"\${TARGET_DIAL}\" != \"\"]?record)
 same => n,Set(TARGET_DIAL=\${ODBC_AST_RESOLVE_OUTBOUND(\${CALLER_CHANNEL},\${EXTEN})})
 same => n,GotoIf(\$[\"\${TARGET_DIAL}\" = \"\"]?notfound)
 same => n(record),Set(MNSCLOUD_RECORDING_PATH=/var/spool/asterisk/monitor/mnscloud/\${STRFTIME(\${EPOCH},,%Y%m%d)}-\${UNIQUEID}.wav)
 same => n,Set(CDR(userfield)=\${MNSCLOUD_RECORDING_PATH})
 same => n,MixMonitor(\${MNSCLOUD_RECORDING_PATH},b)
 same => n(dial),Dial(\${TARGET_DIAL},30)
 same => n,Gosub(mnscloud-dial-result,s,1(\${DIALSTATUS}))
 same => n,Hangup()
 same => n(notfound),Hangup(404)

[trunk-inbound]
exten => _X.,1,NoOp(mnscloud inbound trunk call from \${CHANNEL(name)} to \${EXTEN})
 same => n,Set(__MNSCLOUD_INBOUND_CHANNEL=\${CHANNEL(name)})
 same => n,Set(BLACKLIST_CAUSE=\${ODBC_AST_CHECK_INBOUND_BLACKLIST(\${CHANNEL(name)},\${CALLERID(num)})})
 same => n,GotoIf(\$[\"\${BLACKLIST_CAUSE}\" != \"\"]?blacklisted)
 same => n,Set(TARGET_DIAL=\${ODBC_AST_RESOLVE_INBOUND(\${CHANNEL(name)},\${EXTEN})})
 same => n,GotoIf(\$[\"\${TARGET_DIAL}\" = \"\"]?notfound)
 same => n,Set(MNSCLOUD_RECORDING_PATH=/var/spool/asterisk/monitor/mnscloud/\${STRFTIME(\${EPOCH},,%Y%m%d)}-\${UNIQUEID}.wav)
 same => n,Set(CDR(userfield)=\${MNSCLOUD_RECORDING_PATH})
 same => n,MixMonitor(\${MNSCLOUD_RECORDING_PATH},b)
 same => n,Dial(\${TARGET_DIAL},30)
 same => n,Gosub(mnscloud-dial-result,s,1(\${DIALSTATUS}))
 same => n,Hangup()
 same => n(blacklisted),Hangup(\${BLACKLIST_CAUSE})
 same => n(notfound),Hangup(404)

[mnscloud-group]
exten => _.,1,NoOp(mnscloud group \${EXTEN})
 same => n,Set(GROUP_DIAL=\${ODBC_AST_GROUP_DIAL(\${EXTEN})})
 same => n,Set(GROUP_TIMEOUT=\${ODBC_AST_GROUP_TIMEOUT(\${EXTEN})})
 same => n,GotoIf(\$[\"\${GROUP_DIAL}\" = \"\"]?notfound)
 same => n,Dial(\${GROUP_DIAL},\${IF(\$[\"\${GROUP_TIMEOUT}\" = \"\"]?30:\${GROUP_TIMEOUT})})
 same => n,Gosub(mnscloud-dial-result,s,1(\${DIALSTATUS}))
 same => n,Hangup()
 same => n(notfound),Hangup(404)

[mnscloud-queue]
exten => _.,1,NoOp(mnscloud queue \${EXTEN})
 same => n,Set(QUEUE_TIMEOUT=\${ODBC_AST_QUEUE_TIMEOUT(\${EXTEN})})
 same => n,ExecIf(\$[\"\${QUEUE_TIMEOUT}\" = \"\"]?Set(QUEUE_TIMEOUT=30))
 same => n,Queue(mnscloud-\${TOLOWER(\${EXTEN})},tT,,,\${QUEUE_TIMEOUT})
 same => n,GotoIf(\$[\"\${QUEUESTATUS}\" = \"TIMEOUT\"]?timeout)
 same => n,GotoIf(\$[\"\${QUEUESTATUS}\" = \"JOINEMPTY\"]?unavailable)
 same => n,GotoIf(\$[\"\${QUEUESTATUS}\" = \"LEAVEEMPTY\"]?unavailable)
 same => n,Hangup()
 same => n(timeout),Hangup(19)
 same => n(unavailable),Hangup(20)
 same => n(notfound),Hangup(404)

[mnscloud-ivr]
exten => _.,1,NoOp(mnscloud ivr \${EXTEN})
 same => n,Answer()
 same => n,Set(IVR_AUDIO=\${ODBC_AST_IVR_AUDIO(\${EXTEN})})
 same => n,Set(IVR_TIMEOUT=\${ODBC_AST_IVR_TIMEOUT(\${EXTEN})})
 same => n,ExecIf(\$[\"\${IVR_TIMEOUT}\" = \"\"]?Set(IVR_TIMEOUT=10))
 same => n,GotoIf(\$[\"\${IVR_AUDIO}\" = \"\"]?read_no_prompt)
 same => n,Read(IVR_DIGIT,\${IVR_AUDIO},1,,1,\${IVR_TIMEOUT})
 same => n,Goto(resolve)
 same => n(read_no_prompt),Read(IVR_DIGIT,,1,,1,\${IVR_TIMEOUT})
 same => n(resolve),NoOp(mnscloud ivr digit \${IVR_DIGIT} for \${EXTEN})
 same => n,Set(TARGET_DIAL=\${ODBC_AST_IVR_OPTION_TARGET(\${EXTEN},\${IVR_DIGIT},\${MNSCLOUD_INBOUND_CHANNEL})})
 same => n,GotoIf(\$[\"\${TARGET_DIAL}\" = \"\"]?notfound)
 same => n,Dial(\${TARGET_DIAL},30)
 same => n,Gosub(mnscloud-dial-result,s,1(\${DIALSTATUS}))
 same => n,Hangup()
 same => n(notfound),Hangup(404)

[mnscloud-dial-result]
exten => s,1,NoOp(mnscloud dial result \${ARG1})
 same => n,GotoIf(\$[\"\${ARG1}\" = \"BUSY\"]?busy)
 same => n,GotoIf(\$[\"\${ARG1}\" = \"CHANUNAVAIL\"]?unavailable)
 same => n,GotoIf(\$[\"\${ARG1}\" = \"CONGESTION\"]?congestion)
 same => n,GotoIf(\$[\"\${ARG1}\" = \"NOANSWER\"]?noanswer)
 same => n,Return()
 same => n(busy),Hangup(17)
 same => n(unavailable),Hangup(20)
 same => n(congestion),Hangup(34)
 same => n(noanswer),Hangup(19)"

  write_file "/etc/asterisk/queues.conf" "[general]
persistentmembers = no
autofill = yes
shared_lastcall = yes"

  write_file "/etc/asterisk/cdr_adaptive_odbc.conf" "[mnscloud]
connection=mnscloud
table=AsteriskCdr
alias start => calldate"

  write_file "/etc/asterisk/cel_odbc.conf" "[mnscloud]
connection=mnscloud
table=AsteriskCel"

  write_file "/etc/asterisk/logger.conf" "[general]
dateformat=%F %T

[logfiles]
console => notice,warning,error
messages => notice,warning,error,verbose,security
full => notice,warning,error,debug,verbose,security
security => security"

  run "touch /var/log/asterisk/full /var/log/asterisk/messages /var/log/asterisk/security"
  run "chown asterisk:asterisk /var/log/asterisk/full /var/log/asterisk/messages /var/log/asterisk/security"
  run "chmod 0644 /var/log/asterisk/full /var/log/asterisk/messages /var/log/asterisk/security"

  local local_ip permits permit_line
  local_ip="$(hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i !~ /:/) { print $i; exit }}')"
  permits="${AST_CONTROL_ALLOWED_IPS:-${local_ip}/255.255.255.255}"
  permit_line=""
  IFS=',' read -ra entries <<< "${permits}"
  for entry in "${entries[@]}"; do
    entry="$(echo "$entry" | xargs)"
    [[ -n "$entry" ]] || continue
    permit_line+="permit=${entry}
"
  done
  backup_once "/etc/asterisk/manager.conf"
  write_file "/etc/asterisk/manager.conf" "[general]
enabled=yes
webenabled=no
port=${AST_CONTROL_PORT}
bindaddr=${local_ip}
displayconnects=no
timestampevents=yes

[mnscloud]
secret=${AST_CONTROL_SECRET}
read=system,call,log,verbose,command,agent,user,config,dtmf,reporting,cdr,dialplan
write=system,call,log,verbose,command,agent,user,config,originate,reporting
deny=0.0.0.0/0.0.0.0
${permit_line}"

  run "chown -R asterisk:asterisk /etc/asterisk"
}

write_systemd_service() {
  backup_once "/etc/systemd/system/asterisk.service"
  write_file "/etc/systemd/system/asterisk.service" "[Unit]
Description=Asterisk PBX and telephony daemon
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=asterisk
Group=asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0755
WorkingDirectory=/var/lib/asterisk
ExecStart=/usr/sbin/asterisk -f -C /etc/asterisk/asterisk.conf
ExecReload=/usr/sbin/asterisk -rx 'core reload'
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target"
  run "systemctl daemon-reload"
}

is_public_ipv4() {
  local ip="$1" first second third fourth octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r first second third fourth <<<"$ip"
  for octet in "$first" "$second" "$third" "$fourth"; do
    [[ "$octet" =~ ^[0-9]+$ && "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
  done
  [[ "$first" -eq 10 ]] && return 1
  [[ "$first" -eq 127 ]] && return 1
  [[ "$first" -eq 169 && "$second" -eq 254 ]] && return 1
  [[ "$first" -eq 172 && "$second" -ge 16 && "$second" -le 31 ]] && return 1
  [[ "$first" -eq 192 && "$second" -eq 168 ]] && return 1
  [[ "$first" -eq 100 && "$second" -ge 64 && "$second" -le 127 ]] && return 1
  [[ "$first" -eq 0 ]] && return 1
  return 0
}

discover_public_ip() {
  local ip service
  for service in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    ip="$(curl -fsS --max-time 4 "$service" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_public_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_curl_for_validation() {
  command -v curl >/dev/null 2>&1 && return 0

  if $DRY_RUN; then
    log DRY "apt-get update -y"
    log DRY "apt-get install -y --no-install-recommends ca-certificates curl"
    return 0
  fi

  warn "curl not found; installing the minimum dependency required to validate the Node UUID via API."
  run "apt-get update -y"
  run "apt-get install -y --no-install-recommends ca-certificates curl"
}

json_field() {
  local field="$1" file="$2"
  grep -o "\"${field}\":\"[^\"]*\"" "$file" | head -n1 | cut -d'"' -f4 || true
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

local_ipv4() {
  if [[ -n "${AST_LOCAL_IP}" ]]; then
    printf '%s\n' "${AST_LOCAL_IP}"
    return 0
  fi
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' ||
    hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i !~ /:/) { print $i; exit }}'
}

resolve_public_ipv4() {
  local ip
  if [[ -n "${API_VALIDATED_PUBLIC_IP}" ]]; then
    log_raw "INFO" "Using public IP validated by the API: ${API_VALIDATED_PUBLIC_IP}"
    printf '%s\n' "${API_VALIDATED_PUBLIC_IP}"
    return 0
  fi
  if [[ -n "${AST_PUBLIC_IP}" ]]; then
    if is_public_ipv4 "${AST_PUBLIC_IP}"; then
      printf '%s\n' "${AST_PUBLIC_IP}"
      return 0
    fi
    warn "Ignoring AST_PUBLIC_IP/ASTERISK_PUBLIC_IP because it is not a public IPv4: ${AST_PUBLIC_IP}"
  fi
  if is_truthy "${AST_AUTO_DISCOVER_PUBLIC_IP}"; then
    if ip="$(discover_public_ip 2>/dev/null || true)" && [[ -n "$ip" ]]; then
      log_raw "INFO" "Public IP detected automatically: ${ip}"
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  return 1
}

api_base_host() {
  printf '%s\n' "${API_BASE}" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s#:.*$##'
}

resolve_api_base_ipv4s() {
  local host
  host="$(api_base_host)"
  [[ -n "${host}" ]] || return 1
  getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
}

ensure_control_allowed_ips() {
  local ip entries=() joined=""

  mapfile -t entries < <(resolve_api_base_ipv4s || true)
  if [[ "${#entries[@]}" -eq 0 ]]; then
    ip="$(local_ipv4)"
    [[ -n "${ip}" ]] && entries=("${ip}")
  fi

  for ip in "${entries[@]}"; do
    [[ -n "${ip}" ]] || continue
    [[ -n "${joined}" ]] && joined+=","
    joined+="${ip}/255.255.255.255"
  done

  AST_CONTROL_ALLOWED_IPS="${joined:-127.0.0.1/255.255.255.255}"
  info "AMI allowed IPs auto: ${AST_CONTROL_ALLOWED_IPS}"
}

local_ipv4_cidr() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  ip -o -4 addr show scope global 2>/dev/null | awk -v ip="$ip" '{
    split($4, addr, "/");
    if (addr[1] == ip) {
      print $4;
      exit;
    }
  }'
}

is_global_ipv6() {
  local ip="${1%%/*}" lower
  [[ -n "$ip" && "$ip" == *:* ]] || return 1
  lower="$(echo "$ip" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" == fe80:* ]] && return 1
  [[ "$lower" == ::1 ]] && return 1
  [[ "$lower" == fc* || "$lower" == fd* ]] && return 1
  [[ "$lower" == ::ffff:* ]] && return 1
  return 0
}

local_ipv6_cidr() {
  ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | while read -r cidr; do
    if is_global_ipv6 "$cidr"; then
      printf '%s\n' "$cidr"
      return 0
    fi
  done
}

local_ipv6() {
  local cidr
  cidr="$(local_ipv6_cidr || true)"
  [[ -n "$cidr" ]] || return 1
  printf '%s\n' "${cidr%%/*}"
}

heartbeat() {
  local version payload response_file http_code server_uuid public_ip private_ip control_host private_cidr private_ipv6 private_ipv6_cidr hostname_value
  if $DRY_RUN; then
    log DRY "POST ${API_BASE}/api/v1/pabx/asterisk/heartbeat?node_uuid=${NODE_UUID}"
    return 0
  fi
  version="$(asterisk -V 2>/dev/null | head -n1 | sed 's/^Asterisk //' || true)"
  hostname_value="$(hostname -f 2>/dev/null || hostname)"
  private_ip="$(local_ipv4)"
  private_cidr="$(local_ipv4_cidr "${private_ip}" || true)"
  private_ipv6="$(local_ipv6 || true)"
  private_ipv6_cidr="$(local_ipv6_cidr || true)"
  public_ip="$(resolve_public_ipv4 || true)"
  control_host="${public_ip:-${private_ip}}"
  payload="{\"hostname\":\"$(json_escape "${hostname_value}")\",\"privateIPv4\":\"$(json_escape "${private_ip}")\",\"version\":\"$(json_escape "${version}")\",\"baseUrl\":\"$(json_escape "${API_BASE}")\""
  if [[ -n "${public_ip}" ]]; then
    payload+=",\"publicIPv4\":\"$(json_escape "${public_ip}")\""
  fi
  if [[ -n "${private_cidr}" ]]; then
    payload+=",\"localNet\":\"$(json_escape "${private_cidr}")\""
  fi
  if [[ -n "${private_ipv6}" ]]; then
    payload+=",\"privateIPv6\":\"$(json_escape "${private_ipv6}")\",\"publicIPv6\":\"$(json_escape "${private_ipv6}")\""
  fi
  if [[ -n "${private_ipv6_cidr}" ]]; then
    payload+=",\"localNetIPv6\":\"$(json_escape "${private_ipv6_cidr}")\""
  fi
  payload+=",\"controlHost\":\"$(json_escape "${control_host}")\",\"controlPort\":${AST_CONTROL_PORT},\"controlUsername\":\"mnscloud\",\"controlSecret\":\"$(json_escape "${AST_CONTROL_SECRET}")\",\"controlAllowedIps\":\"$(json_escape "${AST_CONTROL_ALLOWED_IPS}")\""
  payload+="}"
  response_file="$(mktemp)"
  set +e
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${API_BASE}/api/v1/pabx/asterisk/heartbeat?node_uuid=${NODE_UUID}" -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" --data "${payload}" 2>>"${LOG_FILE}")"
  set -e
  if [[ "${http_code}" == "200" ]]; then
    server_uuid="$(json_field "serverUUID" "${response_file}")"
    API_VALIDATED_PUBLIC_IP="$(json_field "publicIPv4" "${response_file}")"
    if ! is_public_ipv4 "${API_VALIDATED_PUBLIC_IP}"; then
      API_VALIDATED_PUBLIC_IP=""
    fi
    if [[ -n "${server_uuid}" ]]; then
      ok "Asterisk server registered/linked in the API. serverUUID: ${server_uuid}"
    else
      ok "Heartbeat Asterisk aceito pela API."
    fi
    [[ -n "${API_VALIDATED_PUBLIC_IP}" ]] && ok "Public IP validated by the API: ${API_VALIDATED_PUBLIC_IP}"
    rm -f "${response_file}"
    return 0
  else
    warn "Asterisk heartbeat returned HTTP ${http_code:-000}. Check that the API is updated/restarted and that the Asterisk server is registered. Response: $(tr '\n' ' ' < "${response_file}" | head -c 200)"
    if [[ "${http_code}" == "401" ]]; then
      warn "HTTP 401 means the local api.token does not match the server token hash, or the API was not updated/restarted with first-heartbeat token initialization."
    elif [[ "${http_code}" == "404" ]]; then
      warn "HTTP 404 means the Node UUID is not saved on an active Asterisk VoipPabxServer record, or the record engine is different."
    fi
  fi
  rm -f "${response_file}"
  return 1
}

wait_for_node_registration() {
  info "Node UUID for this Asterisk host: ${NODE_UUID}"
  info "Register this exact Node UUID in the correct VoipPabxServer Asterisk record before continuing."

  ensure_curl_for_validation

  if [[ -n "${API_TOKEN}" ]]; then
    info "Validating generated Asterisk install credential with the API."
    if heartbeat; then
      return 0
    fi
    warn "Automatic API validation failed; falling back to interactive validation."
  fi

  if $DRY_RUN || ! [[ -t 0 && -r /dev/tty && -w /dev/tty ]]; then
    warn "Interactive terminal is unavailable at /dev/tty; skipping Node UUID registration wait."
    return 1
  fi

  local answer
  while true; do
    printf "%s\n" "After registering the Node UUID in the platform, type 'validate' to test it, or type 'skip' to continue without validation: " >/dev/tty
    if ! IFS= read -r answer </dev/tty; then
      warn "Could not read from /dev/tty; skipping Node UUID registration wait."
      return 1
    fi
    if [[ "${answer,,}" == "skip" ]]; then
      warn "Node UUID registration was not validated. The installer will try HTTPS discovery in the final heartbeat."
      return 1
    fi
    if [[ "${answer,,}" != "validate" ]]; then
      warn "Empty or invalid answer. Register the Node UUID first, then type 'validate'."
      continue
    fi
    if heartbeat; then
      return 0
    fi
    printf "%s\n" "Validation failed. Confirm the Node UUID was saved in the correct Asterisk server record and try again." >/dev/tty
  done
}

validate_and_start() {
  run "asterisk -V"
  run "systemctl enable asterisk"
  run "systemctl restart asterisk"
  if $DRY_RUN; then
    return 0
  fi
  local attempt
  for attempt in {1..20}; do
    if asterisk -rx 'core show uptime' >/dev/null 2>&1; then
      run "asterisk -rx 'core show uptime'"
      run "asterisk -rx 'module show like res_odbc' || true"
      run "asterisk -rx 'module show like res_config_odbc' || true"
      run "asterisk -rx 'module show like res_sorcery_realtime' || true"
      run "asterisk -rx 'module show like res_pjsip' || true"
      run "asterisk -rx 'module show like func_odbc' || true"
      run "asterisk -rx 'module show like res_musiconhold' || true"
      run "asterisk -rx 'module show like app_queue' || true"
      run "asterisk -rx 'module show like g729' || true"
      run "asterisk -rx 'module show like h264' || true"
      run "asterisk -rx 'core show applications like Queue' || true"
      run "asterisk -rx 'core show codecs audio' | grep -i g729 || true"
      run "asterisk -rx 'core show codecs video' | grep -i h264 || true"
      return 0
    fi
    sleep 1
  done
  run "systemctl status asterisk --no-pager || true"
  run "journalctl -u asterisk -n 100 --no-pager || true"
  err "Asterisk did not create the control socket at /run/asterisk/asterisk.ctl after startup."
  return 1
}

main() {
  require_root
  parse_cli_args "$@"
  echo "asterisk        PABX - Asterisk 22.9.x LTS Multi-Tenant (official repository)"
  echo "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
  echo "Log:  ${LOG_FILE}"
  echo "=================================================="
  local app_security_script="${MNSCLOUD_MONOREPO_ROOT:-${PROJECT_ROOT}}/scripts/application-security.sh"
  [[ -f "${app_security_script}" ]] && run "bash '${app_security_script}'"
  ensure_local_hostname_hosts
  load_env_file
  ensure_api_base_file
  ensure_node_uuid_file
  ensure_api_token_file
  ensure_control_secret
  ensure_control_allowed_ips
  detect_asterisk_os >/dev/null
  info "Node UUID: ${NODE_UUID}"
  info "API base:  ${API_BASE}"
  wait_for_node_registration || true
  install_packages_debian
  install_asterisk_from_source
  build_asterisk_g729_codec || true
  ensure_asterisk_user
  ensure_asterisk_db_config
  write_odbc_config
  validate_odbc_config
  write_asterisk_configs
  write_systemd_service
  validate_and_start
  heartbeat || true
  ok "Asterisk installed and configured with MariaDB Realtime. Node UUID: ${NODE_UUID}"
}

main "$@"
