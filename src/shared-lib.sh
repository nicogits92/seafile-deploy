# =============================================================================
# shared-lib.sh — Shared functions, data, and helpers
# =============================================================================
# Embedded into every generated script by build.sh. Single source of truth for:
#   - Default values and DO NOT CHANGE variable lists
#   - .env normalization (merge missing keys from template)
#   - Secret writing (set_env_secret Python helper)
#   - Docker Compose profile computation
#   - Config review helpers (_mask_secret, _get_default, _is_dnc, _pfv)
#   - Interactive phase-toggle menu (_show_menu / _run_menu)
#   - DNC risk descriptions
# =============================================================================

# ---------------------------------------------------------------------------
# Deployment version
# ---------------------------------------------------------------------------
DEPLOY_VERSION="v4.3-alpha"

# ---------------------------------------------------------------------------
# Colours (safe to re-source — just variable assignments)
# ---------------------------------------------------------------------------
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Safe .env loader — replaces `set -a; source` to prevent bash interpretation
# of values containing spaces, globs, or special characters.
# Reads KEY=VALUE lines, strips surrounding quotes, exports the variable.
# ---------------------------------------------------------------------------
_load_env() {
  local env_file="${1:-/opt/seafile/.env}"
  [[ ! -f "$env_file" ]] && return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Skip lines without =
    [[ "$line" != *=* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"

    # Strip surrounding double or single quotes
    if [[ "$value" == \"*\" ]]; then
      value="${value#\"}"
      value="${value%\"}"
    elif [[ "$value" == \'*\' ]]; then
      value="${value#\'}"
      value="${value%\'}"
    fi

    export "$key=$value"
  done < "$env_file"
}

# ---------------------------------------------------------------------------
# Default values — single source of truth for preflight, update review,
# and Stage 2/3 config review. The DO NOT CHANGE section is at the bottom.
# ---------------------------------------------------------------------------
_DEFAULTS=(
  "SEAFILE_SERVER_PROTOCOL=https"
  "STORAGE_TYPE=nfs"
  "SEAFILE_VOLUME=/mnt/seafile_nfs"
  "DB_INTERNAL=true"
  "DB_INTERNAL_VOLUME=/opt/seafile-db"
  "DB_INTERNAL_IMAGE=mariadb:10.11"
  "OFFICE_SUITE=collabora"
  "ONLYOFFICE_PORT=6233"
  "ONLYOFFICE_VOLUME=/opt/onlyoffice"
  "CLAMAV_ENABLED=false"
  "SMTP_ENABLED=true"
  "SMTP_PORT=465"
  "SMTP_USE_TLS=true"
  "SMTP_FROM=noreply@yourdomain.com"
  "DEFAULT_USER_QUOTA_GB=0"
  "MAX_UPLOAD_SIZE_MB=0"
  "TRASH_CLEAN_AFTER_DAYS=30"
  "FORCE_2FA=false"
  "ENABLE_GUEST=false"
  "SEAFDAV_ENABLED=false"
  "LDAP_ENABLED=false"
  "LDAP_LOGIN_ATTR=mail"
  "GC_ENABLED=true"
  "GC_SCHEDULE=0 3 * * 0"
  "GC_REMOVE_DELETED=true"
  "GC_DRY_RUN=false"
  "BACKUP_ENABLED=false"
  "BACKUP_SCHEDULE=0 2 * * *"
  "THUMBNAIL_PATH=/opt/seafile-thumbnails"
  "METADATA_PATH=/opt/seafile-metadata"
  "SEADOC_DATA_PATH=/opt/seadoc-data"
  "CADDY_PORT=7080"
  "CADDY_HTTPS_PORT=7443"
  "TIME_ZONE=America/New_York"
  "SEAFILE_LOG_TO_STDOUT=true"
  "MD_FILE_COUNT_LIMIT=100000"
  "NOTIFICATION_SERVER_LOG_LEVEL=info"
  "SEAFILE_MYSQL_DB_USER=seafile"
  "SEAFILE_MYSQL_DB_PORT=3306"
  "PORTAINER_MANAGED=false"
  "PORTAINER_STACK_WEBHOOK="
  "CONFIG_GIT_PORT=9418"
  "CONFIG_HISTORY_ENABLED=true"
  "CONFIG_HISTORY_RETAIN=50"
  "PROXY_TYPE=nginx"
  "GITOPS_INTEGRATION=false"
  "GITOPS_BRANCH=main"
  "GITOPS_WEBHOOK_PORT=9002"
  "GITOPS_CLONE_PATH=/opt/seafile-gitops"
  "TRAEFIK_ENABLED=false"
  "TRAEFIK_ENTRYPOINT=websecure"
  "TRAEFIK_CERTRESOLVER=letsencrypt"
  "ISCSI_FILESYSTEM=ext4"
  "MULTI_BACKEND_ENABLED=false"
  "STORAGE_CLASS_MAPPING_POLICY=USER_SELECT"
  # DO NOT CHANGE values
  "SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db"
  "SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db"
  "SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=seahub_db"
  "REDIS_PORT=6379"
  "SITE_ROOT=/"
  "NON_ROOT=false"
  "CADDY_CONFIG_PATH=/opt/seafile-caddy"
  "SEAFILE_NETWORK=seafile-net"
  "ENABLE_GO_FILESERVER=true"
  "ENABLE_SEADOC=true"
  "ENABLE_NOTIFICATION_SERVER=true"
  "ENABLE_METADATA_SERVER=true"
  "ENABLE_THUMBNAIL_SERVER=true"
  "ENABLE_SEAFILE_AI=false"
  "ENABLE_FACE_RECOGNITION=false"
)

# DO NOT CHANGE variable names (subset of _DEFAULTS)
_DNC_VARS=(
  SEAFILE_MYSQL_DB_CCNET_DB_NAME
  SEAFILE_MYSQL_DB_SEAFILE_DB_NAME
  SEAFILE_MYSQL_DB_SEAHUB_DB_NAME
  REDIS_PORT
  SITE_ROOT
  NON_ROOT
  CADDY_CONFIG_PATH
  SEAFILE_NETWORK
  ENABLE_GO_FILESERVER
  ENABLE_SEADOC
  ENABLE_NOTIFICATION_SERVER
  ENABLE_METADATA_SERVER
  ENABLE_THUMBNAIL_SERVER
  ENABLE_SEAFILE_AI
  ENABLE_FACE_RECOGNITION
)

# ---------------------------------------------------------------------------
# DNC risk descriptions
# ---------------------------------------------------------------------------
_dnc_risk() {
  case "$1" in
    SEAFILE_MYSQL_DB_*_DB_NAME) echo "Database name change breaks all existing tables on redeploy." ;;
    REDIS_PORT)                 echo "Internal services hardcode this port — changing breaks caching." ;;
    SITE_ROOT)                  echo "Seafile expects to be served at / — changing breaks routing." ;;
    NON_ROOT)                   echo "Container runs as root by design — changing breaks file permissions." ;;
    CADDY_CONFIG_PATH)          echo "Internal config mount — Caddy will not start if this differs." ;;
    SEAFILE_NETWORK)            echo "All containers must share the same network name — changing breaks service discovery." ;;
    ENABLE_GO_FILESERVER)       echo "Required for large file uploads and transfers." ;;
    ENABLE_SEADOC)              echo "Required for collaborative document editing." ;;
    ENABLE_NOTIFICATION_SERVER) echo "Required for real-time notifications and collaborative editing." ;;
    ENABLE_METADATA_SERVER)     echo "Required for Extended Properties and metadata features." ;;
    ENABLE_THUMBNAIL_SERVER)    echo "Required for image and video thumbnails." ;;
    ENABLE_SEAFILE_AI)          echo "AI features require a separate licence — leave false unless licensed." ;;
    ENABLE_FACE_RECOGNITION)    echo "Requires AI licence and additional setup — leave false unless ready." ;;
    *)                          echo "Internal wiring — changing may break container connectivity." ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: get default value for a variable
