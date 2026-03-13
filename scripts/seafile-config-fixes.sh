#!/bin/bash
# =============================================================================
# seafile-config-fixes.sh
# =============================================================================
# Applies all Seafile configuration from .env to conf files on the storage
# share. Run this AFTER the stack has started at least once (so the conf
# directory exists) and whenever you change settings in .env.
#
# Written by:  this repo (paste to /opt/seafile-config-fixes.sh)
# Run from:    /opt/seafile-config-fixes.sh  or  seafile fix
# Writes to:   $SEAFILE_VOLUME/seafile/conf/seahub_settings.py
#              $SEAFILE_VOLUME/seafile/conf/seafevents.conf
#              $SEAFILE_VOLUME/seafile/conf/seafile.conf
#              $SEAFILE_VOLUME/seafile/conf/seafdav.conf
#              $SEAFILE_VOLUME/seafile/conf/gunicorn.conf.py
#              /etc/cron.d/seafile-gc         (when GC_ENABLED=true)
#              /etc/logrotate.d/seafile-gc    (when GC_ENABLED=true)
#              /opt/seafile-backup.sh         (when BACKUP_ENABLED=true)
#              /etc/cron.d/seafile-backup     (when BACKUP_ENABLED=true)
#              $SEAFILE_VOLUME/seafile-config-fixes.sh  (storage backup)
#              /opt/seafile/seafile_storage_classes.json  (multi-backend — local)
#              $SEAFILE_VOLUME/seafile_storage_classes.json  (multi-backend — copied)
# Deletes:     $SEAFILE_VOLUME/seafile/conf/ccnet.conf  (deprecated — if present)
# =============================================================================

set -e
trap 'echo -e "\n${RED}[ERROR]${NC}  seafile-config-fixes.sh failed at line $LINENO — check output above."; exit 1' ERR

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Please run as root or with sudo."

# ---------------------------------------------------------------------------
# Version display
# ---------------------------------------------------------------------------
_SEAFILE_VERSION="13"
_ENV_PEEK="/opt/seafile/.env"
if [[ -f "$_ENV_PEEK" ]]; then
  _img=$(grep "^SEAFILE_IMAGE=" "$_ENV_PEEK" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)
  if [[ -n "$_img" ]]; then
    _ver=$(echo "$_img" | grep -oP '\d+(\.\d+)+' | head -1 || true)
    [[ -n "$_ver" ]] && _SEAFILE_VERSION="$_ver"
  fi
fi

# ---------------------------------------------------------------------------
# Splash
# ---------------------------------------------------------------------------
_show_splash() {
  clear
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "  ███████╗███████╗ █████╗ ███████╗██╗██╗     ███████╗"
  echo "  ██╔════╝██╔════╝██╔══██╗██╔════╝██║██║     ██╔════╝"
  echo "  ███████╗█████╗  ███████║█████╗  ██║██║     █████╗  "
  echo "  ╚════██║██╔══╝  ██╔══██║██╔══╝  ██║██║     ██╔══╝  "
  echo "  ███████║███████╗██║  ██║██║     ██║███████╗███████╗"
  echo "  ╚══════╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝"
  echo -e "${NC}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${BOLD}nicogits92 / seafile-deploy${NC}   ${DIM}Seafile ${_SEAFILE_VERSION} CE  ·  v4.1-alpha  ·  config-fixes${NC}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${DIM}Community deployment · not affiliated with Seafile Ltd.${NC}"
  echo ""
  echo ""
}