# ---------------------------------------------------------------------------
_get_default() {
  local var="$1"
  for entry in "${_DEFAULTS[@]}"; do
    if [[ "${entry%%=*}" == "$var" ]]; then
      echo "${entry#*=}"
      return
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Helper: is this a DO NOT CHANGE variable?
# ---------------------------------------------------------------------------
_is_dnc() {
  local var="$1"
  for d in "${_DNC_VARS[@]}"; do
    [[ "$d" == "$var" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Helper: mask secrets for display
# ---------------------------------------------------------------------------
_mask_secret() {
  [[ -n "${1:-}" ]] && echo "[set]" || echo "[blank]"
}

# ---------------------------------------------------------------------------
# Helper: smart value display for one variable
# ---------------------------------------------------------------------------
_pfv() {
  local var="$1"
  local is_secret="${2:-false}"
  local actual="${!var:-}"
  local default
  default=$(_get_default "$var")

  if _is_dnc "$var" && [[ "$actual" != "$default" ]]; then
    printf "${YELLOW}%s${NC}  ${YELLOW}⚠ NOT RECOMMENDED${NC}" \
      "${actual:-[blank]}"
    return
  fi

  if [[ "$actual" == "$default" ]] || [[ -z "$actual" && -z "$default" ]]; then
    printf "${DIM}default${NC}"
    return
  fi

  if [[ "$is_secret" == "true" ]]; then
    echo "[set]"
  else
    echo "$actual"
  fi
}

# ---------------------------------------------------------------------------
# Normalize .env — ensure all expected keys from the template exist
# ---------------------------------------------------------------------------
# Merges missing keys from the canonical template. Existing values and
# custom user keys are never modified or removed.
_normalize_env() {
  local env_file="$1"

  local template_content
  template_content=$(cat << 'ENVNORMALIZE'
{{ENV_TEMPLATE}}
ENVNORMALIZE
)

  local key line _added=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    [[ -z "$key" ]] && continue
    if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
      echo "$line" >> "$env_file"
      ((_added++)) || true
    fi
  done <<< "$template_content"

  if [[ $_added -gt 0 ]]; then
    echo -e "  ${DIM}Added $_added missing key(s) to .env from template defaults.${NC}"
  fi
}

# ---------------------------------------------------------------------------
# Write a secret value into .env — handles both blank and missing keys
# ---------------------------------------------------------------------------
_set_env_secret() {
  local key="$1"
  local value="$2"
  local file="$3"
  python3 - "$key" "$value" "$file" << 'PYEOF'
import sys, re
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
new_content = re.sub(
    r'^(' + re.escape(key) + r'=)\s*$',
    r'\g<1>' + value,
    content,
    flags=re.MULTILINE
)
if new_content == content:
    if not re.search(r'^' + re.escape(key) + r'=', content, re.MULTILINE):
        new_content = content.rstrip('\n') + '\n' + key + '=' + value + '\n'
open(path, 'w').write(new_content)
PYEOF
}

# ---------------------------------------------------------------------------
# Compute COMPOSE_PROFILES from .env
# ---------------------------------------------------------------------------
_compute_profiles() {
  local _profiles=()
  case "${OFFICE_SUITE:-collabora}" in
    onlyoffice) _profiles+=(onlyoffice) ;;
    none)       ;;  # No office suite container
    *)          _profiles+=(collabora)  ;;
  esac
  [[ "${CLAMAV_ENABLED:-false}" == "true" ]]  && _profiles+=(clamav)
  [[ "${DB_INTERNAL:-true}"    == "true" ]]   && _profiles+=(internal-db)
  export COMPOSE_PROFILES
  COMPOSE_PROFILES=$(IFS=','; echo "${_profiles[*]}")
}

# ---------------------------------------------------------------------------
# Interactive phase-toggle menu
# ---------------------------------------------------------------------------
# Expects _PHASES and _SELECTED arrays to be set by the calling script.

_show_phase_menu() {
  local title="${1:-Setup}"
  local i _num
  echo ""
  echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}   ${title}${NC}"
  echo -e "${BOLD}${CYAN}  ════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  The following steps will run. Enter step numbers to"
  echo "  toggle (e.g. 1 3), Enter to run, or q to quit."
  echo ""
  local -a _OPT_COLORS=("$GREEN" "$CYAN" "$YELLOW" "$PURPLE" "$BOLD")
  for i in "${!_PHASES[@]}"; do
    _num=$(( i + 1 ))
    local _c="${_OPT_COLORS[$(( i % ${#_OPT_COLORS[@]} ))]}"
    if [[ "${_SELECTED[$i]}" == "true" ]]; then
      echo -e "    [${GREEN}✓${NC}] ${_c}$(printf '%2d' $_num)${NC}.  ${_PHASES[$i]}"
    else
      echo -e "    [ ] ${DIM}$(printf '%2d' $_num).  ${_PHASES[$i]}${NC}"
    fi
  done
  echo ""
  echo "  Press [Enter] to run, enter numbers to toggle, or q to quit."
  echo ""
}