# =============================================================================
# Safe .env loader
# =============================================================================
_load_env() {
  local env_file="${1:-/opt/seafile/.env}"
  [[ ! -f "$env_file" ]] && return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "$line" != *=* ]] && continue
    local key="${line%%=*}" value="${line#*=}"
    if [[ "$value" == \"*\" ]]; then value="${value#\"}"; value="${value%\"}";
    elif [[ "$value" == \'*\' ]]; then value="${value#\'}"; value="${value%\'}"; fi
    export "$key=$value"
  done < "$env_file"
}

# =============================================================================
# Load .env
# =============================================================================
ENV_FILE="/opt/seafile/.env"
[ ! -f "$ENV_FILE" ] && error ".env not found at $ENV_FILE."
_load_env "$ENV_FILE"

SEAFILE_DOMAIN="${SEAFILE_SERVER_HOSTNAME}"
SEAFILE_PROTO="${SEAFILE_SERVER_PROTOCOL:-https}"
SEAFILE_TIMEZONE="${TIME_ZONE:-America/New_York}"
CONF_DIR="${SEAFILE_VOLUME}/seafile/conf"

[[ "$1" != "--yes" ]] && _show_splash

info "Reading configuration from $ENV_FILE"
info "  SEAFILE_VOLUME   = $SEAFILE_VOLUME"
info "  SEAFILE_DOMAIN   = $SEAFILE_DOMAIN"
info "  PROTOCOL         = $SEAFILE_PROTO"
info "  PROXY_TYPE       = ${PROXY_TYPE:-nginx}"
info "  OFFICE_SUITE     = ${OFFICE_SUITE:-collabora}"
info "  CLAMAV_ENABLED   = ${CLAMAV_ENABLED:-false}"
info "  SMTP_ENABLED     = ${SMTP_ENABLED:-false}"
info "  LDAP_ENABLED     = ${LDAP_ENABLED:-false}"
info "  GC_ENABLED       = ${GC_ENABLED:-true}"
info "  BACKUP_ENABLED   = ${BACKUP_ENABLED:-false}"
info "  SEAFDAV_ENABLED  = ${SEAFDAV_ENABLED:-false}"
info "  MULTI_BACKEND_ENABLED = ${MULTI_BACKEND_ENABLED:-false}"
if [[ "${MULTI_BACKEND_ENABLED:-false}" == "true" ]]; then
  info "  MAPPING_POLICY       = ${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}"
fi
if [[ -f "/opt/seafile/.storage-migration.conf" ]]; then
  info "  STORAGE_MIGRATION = active"
fi

if [ ! -d "$CONF_DIR" ]; then
  error "Config directory $CONF_DIR not found.
  The seafile container must have started at least once before running this script."
fi

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
_PHASES=(
  "Clear INIT_SEAFILE_MYSQL_ROOT_PASSWORD from .env"
  "Write seahub_settings.py (office, Redis, SMTP, users, LDAP, ClamAV)"
  "Write seafevents.conf (background workers)"
  "Write seafile.conf + storage backend config (if multi-backend or migrating)"
  "Write seafdav.conf (WebDAV)"
  "Write gunicorn.conf.py"
  "Remove deprecated ccnet.conf"
  "Write GC cron and logrotate (GC_ENABLED)"
  "Write DB snapshot cron (DB_INTERNAL=true) + backup script (BACKUP_ENABLED)"
  "Write Caddyfile (reverse proxy routing)"
  "Restart containers"
  "Back up this script to storage"
)
_SELECTED=(true true true true true true true true true true true true)

_show_menu() {
  local i _num
  echo ""
  echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}   seafile-config-fixes.sh${NC}"
  echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  The following steps will run. Enter a step number to"
  echo "  toggle it off (or back on) before proceeding."
  echo ""
  for i in "${!_PHASES[@]}"; do
    _num=$(( i + 1 ))
    if [[ "${_SELECTED[$i]}" == "true" ]]; then
      echo -e "    [${GREEN}✓${NC}] $(printf '%2d' $_num).  ${_PHASES[$i]}"
    else
      echo -e "    [ ] $(printf '%2d' $_num).  ${_PHASES[$i]}"
    fi
  done
  echo ""
  echo "  Press [Enter] to run, enter a number to toggle, or q to quit."
  echo ""
}

_run_menu() {
  local _input _idx _any
  while true; do
    _show_menu
    read -r -p "  > " _input
    case "$_input" in
      q|Q) echo ""; echo "  Run me again if you change your mind."; echo ""; exit 0 ;;
      "")
        _any=false
        for _s in "${_SELECTED[@]}"; do [[ "$_s" == "true" ]] && _any=true && break; done
        if [[ "$_any" == "false" ]]; then
          echo ""; echo "  Nothing selected."; echo ""; exit 0
        fi
        echo ""; break ;;
      *)
        if [[ "$_input" =~ ^[0-9]+$ ]]; then
          _idx=$(( _input - 1 ))
          if [[ $_idx -ge 0 && $_idx -lt ${#_PHASES[@]} ]]; then
            [[ "${_SELECTED[$_idx]}" == "true" ]] && _SELECTED[$_idx]="false" || _SELECTED[$_idx]="true"
          else
            echo "  No step $_input — try again."
          fi
        else
          echo "  Enter a step number, press [Enter] to run, or q to quit."
        fi ;;
    esac
  done
}

[[ "$1" != "--yes" ]] && _run_menu
_START_TIME=$SECONDS

# =============================================================================
# Step 1 — Clear INIT_SEAFILE_MYSQL_ROOT_PASSWORD
# =============================================================================
if [[ "${_SELECTED[0]}" == "true" ]]; then
if grep -q "^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=." "$ENV_FILE"; then
  sed -i 's/^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=.*/INIT_SEAFILE_MYSQL_ROOT_PASSWORD=/' "$ENV_FILE"
  warn "INIT_SEAFILE_MYSQL_ROOT_PASSWORD cleared from $ENV_FILE."
  warn "Storage backup will sync automatically."
else
  info "INIT_SEAFILE_MYSQL_ROOT_PASSWORD already blank — skipping."
fi
fi

# =============================================================================
# Step 2 — seahub_settings.py
# =============================================================================
if [[ "${_SELECTED[1]}" == "true" ]]; then
info "Writing seahub_settings.py..."

# Preserve existing SECRET_KEY so active sessions are not invalidated
EXISTING_KEY=""
if [ -f "${CONF_DIR}/seahub_settings.py" ]; then
  EXISTING_KEY=$(grep "^SECRET_KEY" "${CONF_DIR}/seahub_settings.py" 2>/dev/null | head -1 | cut -d'"' -f2)
fi
[ -z "$EXISTING_KEY" ] && EXISTING_KEY=$(openssl rand -base64 40)

# Redis URL — omit password when blank (redis://:@host sends empty AUTH which Redis 7+ rejects)
if [ -n "$REDIS_PASSWORD" ]; then
  REDIS_URL="redis://:${REDIS_PASSWORD}@redis:6379/0"
else
  REDIS_URL="redis://redis:6379/0"
fi

{
cat << SEAHUBEOF
# -*- coding: utf-8 -*-
# Generated by seafile-config-fixes.sh — do not edit by hand.
# Re-run: seafile fix

SECRET_KEY = "${EXISTING_KEY}"
TIME_ZONE = '${SEAFILE_TIMEZONE}'

# --- Redis cache ---
CACHES = {
    'default': {
        'BACKEND': 'django_redis.cache.RedisCache',
        'LOCATION': '${REDIS_URL}',
        'TIMEOUT': 86400,
    }
}

# --- File handling ---
FILE_PREVIEW_MAX_SIZE = 30 * 1024 * 1024
COMPRESS_ENABLED = True

# --- Metadata / Extended Properties ---
ENABLE_METADATA_MANAGEMENT = True
METADATA_SERVER_URL = 'http://metadata-server:8084'

SEAHUBEOF

# --- Office suite ---
if [[ "${OFFICE_SUITE:-collabora}" == "none" ]]; then
  : # No office suite — skip config
elif [[ "${OFFICE_SUITE:-collabora}" == "onlyoffice" ]]; then
cat << OOEOF
# --- OnlyOffice ---
ENABLE_ONLYOFFICE = True
VERIFY_ONLYOFFICE_CERTIFICATE = False
ONLYOFFICE_APIJS_URL = '${SEAFILE_PROTO}://${SEAFILE_DOMAIN}:${ONLYOFFICE_PORT:-6233}/web-apps/apps/api/documents/api.js'
ONLYOFFICE_FILE_EXTENSION = ('doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'odt', 'ods', 'odp', 'csv')
ONLYOFFICE_EDIT_FILE_EXTENSION = ('doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'odt', 'ods', 'odp')
ONLYOFFICE_JWT_SECRET = '${ONLYOFFICE_JWT_SECRET}'

OOEOF
else
cat << COLLABEOF
# --- Collabora Online ---
OFFICE_SERVER_TYPE = 'CollaboraOffice'
ENABLE_OFFICE_WEB_APP = True
OFFICE_WEB_APP_BASE_URL = '${SEAFILE_PROTO}://${SEAFILE_DOMAIN}/hosting/discovery'
WOPI_ACCESS_TOKEN_EXPIRATION = 30 * 60
OFFICE_WEB_APP_FILE_EXTENSION = ('odp', 'ods', 'odt', 'xls', 'xlsb', 'xlsm', 'xlsx', 'ppsx', 'ppt', 'pptm', 'pptx', 'doc', 'docm', 'docx')
ENABLE_OFFICE_WEB_APP_EDIT = True
OFFICE_WEB_APP_EDIT_FILE_EXTENSION = ('odp', 'ods', 'odt', 'xls', 'xlsb', 'xlsm', 'xlsx', 'ppsx', 'ppt', 'pptm', 'pptx', 'doc', 'docm', 'docx')

COLLABEOF
fi

# --- SMTP ---
if [[ "${SMTP_ENABLED:-false}" == "true" ]]; then
cat << SMTPEOF
# --- Email / SMTP ---
EMAIL_USE_TLS = ${SMTP_USE_TLS:-true}
EMAIL_HOST = '${SMTP_HOST}'
EMAIL_PORT = ${SMTP_PORT:-465}
EMAIL_HOST_USER = '${SMTP_USER}'
EMAIL_HOST_PASSWORD = '${SMTP_PASSWORD}'
DEFAULT_FROM_EMAIL = '${SMTP_FROM:-noreply@yourdomain.com}'
SERVER_EMAIL = '${SMTP_FROM:-noreply@yourdomain.com}'

SMTPEOF
fi

# --- User and library settings ---
_quota="${DEFAULT_USER_QUOTA_GB:-0}"
_max_upload="${MAX_UPLOAD_SIZE_MB:-0}"
_trash="${TRASH_CLEAN_AFTER_DAYS:-30}"
_2fa="${FORCE_2FA:-false}"
_guest="${ENABLE_GUEST:-false}"

cat << USERSEOF
# --- User and library settings ---
FORCE_PASSWORD_CHANGE = False
$([ "$_quota" != "0" ] && echo "USER_DEFAULT_QUOTA = ${_quota} * 1024")
$([ "$_max_upload" != "0" ] && echo "MAX_UPLOAD_SIZE = ${_max_upload}")
$([ "$_trash" != "0" ] && echo "TRASH_CLEAN_AFTER_DAYS = ${_trash}")
$([ "${_2fa,,}" == "true" ] && echo "ENABLE_FORCE_2FA = True")
$([ "${_guest,,}" == "true" ] && echo "ENABLE_GUEST = True")

USERSEOF

# --- LDAP ---
if [[ "${LDAP_ENABLED:-false}" == "true" ]]; then
cat << LDAPEOF
# --- LDAP / Active Directory ---
ENABLE_LDAP = True
LDAP_SERVER_URL = '${LDAP_URL}'
LDAP_BASE_DN = '${LDAP_BASE_DN}'
LDAP_ADMIN_DN = '${LDAP_BIND_DN}'
LDAP_ADMIN_PASSWORD = '${LDAP_BIND_PASSWORD}'
LDAP_LOGIN_ATTR = '${LDAP_LOGIN_ATTR:-mail}'
$([ -n "${LDAP_FILTER:-}" ] && echo "LDAP_FILTER = '${LDAP_FILTER}'")

LDAPEOF
fi

# --- ClamAV ---
if [[ "${CLAMAV_ENABLED:-false}" == "true" ]]; then
cat << CLAMAVEOF
# --- ClamAV antivirus ---
ENABLE_VIRUS_SCAN = True
CLAMAV_SERVER_URL = 'seafile-clamav:3310'

CLAMAVEOF
fi

# --- Multi-backend storage classes ---
if [[ "${MULTI_BACKEND_ENABLED:-false}" == "true" ]]; then
cat << STORCLASSEOF
# --- Storage classes ---
ENABLE_STORAGE_CLASSES = True
STORAGE_CLASS_MAPPING_POLICY = '${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}'

STORCLASSEOF
fi

} > "${CONF_DIR}/seahub_settings.py"

fi

# =============================================================================
# Step 3 — seafevents.conf
# =============================================================================
if [[ "${_SELECTED[2]}" == "true" ]]; then
info "Writing seafevents.conf..."
cat > "${CONF_DIR}/seafevents.conf" << 'SEAFEVENTSEOF'
[SEAHUB EMAIL]
enabled = true
interval = 30m

[STATISTICS]
enabled = true

[FILE HISTORY]
enabled = true
suffix = md,txt,doc,docx,xls,xlsx,ppt,pptx,sdoc

[AUDIT]
enabled = true

[VIRUS SCAN]
enabled = false

[METADATA]
enabled = true

# Redis connection is required for the metadata worker.
[REDIS]
host = redis
port = 6379
SEAFEVENTSEOF
# Append password only when set — sending AUTH "" to no-auth Redis 7+ returns an error.
[ -n "$REDIS_PASSWORD" ] && echo "password = ${REDIS_PASSWORD}" >> "${CONF_DIR}/seafevents.conf"

# Enable virus scan section if ClamAV is active
if [[ "${CLAMAV_ENABLED:-false}" == "true" ]]; then
  sed -i 's/^\[VIRUS SCAN\]/[VIRUS SCAN]/' "${CONF_DIR}/seafevents.conf"
  sed -i '/^\[VIRUS SCAN\]/{n;s/enabled = false/enabled = true/}' "${CONF_DIR}/seafevents.conf"
  info "ClamAV: enabled virus scan in seafevents.conf"
fi
fi

# =============================================================================
# Step 4 — seafile.conf
# =============================================================================
if [[ "${_SELECTED[3]}" == "true" ]]; then
info "Writing seafile.conf..."

# --- Base seafile.conf ---
{
cat << 'SEAFILEEOF'
[fileserver]
port = 8082
SEAFILEEOF

if [[ "${MAX_UPLOAD_SIZE_MB:-0}" != "0" ]]; then
  echo "max_upload_size = ${MAX_UPLOAD_SIZE_MB}"
fi

# --- Multi-backend storage configuration ---
# The storage_classes.json is generated locally first (always available, no mount dependency),
# then copied to the storage volume where Seafile reads it from inside the container.
MIGRATION_CONF="/opt/seafile/.storage-migration.conf"
STORAGE_JSON_LOCAL="/opt/seafile/seafile_storage_classes.json"
STORAGE_JSON_MOUNT="${SEAFILE_VOLUME}/seafile_storage_classes.json"

# Helper to copy local JSON to mounted storage
_copy_storage_json() {
  if [[ -f "$STORAGE_JSON_LOCAL" ]]; then
    cp "$STORAGE_JSON_LOCAL" "$STORAGE_JSON_MOUNT"
    info "  Copied storage_classes.json to ${SEAFILE_VOLUME}/"
  fi
}

# Check if migration is in progress
if [[ -f "$MIGRATION_CONF" ]]; then
  info "  Storage migration in progress — generating temporary dual-backend config"
  # shellcheck disable=SC1090
  source "$MIGRATION_CONF"
  
  # Add storage backend reference to seafile.conf
  echo ""
  echo "[storage]"
  echo "enable_storage_classes = true"
  echo "storage_classes_file = /shared/seafile_storage_classes.json"
  
  # Generate dual-backend JSON for migration (locally first)
  cat > "$STORAGE_JSON_LOCAL" << MIGRATIONJSON
[
  {
    "storage_id": "${SOURCE_STORAGE_ID:-old}",
    "name": "Source Storage (migrating from)",
    "is_default": false,
    "commits": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "fs": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "blocks": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    }
  },
  {
    "storage_id": "${TARGET_STORAGE_ID:-new}",
    "name": "Target Storage (migrating to)",
    "is_default": true,
    "commits": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "fs": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "blocks": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    }
  }
]
MIGRATIONJSON
  _copy_storage_json
  info "  Generated temporary storage_classes.json for migration"

elif [[ "${MULTI_BACKEND_ENABLED:-false}" == "true" ]]; then
  info "  Multi-backend storage enabled — generating storage_classes.json"
  
  # Add storage backend reference to seafile.conf
  echo ""
  echo "[storage]"
  echo "enable_storage_classes = true"
  echo "storage_classes_file = /shared/seafile_storage_classes.json"
  
  # Generate storage_classes.json from BACKEND_N_* variables (locally first)
  echo "[" > "$STORAGE_JSON_LOCAL"
  
  _first_backend=true
  _backend_n=1
  while true; do
    _id_var="BACKEND_${_backend_n}_ID"
    _id="${!_id_var:-}"
    
    # Stop when we hit an undefined backend
    [[ -z "$_id" ]] && break
    
    _name_var="BACKEND_${_backend_n}_NAME"
    _default_var="BACKEND_${_backend_n}_DEFAULT"
    _mount_var="BACKEND_${_backend_n}_MOUNT"
    
    _name="${!_name_var:-Backend $_backend_n}"
    _is_default="${!_default_var:-false}"
    _mount="${!_mount_var:-}"
    
    # Add comma before all but the first entry
    if [[ "$_first_backend" != "true" ]]; then
      echo "," >> "$STORAGE_JSON_LOCAL"
    fi
    _first_backend=false
    
    cat >> "$STORAGE_JSON_LOCAL" << BACKENDENTRY
  {
    "storage_id": "$_id",
    "name": "$_name",
    "is_default": $_is_default,
    "commits": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "fs": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    },
    "blocks": {
      "backend": "fs",
      "dir": "/shared/seafile-data"
    }
  }
BACKENDENTRY
    
    info "    Added backend: $_id ($_name)${_is_default:+ [default]}"
    ((_backend_n++))
  done
  
  echo "]" >> "$STORAGE_JSON_LOCAL"
  _copy_storage_json
  info "  Generated storage_classes.json with $((_backend_n - 1)) backends"

else
  # Single-backend mode — remove storage_classes.json if it exists
  if [[ -f "$STORAGE_JSON_LOCAL" ]]; then
    rm -f "$STORAGE_JSON_LOCAL"
    info "  Removed local storage_classes.json (single-backend mode)"
  fi
  if [[ -f "$STORAGE_JSON_MOUNT" ]]; then
    rm -f "$STORAGE_JSON_MOUNT"
    info "  Removed storage_classes.json from storage (single-backend mode)"
  fi
fi

} > "${CONF_DIR}/seafile.conf"
fi

# =============================================================================
# Step 5 — seafdav.conf
# =============================================================================
if [[ "${_SELECTED[4]}" == "true" ]]; then
info "Writing seafdav.conf (SEAFDAV_ENABLED=${SEAFDAV_ENABLED:-false})..."
cat > "${CONF_DIR}/seafdav.conf" << SEAFDAVEOF
[WEBDAV]
enabled = ${SEAFDAV_ENABLED:-false}
port = 8080
share_name = /seafdav
SEAFDAVEOF
fi

# =============================================================================
# Step 6 — gunicorn.conf.py
# =============================================================================
if [[ "${_SELECTED[5]}" == "true" ]]; then
info "Writing gunicorn.conf.py..."
# Scale timeout with max upload size: 1200s baseline + 1s per MB, capped at 3600s
_timeout=1200
if [[ "${MAX_UPLOAD_SIZE_MB:-0}" != "0" ]]; then
  _timeout=$(( 1200 + MAX_UPLOAD_SIZE_MB ))
  (( _timeout > 3600 )) && _timeout=3600
fi
cat > "${CONF_DIR}/gunicorn.conf.py" << GUNICORNEOF
import os

daemon = True
workers = 5

bind = "127.0.0.1:8000"

pids_dir = '/opt/seafile/pids'
pidfile = os.path.join(pids_dir, 'seahub.pid')

# Timeout scaled to MAX_UPLOAD_SIZE_MB (${MAX_UPLOAD_SIZE_MB:-0} MB → ${_timeout}s)
timeout = ${_timeout}
limit_request_line = 8190

forwarder_headers = 'SCRIPT_NAME,PATH_INFO,REMOTE_USER'
GUNICORNEOF
fi

# =============================================================================
# Step 7 — Remove deprecated ccnet.conf
# =============================================================================
if [[ "${_SELECTED[6]}" == "true" ]]; then
CCNET_CONF="${CONF_DIR}/ccnet.conf"
if [ -f "$CCNET_CONF" ]; then
  if grep -q "^\[General\]" "$CCNET_CONF"; then
    rm "$CCNET_CONF"
    info "Removed deprecated ccnet.conf"
  else
    warn "ccnet.conf exists but looks hand-crafted — leaving in place."
    warn "  Remove manually if not needed: rm $CCNET_CONF"
  fi
else
  info "ccnet.conf not present — nothing to remove."
fi
fi

# =============================================================================
# Step 8 — GC cron and logrotate
# =============================================================================
if [[ "${_SELECTED[7]}" == "true" ]]; then
if [[ "${GC_ENABLED:-true}" == "true" ]]; then
  info "Writing GC cron and logrotate..."

  _gc_flags=""
  [[ "${GC_REMOVE_DELETED:-true}" == "true" ]] && _gc_flags="${_gc_flags} -r"
  [[ "${GC_DRY_RUN:-false}" == "true" ]]       && _gc_flags="${_gc_flags} --dry-run"
  _gc_flags="${_gc_flags# }"  # trim leading space

  # Build the gc command string
  _gc_cmd="docker exec seafile /scripts/gc.sh ${_gc_flags}"
  _gc_log="/var/log/seafile-gc.log"

  cat > /etc/cron.d/seafile-gc << GCCRONEOF
# Seafile garbage collection — managed by seafile-config-fixes.sh
# To change schedule, update GC_SCHEDULE in /opt/seafile/.env and re-run: seafile fix
# Schedule: ${GC_SCHEDULE:-0 3 * * 0}  (${GC_DRY_RUN:-false} dry_run, ${GC_REMOVE_DELETED:-true} remove_deleted)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${GC_SCHEDULE:-0 3 * * 0} root ${_gc_cmd} >> ${_gc_log} 2>&1
GCCRONEOF
  chmod 644 /etc/cron.d/seafile-gc

  cat > /etc/logrotate.d/seafile-gc << GCLOGEOF
${_gc_log} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
GCLOGEOF

  info "GC cron written: ${GC_SCHEDULE:-0 3 * * 0}"
  [[ "${GC_DRY_RUN:-false}" == "true" ]] && warn "GC_DRY_RUN=true — GC will log what it would collect but not remove anything."
else
  # GC disabled — remove cron if it exists
  if [ -f /etc/cron.d/seafile-gc ]; then
    rm /etc/cron.d/seafile-gc
    info "GC disabled — removed /etc/cron.d/seafile-gc"
  else
    info "GC disabled — no cron to remove."
  fi
fi
fi

# =============================================================================
# Step 9 — Backup script and cron
# =============================================================================
if [[ "${_SELECTED[8]}" == "true" ]]; then
# ---------------------------------------------------------------------------
# Automatic DB snapshot — always active when DB_INTERNAL=true and using
# network storage. Writes nightly dumps to ${SEAFILE_VOLUME}/db-backup/.
# This is the primary disaster-recovery mechanism for the bundled database.
# ---------------------------------------------------------------------------
_DB_SNAPSHOT_CRON=/etc/cron.d/seafile-db-snapshot
_DB_SNAPSHOT_LOGROTATE=/etc/logrotate.d/seafile-db-snapshot

if [[ "${DB_INTERNAL:-true}" == "true" && "${STORAGE_TYPE:-nfs}" != "local" ]]; then
  info "DB_INTERNAL=true — writing nightly DB snapshot cron..."
  mkdir -p "${SEAFILE_VOLUME}/db-backup"

  cat > /opt/seafile-db-snapshot.sh << 'DBSNAPEOF'
#!/bin/bash
# =============================================================================
# Seafile DB snapshot — managed by seafile-config-fixes.sh
# Runs nightly. Dumps all three Seafile databases to SEAFILE_VOLUME/db-backup/
# using docker exec so it reaches the internal seafile-db container.
# Keeps the last 7 daily dumps.
# =============================================================================
set -euo pipefail
LOG="/var/log/seafile-db-snapshot.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $1" | tee -a "$LOG"; }
err() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG"; exit 1; }

# Source .env for volume path and credentials
ENV_FILE="/opt/seafile/.env"
[[ -f "$ENV_FILE" ]] || err ".env not found at $ENV_FILE"
_load_env "$ENV_FILE"

DEST="${SEAFILE_VOLUME}/db-backup"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$DEST"

# Verify the seafile-db container is running
docker ps --format '{{.Names}}' | grep -q '^seafile-db$' \
  || err "seafile-db container is not running — skipping dump"

log "Starting DB snapshot — ${TIMESTAMP}"

for db in \
    "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
    "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
    "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do
  docker exec seafile-db \
    mysqldump \
      -u "${SEAFILE_MYSQL_DB_USER:-seafile}" \
      -p"${SEAFILE_MYSQL_DB_PASSWORD}" \
      --single-transaction \
      --quick \
      "${db}" \
    | gzip > "${DEST}/${db}_${TIMESTAMP}.sql.gz" \
    && log "  Dumped ${db}" \
    || err "  Failed to dump ${db}"
done

# Keep last 7 days per database
find "$DEST" -name "*.sql.gz" -mtime +7 -delete 2>/dev/null || true

log "DB snapshot complete."
DBSNAPEOF
  chmod +x /opt/seafile-db-snapshot.sh

  cat > "$_DB_SNAPSHOT_CRON" << DBCRONEOF
# Seafile internal DB nightly snapshot — managed by seafile-config-fixes.sh
# Dumps to ${SEAFILE_VOLUME}/db-backup/ — last 7 days retained.
# To change the schedule, edit BACKUP_SCHEDULE in .env and run: seafile fix
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

0 1 * * * root /opt/seafile-db-snapshot.sh
DBCRONEOF
  chmod 644 "$_DB_SNAPSHOT_CRON"

  cat > "$_DB_SNAPSHOT_LOGROTATE" << 'LOGEOF'
/var/log/seafile-db-snapshot.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
LOGEOF
  info "DB snapshot cron written — nightly at 1am → ${SEAFILE_VOLUME}/db-backup/"

else
  # Remove snapshot cron if DB_INTERNAL switched off or STORAGE_TYPE=local
  [[ -f "$_DB_SNAPSHOT_CRON" ]]     && rm -f "$_DB_SNAPSHOT_CRON"     && warn "Removed DB snapshot cron (DB_INTERNAL or local storage)."
  [[ -f "$_DB_SNAPSHOT_LOGROTATE" ]] && rm -f "$_DB_SNAPSHOT_LOGROTATE"
fi

# ---------------------------------------------------------------------------
# BACKUP_ENABLED — full backup (database + rsync of storage share)
# ---------------------------------------------------------------------------
if [[ "${BACKUP_ENABLED:-false}" == "true" ]]; then
  if [[ -z "${BACKUP_DEST:-}" ]]; then
    warn "BACKUP_ENABLED=true but BACKUP_DEST is blank — skipping backup setup."
    warn "  Set BACKUP_DEST in .env and re-run: seafile fix"
  elif [[ "${BACKUP_DEST}" == "${SEAFILE_VOLUME}" ]]; then
    warn "BACKUP_DEST is the same as SEAFILE_VOLUME — this would back up to itself."
    warn "  Set BACKUP_DEST to a different path or mount and re-run: seafile fix"
  else
    info "Writing backup script to /opt/seafile-backup.sh..."

    # Build the database dump snippet based on DB_INTERNAL
    if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
      _DB_DUMP_SNIPPET=$(cat << 'SNIPPETEOF'
# --- Database dump (internal container via docker exec) ---
log "Dumping databases via docker exec seafile-db..."
docker ps --format '{{.Names}}' | grep -q '^seafile-db$' \
  || { err "seafile-db is not running — database dump skipped"; }

for db in \
    "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
    "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
    "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do
  docker exec seafile-db \
    mysqldump \
      -u "${SEAFILE_MYSQL_DB_USER:-seafile}" \
      -p"${SEAFILE_MYSQL_DB_PASSWORD}" \
      --single-transaction \
      --quick \
      "${db}" \
    | gzip > "${BACKUP_DEST}/db/${db}_${TIMESTAMP}.sql.gz" \
    && log "  Dumped ${db}" \
    || err "  Failed to dump ${db}"
done
SNIPPETEOF
)
    else
      _DB_DUMP_SNIPPET=$(cat << 'SNIPPETEOF'
# --- Database dump (external server via mysqldump client) ---
log "Dumping databases from external server ${DB_HOST}..."
for db in \
    "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
    "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
    "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do
  mysqldump \
    -h "${DB_HOST}" -P "${DB_PORT}" \
    -u "${DB_USER}" -p"${DB_PASS}" \
    --single-transaction \
    --quick \
    "${db}" \
    | gzip > "${BACKUP_DEST}/db/${db}_${TIMESTAMP}.sql.gz" \
    && log "  Dumped ${db}" \
    || err "  Failed to dump ${db}"
done
SNIPPETEOF
)
    fi

    cat > /opt/seafile-backup.sh << BACKUPSCRIPTEOF
#!/bin/bash
# =============================================================================
# Seafile automated backup — managed by seafile-config-fixes.sh
# Do not edit by hand. Change settings in /opt/seafile/.env and re-run:
#   seafile fix
# =============================================================================
set -euo pipefail
LOG_TAG="seafile-backup"
log()  { logger -t "\${LOG_TAG}" "\$1"; echo "\$(date '+%Y-%m-%d %H:%M:%S') [INFO]  \$1"; }
err()  { logger -t "\${LOG_TAG}" "ERROR: \$1"; echo "\$(date '+%Y-%m-%d %H:%M:%S') [ERROR] \$1"; }

# Source .env for current values
ENV_FILE="/opt/seafile/.env"
[[ -f "\$ENV_FILE" ]] && set -a && source "\$ENV_FILE" && set +a

SEAFILE_VOLUME="${SEAFILE_VOLUME}"
BACKUP_DEST="${BACKUP_DEST}"
DB_HOST="${SEAFILE_MYSQL_DB_HOST}"
DB_PORT="${SEAFILE_MYSQL_DB_PORT:-3306}"
DB_USER="${SEAFILE_MYSQL_DB_USER:-seafile}"
DB_PASS="${SEAFILE_MYSQL_DB_PASSWORD}"
TIMESTAMP="\$(date '+%Y%m%d_%H%M%S')"

log "Starting Seafile backup — \${TIMESTAMP}"
mkdir -p "\${BACKUP_DEST}/db" "\${BACKUP_DEST}/data"

${_DB_DUMP_SNIPPET}

# Remove database dumps older than 14 days
find "\${BACKUP_DEST}/db" -name "*.sql.gz" -mtime +14 -delete 2>/dev/null || true

# --- Data rsync ---
# Exclude db-backup/ — it lives on the share but should not be recursively rsynced
log "Rsyncing \${SEAFILE_VOLUME} → \${BACKUP_DEST}/data ..."
rsync -aH --delete \
  --exclude='db-backup/' \
  "\${SEAFILE_VOLUME}/" "\${BACKUP_DEST}/data/" \
  && log "rsync complete" \
  || err "rsync failed — partial backup may exist"

log "Backup complete."
BACKUPSCRIPTEOF
    chmod +x /opt/seafile-backup.sh

    cat > /etc/cron.d/seafile-backup << BACKUPCRONEOF
# Seafile backup — managed by seafile-config-fixes.sh
# To change schedule, update BACKUP_SCHEDULE in /opt/seafile/.env and re-run: seafile fix
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${BACKUP_SCHEDULE:-0 2 * * *} root /opt/seafile-backup.sh
BACKUPCRONEOF
    chmod 644 /etc/cron.d/seafile-backup
    info "Backup cron written: ${BACKUP_SCHEDULE:-0 2 * * *} → ${BACKUP_DEST}"
  fi
else
  # Backup disabled — remove cron if it exists
  [[ -f /etc/cron.d/seafile-backup ]] && rm -f /etc/cron.d/seafile-backup && warn "Removed backup cron (BACKUP_ENABLED=false)."
  [[ -f /opt/seafile-backup.sh ]]     && rm -f /opt/seafile-backup.sh
fi
fi  # _SELECTED[8]

# =============================================================================
# Step 10 — Write Caddyfile
# =============================================================================
if [[ "${_SELECTED[9]}" == "true" ]]; then
info "Writing Caddyfile..."

CADDYFILE_PATH="${CADDY_CONFIG_PATH:-/opt/seafile-caddy}/Caddyfile"
mkdir -p "$(dirname "$CADDYFILE_PATH")"

# Determine site address based on PROXY_TYPE
# caddy-bundled: use domain name — Caddy handles ACME/SSL automatically
# all others:    use :80 — Caddy sits behind an external reverse proxy
_CADDY_SITE_ADDR=":80"
if [[ "${PROXY_TYPE:-nginx}" == "caddy-bundled" ]]; then
  if [[ -n "${SEAFILE_SERVER_HOSTNAME:-}" ]]; then
    _CADDY_SITE_ADDR="${SEAFILE_SERVER_HOSTNAME}"
    info "  PROXY_TYPE=caddy-bundled — Caddy will handle SSL for ${SEAFILE_SERVER_HOSTNAME}"
  else
    warn "  PROXY_TYPE=caddy-bundled but SEAFILE_SERVER_HOSTNAME is blank — falling back to :80"
  fi
fi

cat > "$CADDYFILE_PATH" << CADDYEOF
# Generated by seafile-config-fixes.sh — do not edit directly.
# To regenerate: seafile fix

${_CADDY_SITE_ADDR} {

    # --- SeaDoc REST API ---
    handle_path /sdoc-server/* {
        reverse_proxy seadoc:80 {
            transport http {
                read_timeout 36000s
                write_timeout 36000s
            }
        }
    }

    # --- SeaDoc WebSocket ---
    handle /socket.io/* {
        reverse_proxy seadoc:80 {
            transport http {
                read_timeout 36000s
                write_timeout 36000s
            }
        }
    }

    # --- Notification Server ---
    handle_path /notification/* {
        reverse_proxy notification-server:8083
    }

    # --- Metadata Server ---
    handle_path /metadata/* {
        reverse_proxy metadata-server:8084
    }

    # --- Thumbnail Server ---
    handle_path /thumbnail-server/* {
        reverse_proxy thumbnail-server:80
    }

    # --- Collabora Online ---
    handle /browser/* {
        reverse_proxy collabora:9980
    }

    handle /hosting/* {
        reverse_proxy collabora:9980
    }

    handle /cool/* {
        reverse_proxy collabora:9980 {
            transport http {
                read_timeout 36000s
                write_timeout 36000s
            }
        }
    }

    handle /lool/* {
        reverse_proxy collabora:9980 {
            transport http {
                read_timeout 36000s
                write_timeout 36000s
            }
        }
    }

    # --- Seafile Core (catch-all) ---
    handle {
        reverse_proxy seafile:80 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-Proto ${SEAFILE_SERVER_PROTOCOL:-https}
        }
    }
}
CADDYEOF

chmod 644 "$CADDYFILE_PATH"
info "Caddyfile written to $CADDYFILE_PATH (site: ${_CADDY_SITE_ADDR})"

fi  # _SELECTED[9]

# =============================================================================
# Step 11 — Restart containers
# =============================================================================
if [[ "${_SELECTED[10]}" == "true" ]]; then
info "Restarting containers..."

# Always restart the core set
_to_restart=(seafile-caddy seafile-redis seafile seadoc notification-server thumbnail-server seafile-metadata)

# Add the active office suite container
if [[ "${OFFICE_SUITE:-collabora}" == "none" ]]; then
  : # No office suite container
elif [[ "${OFFICE_SUITE:-collabora}" == "onlyoffice" ]]; then
  docker inspect seafile-onlyoffice &>/dev/null && _to_restart+=(seafile-onlyoffice)
else
  docker inspect seafile-collabora &>/dev/null && _to_restart+=(seafile-collabora)
fi

# Add ClamAV if running
docker inspect seafile-clamav &>/dev/null && _to_restart+=(seafile-clamav)

docker restart "${_to_restart[@]}"
info "Containers restarted."
fi

# =============================================================================
# Step 12 — Back up this script to storage
# =============================================================================
if [[ "${_SELECTED[11]}" == "true" ]]; then
NFS_FIXES="${SEAFILE_VOLUME}/seafile-config-fixes.sh"
info "Backing up seafile-config-fixes.sh to storage backup..."
cp "$0" "$NFS_FIXES"
chmod +x "$NFS_FIXES"
info "Backed up to $NFS_FIXES"
fi

# =============================================================================
# Commit to config history
# =============================================================================
HISTORY_DIR="/opt/seafile/.config-history"
if [[ "${CONFIG_HISTORY_ENABLED:-true}" == "true" && -d "$HISTORY_DIR/.git" ]]; then
  cp /opt/seafile/.env "$HISTORY_DIR/.env" 2>/dev/null || true
  [[ -f /opt/seafile/docker-compose.yml ]] && cp /opt/seafile/docker-compose.yml "$HISTORY_DIR/docker-compose.yml" 2>/dev/null || true
  cp "$0" "$HISTORY_DIR/seafile-config-fixes.sh" 2>/dev/null || true
  [[ -f /opt/update.sh ]] && cp /opt/update.sh "$HISTORY_DIR/update.sh" 2>/dev/null || true
  cd "$HISTORY_DIR" && git add -A 2>/dev/null && \
    { git diff --cached --quiet 2>/dev/null || git commit -m "$(date '+%Y-%m-%d %H:%M:%S') config-fixes applied" --quiet 2>/dev/null; }
  git update-server-info 2>/dev/null || true
  info "Config history updated"
fi

# =============================================================================
# Done
# =============================================================================
_ELAPSED=$(( SECONDS - _START_TIME ))
if   (( _ELAPSED < 60 ));   then _DURATION="${_ELAPSED}s"
elif (( _ELAPSED < 3600 )); then _DURATION="$(( _ELAPSED / 60 ))m $(( _ELAPSED % 60 ))s"
else                              _DURATION="$(( _ELAPSED / 3600 ))h $(( (_ELAPSED % 3600) / 60 ))m"
fi

echo ""
echo -e "  ${DIM}Completed in ${_DURATION}.${NC}"
echo ""
echo -e "  ${DIM}Enable Extended Properties per library (cannot be automated):${NC}"
echo -e "  ${DIM}    Seafile → open a library → Settings → Extended Properties${NC}"
echo ""
echo -e "  ${DIM}Verify your stack:${NC}"
echo -e "  ${DIM}    seafile ping     # endpoint health checks${NC}"
echo -e "  ${DIM}    seafile status   # container health, storage, and disk usage${NC}"
echo ""
echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}  ✓  Configuration applied successfully.${NC}"
echo ""