_run_phase_menu() {
  local title="${1:-Setup}"
  local _input _idx _any
  while true; do
    _show_phase_menu "$title"
    read -r -p "  > " _input
    case "$_input" in
      q|Q)
        echo ""
        echo "  Run me again if you change your mind."
        echo ""
        exit 0
        ;;
      "")
        _any=false
        for _s in "${_SELECTED[@]}"; do
          if [[ "$_s" == "true" ]]; then _any=true; break; fi
        done
        if [[ "$_any" == "false" ]]; then
          echo ""
          echo "  Nothing selected. Run me again if you change your mind."
          echo ""
          exit 0
        fi
        echo ""
        break
        ;;
      *)
        # Parse multiple space-separated numbers
        local _toggled=false
        for _num in $_input; do
          if [[ "$_num" =~ ^[0-9]+$ ]]; then
            _idx=$(( _num - 1 ))
            if [[ $_idx -ge 0 && $_idx -lt ${#_PHASES[@]} ]]; then
              if [[ "${_SELECTED[$_idx]}" == "true" ]]; then
                _SELECTED[$_idx]="false"
              else
                _SELECTED[$_idx]="true"
              fi
              _toggled=true
            fi
          fi
        done
        if [[ "$_toggled" != "true" ]]; then
          echo ""
          echo "  Enter a valid step number, or press Enter to run."
        fi
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Collect missing required fields (populates _MISSING array)
# ---------------------------------------------------------------------------
_collect_missing() {
  local env_file="${1:-/opt/seafile/.env}"
  _load_env "$env_file"
  _MISSING=()

  [[ -z "${SEAFILE_SERVER_HOSTNAME:-}" ]] && _MISSING+=(SEAFILE_SERVER_HOSTNAME)
  [[ -z "${INIT_SEAFILE_ADMIN_EMAIL:-}" ]] && _MISSING+=(INIT_SEAFILE_ADMIN_EMAIL)

  case "${STORAGE_TYPE:-nfs}" in
    nfs)
      [[ -z "${NFS_SERVER:-}" ]] && _MISSING+=(NFS_SERVER)
      [[ -z "${NFS_EXPORT:-}" ]] && _MISSING+=(NFS_EXPORT)
      ;;
    smb)
      [[ -z "${SMB_SERVER:-}" ]]   && _MISSING+=(SMB_SERVER)
      [[ -z "${SMB_SHARE:-}" ]]    && _MISSING+=(SMB_SHARE)
      [[ -z "${SMB_USERNAME:-}" ]] && _MISSING+=(SMB_USERNAME)
      [[ -z "${SMB_PASSWORD:-}" ]] && _MISSING+=(SMB_PASSWORD)
      ;;
    glusterfs)
      [[ -z "${GLUSTER_SERVER:-}" ]] && _MISSING+=(GLUSTER_SERVER)
      [[ -z "${GLUSTER_VOLUME:-}" ]] && _MISSING+=(GLUSTER_VOLUME)
      ;;
    iscsi)
      [[ -z "${ISCSI_PORTAL:-}" ]]     && _MISSING+=(ISCSI_PORTAL)
      [[ -z "${ISCSI_TARGET_IQN:-}" ]] && _MISSING+=(ISCSI_TARGET_IQN)
      ;;
  esac

  if [[ "${DB_INTERNAL:-true}" == "false" ]]; then
    [[ -z "${SEAFILE_MYSQL_DB_HOST:-}" ]]               && _MISSING+=(SEAFILE_MYSQL_DB_HOST)
    [[ -z "${SEAFILE_MYSQL_DB_PASSWORD:-}" ]]            && _MISSING+=(SEAFILE_MYSQL_DB_PASSWORD)
    [[ -z "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" ]]     && _MISSING+=(INIT_SEAFILE_MYSQL_ROOT_PASSWORD)
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Collect DNC vars that differ from expected (populates _DNC_CHANGED)
# ---------------------------------------------------------------------------
_collect_dnc_changed() {
  local env_file="${1:-/opt/seafile/.env}"
  _load_env "$env_file"
  _DNC_CHANGED=()
  for var in "${_DNC_VARS[@]}"; do
    local actual="${!var:-}"
    local expected
    expected=$(_get_default "$var")
    if [[ "$actual" != "$expected" ]]; then
      _DNC_CHANGED+=("$var")
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Print full configuration review table
# ---------------------------------------------------------------------------
_print_config_review() {
  local env_file="${1:-/opt/seafile/.env}"
  _load_env "$env_file"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Configuration Review${NC}"
  echo -e "  ${DIM}Unchanged vars show ${NC}${DIM}default${NC}${DIM}. Secrets show [set] or [blank].${NC}"
  echo -e "  ${DIM}${YELLOW}⚠ NOT RECOMMENDED${NC}${DIM} = DO NOT CHANGE variable modified from expected.${NC}"
  echo ""

  echo -e "  ${BOLD}Required — Server${NC}"
  printf "    %-42s %b\n" "SEAFILE_SERVER_HOSTNAME"  "${SEAFILE_SERVER_HOSTNAME:-[blank]}"
  printf "    %-42s %b\n" "SEAFILE_SERVER_PROTOCOL"  "$(_pfv SEAFILE_SERVER_PROTOCOL)"
  echo ""

  echo -e "  ${BOLD}Required — Admin Account${NC}"
  printf "    %-42s %b\n" "INIT_SEAFILE_ADMIN_EMAIL"    "${INIT_SEAFILE_ADMIN_EMAIL:-[blank]}"
  printf "    %-42s %b\n" "INIT_SEAFILE_ADMIN_PASSWORD" "$(_mask_secret "${INIT_SEAFILE_ADMIN_PASSWORD:-}")"
  echo ""

  echo -e "  ${BOLD}Storage  (STORAGE_TYPE=$(_pfv STORAGE_TYPE))${NC}"
  printf "    %-42s %b\n" "SEAFILE_VOLUME" "$(_pfv SEAFILE_VOLUME)"
  case "${STORAGE_TYPE:-nfs}" in
    nfs)
      printf "    %-42s %b\n" "NFS_SERVER" "${NFS_SERVER:-[blank]}"
      printf "    %-42s %b\n" "NFS_EXPORT" "${NFS_EXPORT:-[blank]}"
      ;;
    smb)
      printf "    %-42s %b\n" "SMB_SERVER"   "${SMB_SERVER:-[blank]}"
      printf "    %-42s %b\n" "SMB_SHARE"    "${SMB_SHARE:-[blank]}"
      printf "    %-42s %b\n" "SMB_USERNAME" "${SMB_USERNAME:-[blank]}"
      printf "    %-42s %b\n" "SMB_PASSWORD" "$(_mask_secret "${SMB_PASSWORD:-}")"
      printf "    %-42s %b\n" "SMB_DOMAIN"   "${SMB_DOMAIN:-(none)}"
      ;;
    glusterfs)
      printf "    %-42s %b\n" "GLUSTER_SERVER" "${GLUSTER_SERVER:-[blank]}"
      printf "    %-42s %b\n" "GLUSTER_VOLUME" "${GLUSTER_VOLUME:-[blank]}"
      ;;
    iscsi)
      printf "    %-42s %b\n" "ISCSI_PORTAL"       "${ISCSI_PORTAL:-[blank]}"
      printf "    %-42s %b\n" "ISCSI_TARGET_IQN"    "${ISCSI_TARGET_IQN:-[blank]}"
      printf "    %-42s %b\n" "ISCSI_FILESYSTEM"    "$(_pfv ISCSI_FILESYSTEM)"
      printf "    %-42s %b\n" "ISCSI_CHAP_USERNAME" "${ISCSI_CHAP_USERNAME:-(none)}"
      printf "    %-42s %b\n" "ISCSI_CHAP_PASSWORD" "$(_mask_secret "${ISCSI_CHAP_PASSWORD:-}")"
      ;;
    local) printf "    %-42s %b\n" "(local disk)" "No network credentials needed." ;;
  esac
  echo ""

  echo -e "  ${BOLD}Database  (DB_INTERNAL=$(_pfv DB_INTERNAL))${NC}"
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    printf "    %-42s %b\n" "DB_INTERNAL_VOLUME"           "$(_pfv DB_INTERNAL_VOLUME)"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PASSWORD"    "$(_mask_secret "${SEAFILE_MYSQL_DB_PASSWORD:-}")"
  else
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_HOST"     "${SEAFILE_MYSQL_DB_HOST:-[blank]}"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PASSWORD" "$(_mask_secret "${SEAFILE_MYSQL_DB_PASSWORD:-}")"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_USER"     "$(_pfv SEAFILE_MYSQL_DB_USER)"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PORT"     "$(_pfv SEAFILE_MYSQL_DB_PORT)"
  fi
  echo ""

  echo -e "  ${BOLD}Auth${NC}"
  printf "    %-42s %b\n" "JWT_PRIVATE_KEY" "$(_mask_secret "${JWT_PRIVATE_KEY:-}")"
  printf "    %-42s %b\n" "REDIS_PASSWORD"  "$(_mask_secret "${REDIS_PASSWORD:-}")"
  printf "    %-42s %b\n" "REDIS_PORT"      "$(_pfv REDIS_PORT)"
  echo ""

  echo -e "  ${BOLD}Office Suite  (OFFICE_SUITE=$(_pfv OFFICE_SUITE))${NC}"
  if [[ "${OFFICE_SUITE:-collabora}" == "onlyoffice" ]]; then
    printf "    %-42s %b\n" "ONLYOFFICE_JWT_SECRET" "$(_mask_secret "${ONLYOFFICE_JWT_SECRET:-}")"
    printf "    %-42s %b\n" "ONLYOFFICE_PORT"       "$(_pfv ONLYOFFICE_PORT)"
  else
    printf "    %-42s %b\n" "COLLABORA_ADMIN_USER"     "${COLLABORA_ADMIN_USER:-[blank]}"
    printf "    %-42s %b\n" "COLLABORA_ADMIN_PASSWORD" "$(_mask_secret "${COLLABORA_ADMIN_PASSWORD:-}")"
  fi
  echo ""

  echo -e "  ${BOLD}Email / SMTP  (SMTP_ENABLED=$(_pfv SMTP_ENABLED))${NC}"
  if [[ "${SMTP_ENABLED:-true}" == "true" ]]; then
    printf "    %-42s %b\n" "SMTP_HOST"     "${SMTP_HOST:-[blank]}"
    printf "    %-42s %b\n" "SMTP_PORT"     "$(_pfv SMTP_PORT)"
    printf "    %-42s %b\n" "SMTP_USER"     "${SMTP_USER:-[blank]}"
    printf "    %-42s %b\n" "SMTP_PASSWORD" "$(_mask_secret "${SMTP_PASSWORD:-}")"
  else
    echo -e "    ${DIM}(disabled)${NC}"
  fi
  echo ""

  echo -e "  ${BOLD}Optional Features${NC}"
  printf "    %-42s %b\n" "CLAMAV_ENABLED"        "$(_pfv CLAMAV_ENABLED)"
  printf "    %-42s %b\n" "SEAFDAV_ENABLED"       "$(_pfv SEAFDAV_ENABLED)"
  printf "    %-42s %b\n" "LDAP_ENABLED"          "$(_pfv LDAP_ENABLED)"
  printf "    %-42s %b\n" "BACKUP_ENABLED"        "$(_pfv BACKUP_ENABLED)"
  printf "    %-42s %b\n" "GC_ENABLED"            "$(_pfv GC_ENABLED)"
  printf "    %-42s %b\n" "DEFAULT_USER_QUOTA_GB" "$(_pfv DEFAULT_USER_QUOTA_GB)"
  printf "    %-42s %b\n" "FORCE_2FA"             "$(_pfv FORCE_2FA)"
  printf "    %-42s %b\n" "ENABLE_GUEST"          "$(_pfv ENABLE_GUEST)"
  echo ""

  echo -e "  ${BOLD}Deployment${NC}"
  printf "    %-42s %b\n" "PROXY_TYPE"        "$(_pfv PROXY_TYPE)"
  printf "    %-42s %b\n" "CADDY_PORT"        "$(_pfv CADDY_PORT)"
  printf "    %-42s %b\n" "PORTAINER_MANAGED" "$(_pfv PORTAINER_MANAGED)"
  printf "    %-42s %b\n" "TIME_ZONE"         "$(_pfv TIME_ZONE)"
  echo ""

  # DNC section — only show if any differ
  _collect_dnc_changed "$env_file"
  if [[ ${#_DNC_CHANGED[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Internal Wiring${NC}  ${DIM}(DO NOT CHANGE section)${NC}"
    for var in "${_DNC_VARS[@]}"; do
      local actual="${!var:-}"
      local expected
      expected=$(_get_default "$var")
      if [[ "$actual" != "$expected" ]]; then
        printf "    %-42s " "$var"
        printf "${YELLOW}%s${NC}  ${YELLOW}⚠ NOT RECOMMENDED${NC}\n" "${actual:-[blank]}"
      fi
    done
    echo ""
  fi

  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# Config history: commit current state to local git repo
# ---------------------------------------------------------------------------
HISTORY_DIR="/opt/seafile/.config-history"

_config_history_commit() {
  local msg="${1:-Config updated}"
  [[ "${CONFIG_HISTORY_ENABLED:-true}" != "true" ]] && return 0
  [[ ! -d "$HISTORY_DIR/.git" ]] && return 0

  # Copy tracked files into the repo
  cp /opt/seafile/.env "$HISTORY_DIR/.env" 2>/dev/null || true
  [[ -f /opt/seafile/docker-compose.yml ]] && \
    cp /opt/seafile/docker-compose.yml "$HISTORY_DIR/docker-compose.yml" 2>/dev/null || true
  [[ -f /opt/seafile-config-fixes.sh ]] && \
    cp /opt/seafile-config-fixes.sh "$HISTORY_DIR/seafile-config-fixes.sh" 2>/dev/null || true
  [[ -f /opt/update.sh ]] && \
    cp /opt/update.sh "$HISTORY_DIR/update.sh" 2>/dev/null || true

  # Commit if anything changed
  cd "$HISTORY_DIR" || return 0
  git add -A 2>/dev/null || return 0
  git diff --cached --quiet 2>/dev/null && return 0
  git commit -m "$msg" --quiet 2>/dev/null || true

  # Update server info for dumb HTTP cloning (Portainer)
  git update-server-info 2>/dev/null || true
}

_config_history_init() {
  [[ "${CONFIG_HISTORY_ENABLED:-true}" != "true" ]] && return 0
  if [[ ! -d "$HISTORY_DIR/.git" ]]; then
    mkdir -p "$HISTORY_DIR"
    cd "$HISTORY_DIR"
    git init --quiet 2>/dev/null
    git config user.email "seafile-deploy@localhost"
    git config user.name "seafile-deploy"
    # Enable dumb HTTP protocol support
    git update-server-info 2>/dev/null || true
  fi
  _config_history_commit "Initial deployment"
}

# ---------------------------------------------------------------------------
# Enable Extended Properties on all libraries via Seafile API
# Uses admin credentials from .env — suitable for setup and recovery scripts.
# ---------------------------------------------------------------------------
_enable_metadata_all() {
  local admin_email="${INIT_SEAFILE_ADMIN_EMAIL:-}"
  local admin_pass="${INIT_SEAFILE_ADMIN_PASSWORD:-}"
  local caddy_port="${CADDY_PORT:-7080}"
  local host_hdr="${SEAFILE_SERVER_HOSTNAME:-localhost}"
  local api_base="http://localhost:${caddy_port}"

  [[ -z "$admin_email" || -z "$admin_pass" ]] && return 0

  info "Enabling Extended Properties on all libraries..."

  # Get auth token
  local token_response
  token_response=$(curl -sf -H "Host: ${host_hdr}" \
    -d "username=${admin_email}&password=${admin_pass}" \
    "${api_base}/api2/auth-token/" 2>/dev/null || true)

  if [[ -z "$token_response" ]]; then
    warn "Could not authenticate to Seafile API — Extended Properties not auto-enabled."
    warn "Enable manually: seafile metadata --enable-all"
    return 0
  fi

  local token
  token=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
  [[ -z "$token" ]] && { warn "API auth failed — run: seafile metadata --enable-all"; return 0; }

  # List repos and enable metadata
  local repos_json
  repos_json=$(curl -sf -H "Host: ${host_hdr}" \
    -H "Authorization: Token ${token}" \
    "${api_base}/api/v2.1/repos/?type=mine" 2>/dev/null || true)

  [[ -z "$repos_json" ]] && { info "No libraries found (fresh install — none exist yet)."; return 0; }

  local enabled=0
  echo "$repos_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
repos = data.get('repos', data) if isinstance(data, dict) else data
for r in repos:
    print(r['id'])
" 2>/dev/null | while IFS= read -r repo_id; do
    [[ -z "$repo_id" ]] && continue
    curl -sf -X PUT -H "Host: ${host_hdr}" \
      -H "Authorization: Token ${token}" \
      -H "Content-Type: application/json" \
      -d '{"enabled": true}' \
      "${api_base}/api/v2.1/repos/${repo_id}/metadata/" >/dev/null 2>&1 || true
    ((enabled++)) 2>/dev/null || true
  done

  info "Extended Properties enabled on all existing libraries."
  info "New libraries will need Extended Properties enabled individually or via: seafile metadata --enable-all"
}

# ---------------------------------------------------------------------------
# Record a generated secret to the secrets reference file.
# This file is append-only, never read by scripts, and exists purely for
# human troubleshooting. Backed up to network share by env-sync.
# ---------------------------------------------------------------------------
SECRETS_FILE="/opt/seafile/.secrets"

_record_secret() {
  local key="$1"
  local value="$2"
  local secrets_file="${3:-$SECRETS_FILE}"

  # Create file with header if it doesn't exist
  if [[ ! -f "$secrets_file" ]]; then
    cat > "$secrets_file" << 'SECHDR'
# ═══════════════════════════════════════════════════════════════════════════
# Seafile Deploy — Generated Secrets Reference
# ═══════════════════════════════════════════════════════════════════════════
# This file records every auto-generated secret for troubleshooting.
# It is NOT read by any script or container — it is purely a human reference.
#
# If a secret is rotated, both the old and new values are kept here with
# timestamps so you can trace credential history.
#
# This file has chmod 600 (root-only). Keep it secure.
# ═══════════════════════════════════════════════════════════════════════════
SECHDR
    chmod 600 "$secrets_file"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S')  ${key}=${value}" >> "$secrets_file"
}

# ---------------------------------------------------------------------------
# Import database dumps — shared by recovery-finalize and migration.
# Looks for .sql.gz or .sql files in the given directory matching each
# Seafile database name. Supports both exact names (ccnet_db.sql.gz)
# and timestamped names (ccnet_db_20260313_010000.sql.gz).
# ---------------------------------------------------------------------------
_import_db_dumps() {
  local dump_dir="$1"
  local root_pass="$2"
  local db_method="${3:-internal}"  # "internal" = docker exec, "external" = mysql client

  local _db_user="${SEAFILE_MYSQL_DB_USER:-seafile}"
  local _db_host="${SEAFILE_MYSQL_DB_HOST:-seafile-db}"
  local _db_port="${SEAFILE_MYSQL_DB_PORT:-3306}"

  for db in \
      "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
      "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
      "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

    # Find the dump file — try timestamped first (newest), then exact name
    local dump_file=""
    dump_file=$(ls -t "${dump_dir}/${db}_"*.sql.gz 2>/dev/null | head -1 || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls -t "${dump_dir}/${db}_"*.sql 2>/dev/null | head -1 || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls "${dump_dir}/${db}.sql.gz" 2>/dev/null || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls "${dump_dir}/${db}.sql" 2>/dev/null || true)

    if [[ -z "$dump_file" ]]; then
      warn "  No dump found for ${db} in ${dump_dir} — skipping."
      continue
    fi

    info "  Importing ${db} from $(basename "$dump_file")..."

    # Ensure target database exists
    if [[ "$db_method" == "internal" ]]; then
      docker exec seafile-db mysql -u root -p"${root_pass}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    else
      mysql -h "$_db_host" -P "$_db_port" -u root -p"${root_pass}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    fi

    # Import — handle both .sql.gz and .sql
    local _import_ok=false
    if [[ "$dump_file" == *.gz ]]; then
      if [[ "$db_method" == "internal" ]]; then
        gunzip -c "$dump_file" | docker exec -i seafile-db \
          mysql -u root -p"${root_pass}" "$db" 2>/dev/null && _import_ok=true
      else
        gunzip -c "$dump_file" | mysql -h "$_db_host" -P "$_db_port" \
          -u root -p"${root_pass}" "$db" 2>/dev/null && _import_ok=true
      fi
    else
      if [[ "$db_method" == "internal" ]]; then
        docker exec -i seafile-db mysql -u root -p"${root_pass}" "$db" \
          < "$dump_file" 2>/dev/null && _import_ok=true
      else
        mysql -h "$_db_host" -P "$_db_port" -u root -p"${root_pass}" "$db" \
          < "$dump_file" 2>/dev/null && _import_ok=true
      fi
    fi

    if [[ "$_import_ok" == "true" ]]; then
      info "  ✓ ${db} imported successfully."
    else
      warn "  ✗ Failed to import ${db} — check dump file and database access."
    fi
  done
}
