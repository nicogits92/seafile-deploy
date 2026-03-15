#!/bin/bash
# =============================================================================
# seafile  —  management CLI for the nicogits92/seafile-deploy stack
# =============================================================================
# Deployed to: /usr/local/bin/seafile by install-dependencies.sh
# Usage:       seafile <command> [args]
#
# Commands:
#   status              Container health, storage mount, and disk usage
#   logs   [container]  Tail container logs (interactive picker if omitted)
#   restart [container] Restart one container or all (interactive picker)
#   shell  [container]  Open a shell inside a container (interactive picker)
#   update [--check]    Run update.sh (--check shows diff without applying)
#   config              Interactive configuration editor
#   config [section]    Jump to section: core, storage, smtp, ldap, office, features
#   config storage --status   Check storage migration progress
#   config storage --cutover  Finalize storage migration
#   config show [--secrets]   Display current configuration
#   config edit         Open .env in $EDITOR
#   fix                 Run seafile-config-fixes.sh
#   backup              Show storage backup status and trigger a manual sync check
#   version             Show running image tags vs .env values
#   gc   [--status|--dry-run]  Run GC or show status (respects .env flags)
#   gitops              Show GitOps listener status (if enabled)
#   help                Show this help
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
NC='\033[0m'

ok()      { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}  !${NC}  $1"; }
err()     { echo -e "${RED}  ✗${NC}  $1"; }
info()    { echo -e "  ${DIM}$1${NC}"; }
heading() { echo -e "\n${BOLD}${CYAN}  $1${NC}\n"; }
rule()    { echo -e "${DIM}  ────────────────────────────────────────────${NC}"; }

# --- Config ------------------------------------------------------------------
ENV_FILE="/opt/seafile/.env"
COMPOSE_FILE="/opt/seafile/docker-compose.yml"
UPDATE_SCRIPT="/opt/update.sh"
FIXES_SCRIPT="/opt/seafile-config-fixes.sh"

CORE_CONTAINERS=(
  seafile-caddy
  seafile-redis
  seafile
  seadoc
  notification-server
  thumbnail-server
  seafile-metadata
)

# --- Simple name mapping (user-facing ↔ Docker container name) ---------------
# Users type simple names; Docker needs the full container name.
declare -A _NAME_TO_CONTAINER=(
  [caddy]=seafile-caddy
  [redis]=seafile-redis
  [seafile]=seafile
  [seadoc]=seadoc
  [notifications]=notification-server
  [thumbnails]=thumbnail-server
  [metadata]=seafile-metadata
  [collabora]=seafile-collabora
  [onlyoffice]=seafile-onlyoffice
  [clamav]=seafile-clamav
  [db]=seafile-db
)
declare -A _CONTAINER_TO_NAME=(
  [seafile-caddy]=caddy
  [seafile-redis]=redis
  [seafile]=seafile
  [seadoc]=seadoc
  [notification-server]=notifications
  [thumbnail-server]=thumbnails
  [seafile-metadata]=metadata
  [seafile-collabora]=collabora
  [seafile-onlyoffice]=onlyoffice
  [seafile-clamav]=clamav
  [seafile-db]=db
)

# Resolve a user-provided name to a Docker container name.
# Accepts both simple names ("collabora") and full names ("seafile-collabora").
_resolve_container() {
  local input="$1"
  # Try simple name first
  if [[ -n "${_NAME_TO_CONTAINER[$input]:-}" ]]; then
    echo "${_NAME_TO_CONTAINER[$input]}"
    return 0
  fi
  # Try as a literal container name
  for _cn in "${CONTAINERS[@]}"; do
    [[ "$_cn" == "$input" ]] && echo "$_cn" && return 0
  done
  return 1
}

# Get the simple display name for a container
_display_name() {
  local cn="$1"
  echo "${_CONTAINER_TO_NAME[$cn]:-$cn}"
}

# --- Safe .env loader --------------------------------------------------------
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

# Source .env if available (for SEAFILE_VOLUME, GITOPS_INTEGRATION, OFFICE_SUITE, etc.)
[[ -f "$ENV_FILE" ]] && _load_env "$ENV_FILE" 2>/dev/null || true

# Build the active container list based on .env settings
CONTAINERS=("${CORE_CONTAINERS[@]}")
case "${OFFICE_SUITE:-collabora}" in
  onlyoffice) CONTAINERS+=(seafile-onlyoffice) ;;
  none)       ;;  # No office suite container
  *)          CONTAINERS+=(seafile-collabora)  ;;
esac
[[ "${CLAMAV_ENABLED:-false}" == "true" ]] && CONTAINERS+=(seafile-clamav)
[[ "${DB_INTERNAL:-true}"    == "true" ]] && CONTAINERS+=(seafile-db)

# --- Shared: interactive container picker ------------------------------------
pick_container() {
  local prompt="${1:-Select a container}"
  local include_all="${2:-false}"

  echo -e "\n  ${BOLD}${prompt}${NC}\n"
  local i=1
  for c in "${CONTAINERS[@]}"; do
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "not found")
    local colour="$NC"
    [[ "$status" == "running" ]] && colour="$GREEN"
    [[ "$status" == "exited"  ]] && colour="$RED"
    local _dname=$(_display_name "$c")
    printf "  ${BOLD}%2d${NC}  %-28s ${colour}%s${NC}\n" "$i" "$_dname" "$status"
    (( i++ ))
  done
  if [[ "$include_all" == "true" ]]; then
    printf "  ${BOLD}%2d${NC}  %-28s\n" "$i" "all containers"
  fi
  echo ""

  local max=$(( include_all == "true" ? ${#CONTAINERS[@]} + 1 : ${#CONTAINERS[@]} ))
  while true; do
    read -r -p "  Enter number (or 0 to cancel): " sel
    [[ "$sel" == "0" ]] && return 1
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= max )); then
      if [[ "$include_all" == "true" && "$sel" -eq "$max" ]]; then
        PICKED="all"
      else
        PICKED="${CONTAINERS[$((sel - 1))]}"
      fi
      return 0
    fi
    echo "  Please enter a number between 1 and $max."
  done
}

# --- Command: status ---------------------------------------------------------
cmd_status() {
  heading "Seafile Stack Status"

  # Container table
  printf "  ${BOLD}%-28s %-12s %-8s %s${NC}\n" "Container" "Status" "Uptime" "Image"
  rule
  for c in "${CONTAINERS[@]}"; do
    local status uptime image
    status=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "not found")
    uptime=$(docker inspect --format='{{.State.StartedAt}}' "$c" 2>/dev/null | \
             xargs -I{} bash -c 'echo $(( ($(date +%s) - $(date -d "{}" +%s)) / 60 ))m' 2>/dev/null || echo "-")
    image=$(docker inspect --format='{{.Config.Image}}' "$c" 2>/dev/null | sed 's|.*:||'  || echo "-")
    local colour="$NC"
    [[ "$status" == "running" ]] && colour="$GREEN"
    [[ "$status" == "exited"  ]] && colour="$RED"
    [[ "$status" == "not found" ]] && colour="$DIM"
    local _dname=$(_display_name "$c")
    printf "  %-28s ${colour}%-12s${NC} %-8s %s\n" "$_dname" "$status" "$uptime" "$image"
  done

  echo ""
  rule
  heading "Storage"

  local nfs_vol="${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
  local _stype="${STORAGE_TYPE:-nfs}"
  if [[ "${_stype,,}" == "local" ]] || mountpoint -q "$nfs_vol" 2>/dev/null; then
    local used avail
    used=$(df -h "$nfs_vol" 2>/dev/null | awk 'NR==2{print $3}')
    avail=$(df -h "$nfs_vol" 2>/dev/null | awk 'NR==2{print $4}')
    ok "${_stype} mounted at ${BOLD}${nfs_vol}${NC}  (used: ${used}  free: ${avail})"
  else
    err "Storage NOT mounted at $nfs_vol  (type: ${_stype})"
  fi

  for path_var in THUMBNAIL_PATH METADATA_PATH; do
    local path="${!path_var:-}"
    if [[ -n "$path" && -d "$path" ]]; then
      local size
      size=$(du -sh "$path" 2>/dev/null | cut -f1)
      ok "${path_var}: ${BOLD}${path}${NC}  ($size)"
    fi
  done

  # GC schedule summary
  if [[ "${GC_ENABLED:-true}" == "true" ]]; then
    echo ""
    rule
    heading "Garbage Collection"
    local gc_sched="${GC_SCHEDULE:-0 3 * * 0}"
    ok "GC enabled  — schedule: ${BOLD}${gc_sched}${NC}"
    if [ -f /etc/cron.d/seafile-gc ]; then
      echo -e "  ${DIM}  Log: /var/log/seafile-gc.log${NC}"
    else
      warn "GC cron not installed — run: seafile fix"
    fi
  fi

  echo ""
}


# --- Command: ping -----------------------------------------------------------
cmd_ping() {
  heading "Endpoint Health"

  # Ping via localhost:CADDY_PORT — all endpoints are routed through local Caddy
  # Pass Host header so Caddy matches the request when site address is a domain
  local base="http://localhost:${CADDY_PORT:-7080}"
  local host_hdr="${SEAFILE_SERVER_HOSTNAME:-localhost}"
  local all_ok=true

  _ping_check() {
    local label="$1" url="$2" expect="$3"
    local response http_code body
    response=$(curl -sk --max-time 8 -H "Host: ${host_hdr}" -w "\n%{http_code}" "$url" 2>/dev/null || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if echo "$body" | grep -qF "$expect"; then
      ok "${label}  ${DIM}(HTTP ${http_code})${NC}"
    else
      local preview=$(echo "$body" | head -1)
      err "${label}  ${DIM}(HTTP ${http_code} — expected: ${expect})${NC}"
      echo -e "    ${DIM}Response: ${preview:0:120}${NC}"
      all_ok=false
    fi
  }

  echo ""
  _ping_check "Notification server  " "${base}/notification/ping"     '"ret": "pong"'
  _ping_check "Thumbnail server     " "${base}/thumbnail-server/ping" "pong"
  # Office suite endpoint
  case "${OFFICE_SUITE:-collabora}" in
    onlyoffice)
      _ping_check "OnlyOffice (healthcheck)" "http://localhost:${ONLYOFFICE_PORT:-6233}/healthcheck" "true"
      ;;
    none)
      echo -e "  ${DIM}  Office suite:  not installed (OFFICE_SUITE=none)${NC}"
      echo -e "  ${DIM}  To add document editing later, run: seafile config office${NC}"
      ;;
    *)
      _ping_check "Collabora (discovery)   " "${base}/hosting/discovery" "</wopi-discovery>"
      ;;
  esac
  echo ""

  if [[ "$all_ok" == "true" ]]; then
    echo -e "  ${GREEN}${BOLD}  All endpoints responding.${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}  Some endpoints did not respond — check container logs.${NC}"
    echo -e "  ${DIM}  seafile logs notifications${NC}"
    echo -e "  ${DIM}  seafile logs thumbnails${NC}"
    case "${OFFICE_SUITE:-collabora}" in
      onlyoffice) echo -e "  ${DIM}  seafile logs onlyoffice${NC}" ;;
      none)       ;;
      *)          echo -e "  ${DIM}  seafile logs collabora${NC}"  ;;
    esac
  fi
  echo ""
}

# --- Command: logs -----------------------------------------------------------
cmd_logs() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    pick_container "Which container?" || return 0
    target="$PICKED"
  else
    target=$(_resolve_container "$target") || { err "Unknown container: $1"; return 1; }
  fi
  local _dname=$(_display_name "$target")
  echo -e "\n  ${DIM}Tailing logs for ${BOLD}${_dname}${NC}${DIM} — Ctrl+C to stop${NC}\n"
  docker logs --tail 50 -f "$target"
}

# --- Command: restart --------------------------------------------------------
cmd_restart() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    pick_container "Which container to restart?" "true" || return 0
    target="$PICKED"
  elif [[ "$target" != "all" ]]; then
    target=$(_resolve_container "$target") || { err "Unknown container: $1"; return 1; }
  fi
  if [[ "$target" == "all" ]]; then
    echo ""
    read -r -p "  Restart ALL containers? This will cause a brief outage. [y/N] " confirm
    [[ ! "$confirm" =~ ^[yY] ]] && { info "Cancelled."; return 0; }
    echo ""
    for c in "${CONTAINERS[@]}"; do
      local _dn=$(_display_name "$c")
      docker restart "$c" &>/dev/null && ok "Restarted ${_dn}" || warn "Could not restart ${_dn}"
    done
  else
    local _dn=$(_display_name "$target")
    docker restart "$target" &>/dev/null && ok "Restarted ${_dn}" || err "Failed to restart ${_dn}"
  fi
  echo ""
}

# --- Command: shell ----------------------------------------------------------
cmd_shell() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    pick_container "Which container?" || return 0
    target="$PICKED"
  else
    target=$(_resolve_container "$target") || { err "Unknown container: $1"; return 1; }
  fi
  local _dname=$(_display_name "$target")
  echo -e "\n  ${DIM}Opening shell in ${BOLD}${_dname}${NC}${DIM} — type 'exit' to return${NC}\n"
  # Try bash first, fall back to sh (Alpine containers use sh)
  docker exec -it "$target" bash 2>/dev/null || docker exec -it "$target" sh
}

# --- Command: update ---------------------------------------------------------
cmd_update() {
  local flag="${1:-}"
  if [[ "$flag" == "--check" ]]; then
    bash "$UPDATE_SCRIPT" --check
  else
    if [[ $EUID -ne 0 ]]; then
      sudo bash "$UPDATE_SCRIPT"
    else
      bash "$UPDATE_SCRIPT"
    fi
  fi
}

# =============================================================================
# CONFIG WIZARD — Section-based configuration editor
# =============================================================================

MIGRATION_CONF="/opt/seafile/.storage-migration.conf"

# --- Config Input Helpers ---
_cfg_rule() {
  echo -e "\n  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

_cfg_header() {
  echo -e "\n  ${BOLD}$1${NC}\n"
}

_cfg_input() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  local hint="${3:-}"
  local new_val
  
  if [[ -n "$hint" ]]; then
    echo -e "  ${BOLD}${prompt}${NC}  ${DIM}($hint)${NC}"
  else
    echo -e "  ${BOLD}${prompt}${NC}"
  fi
  
  if [[ -n "$current" ]]; then
    read -r -p "  [$current]: " new_val
    [[ -z "$new_val" ]] && new_val="$current"
  else
    read -r -p "  : " new_val
  fi
  
  eval "$var_name=\"\$new_val\""
}

_cfg_password() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-}"
  local new_val
  
  echo -e "  ${BOLD}${prompt}${NC}"
  
  if [[ -n "$current" ]]; then
    read -r -s -p "  [••••••••]: " new_val
  else
    read -r -s -p "  : " new_val
  fi
  echo ""
  
  [[ -z "$new_val" && -n "$current" ]] && new_val="$current"
  eval "$var_name=\"\$new_val\""
}

_cfg_select() {
  local var_name="$1"
  local prompt="$2"
  shift 2
  local options=("$@")
  local current="${!var_name:-}"
  local default_idx=1
  
  echo -e "  ${prompt}"
  echo ""
  
  local -a _OPT_COLORS=("$GREEN" "$CYAN" "$YELLOW" "$PURPLE" "$BOLD")
  local i=1
  for opt in "${options[@]}"; do
    local marker=""
    if [[ "$opt" == "$current" ]]; then
      marker=" ${DIM}(current)${NC}"
      default_idx=$i
    fi
    local _c="${_OPT_COLORS[$(( (i-1) % ${#_OPT_COLORS[@]} ))]}"
    echo -e "    ${_c}${BOLD}$i${NC}  $opt$marker"
    ((i++))
  done
  echo ""
  
  local sel
  while true; do
    read -r -p "  Select [1-${#options[@]}] (default: $default_idx): " sel
    [[ -z "$sel" ]] && sel=$default_idx
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#options[@]} )); then
      eval "$var_name=\"\${options[$((sel-1))]}\""
      return 0
    fi
    echo "  Please enter a number between 1 and ${#options[@]}."
  done
}

_cfg_yesno() {
  local var_name="$1"
  local prompt="$2"
  local current="${!var_name:-false}"
  local default_hint="Y/n"
  [[ "$current" != "true" ]] && default_hint="y/N"
  
  local response
  read -r -p "  ${prompt} [$default_hint]: " response
  
  case "${response,,}" in
    y|yes) eval "$var_name=true" ;;
    n|no)  eval "$var_name=false" ;;
    "")    ;; # Keep current
  esac
}

_cfg_save_var() {
  local var_name="$1"
  local value="${!var_name}"
  
  # Quote values containing spaces to prevent source/load issues
  if [[ "$value" == *" "* && "$value" != \"*\" ]]; then
    value="\"${value}\""
  fi
  
  if grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${var_name}=.*|${var_name}=${value}|" "$ENV_FILE"
  else
    echo "${var_name}=${value}" >> "$ENV_FILE"
  fi
}

_cfg_offer_update() {
  _cfg_rule
  echo -e "  ${BOLD}Apply changes now?${NC}"
  echo ""
  echo -e "    ${BOLD}1${NC}  Run ${CYAN}seafile update${NC} now"
  echo -e "    ${BOLD}2${NC}  Later ${DIM}(run seafile update manually)${NC}"
  echo ""
  
  local sel
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    echo ""
    cmd_update
  else
    echo ""
    ok "Changes saved but not yet applied."
    echo -e "  ${DIM}To apply your changes, run: ${BOLD}seafile update${NC}"
    echo ""
  fi
}

# --- Config Section: Core ---
_cfg_section_core() {
  _cfg_header "Core Configuration"
  
  local orig_hostname="$SEAFILE_SERVER_HOSTNAME"
  local orig_email="$INIT_SEAFILE_ADMIN_EMAIL"
  local orig_protocol="$SEAFILE_SERVER_PROTOCOL"
  
  _cfg_input SEAFILE_SERVER_HOSTNAME "Hostname" "e.g. seafile.example.com"
  _cfg_input INIT_SEAFILE_ADMIN_EMAIL "Admin email"
  _cfg_select SEAFILE_SERVER_PROTOCOL "Protocol:" "https" "http"
  
  _cfg_rule
  echo -e "  ${BOLD}Changes:${NC}"
  local changes=false
  [[ "$orig_hostname" != "$SEAFILE_SERVER_HOSTNAME" ]] && { echo -e "    SEAFILE_SERVER_HOSTNAME: $orig_hostname → ${YELLOW}$SEAFILE_SERVER_HOSTNAME${NC}"; changes=true; }
  [[ "$orig_email" != "$INIT_SEAFILE_ADMIN_EMAIL" ]] && { echo -e "    INIT_SEAFILE_ADMIN_EMAIL: $orig_email → ${YELLOW}$INIT_SEAFILE_ADMIN_EMAIL${NC}"; changes=true; }
  [[ "$orig_protocol" != "$SEAFILE_SERVER_PROTOCOL" ]] && { echo -e "    SEAFILE_SERVER_PROTOCOL: $orig_protocol → ${YELLOW}$SEAFILE_SERVER_PROTOCOL${NC}"; changes=true; }
  
  if [[ "$changes" == "false" ]]; then
    echo -e "    ${DIM}No changes${NC}"
    return
  fi
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    _cfg_save_var SEAFILE_SERVER_HOSTNAME
    _cfg_save_var INIT_SEAFILE_ADMIN_EMAIL
    _cfg_save_var SEAFILE_SERVER_PROTOCOL
    ok "Changes saved to $ENV_FILE"
    _cfg_offer_update
  else
    echo -e "  ${DIM}Changes discarded.${NC}"
  fi
}

# --- Config Section: SMTP ---
_cfg_section_smtp() {
  _cfg_header "Email / SMTP Configuration"
  
  local orig_enabled="$SMTP_ENABLED"
  local orig_host="$SMTP_HOST"
  local orig_port="$SMTP_PORT"
  local orig_user="$SMTP_USER"
  local orig_pass="$SMTP_PASSWORD"
  local orig_from="$SMTP_FROM"
  local orig_tls="$SMTP_USE_TLS"
  
  _cfg_yesno SMTP_ENABLED "Enable SMTP?"
  
  if [[ "$SMTP_ENABLED" == "true" ]]; then
    _cfg_input SMTP_HOST "SMTP server" "e.g. smtp.gmail.com"
    _cfg_input SMTP_PORT "SMTP port" "587 for TLS, 465 for SSL"
    _cfg_input SMTP_USER "SMTP username"
    _cfg_password SMTP_PASSWORD "SMTP password"
    _cfg_input SMTP_FROM "From address" "e.g. noreply@example.com"
    _cfg_yesno SMTP_USE_TLS "Use TLS?"
  fi
  
  _cfg_rule
  echo -e "  ${BOLD}Changes:${NC}"
  local changes=false
  [[ "$orig_enabled" != "$SMTP_ENABLED" ]] && { echo -e "    SMTP_ENABLED: $orig_enabled → ${YELLOW}$SMTP_ENABLED${NC}"; changes=true; }
  [[ "$orig_host" != "$SMTP_HOST" ]] && { echo -e "    SMTP_HOST: $orig_host → ${YELLOW}$SMTP_HOST${NC}"; changes=true; }
  [[ "$orig_port" != "$SMTP_PORT" ]] && { echo -e "    SMTP_PORT: $orig_port → ${YELLOW}$SMTP_PORT${NC}"; changes=true; }
  [[ "$orig_user" != "$SMTP_USER" ]] && { echo -e "    SMTP_USER: $orig_user → ${YELLOW}$SMTP_USER${NC}"; changes=true; }
  [[ "$orig_pass" != "$SMTP_PASSWORD" ]] && { echo -e "    SMTP_PASSWORD: ${DIM}[changed]${NC}"; changes=true; }
  [[ "$orig_from" != "$SMTP_FROM" ]] && { echo -e "    SMTP_FROM: $orig_from → ${YELLOW}$SMTP_FROM${NC}"; changes=true; }
  [[ "$orig_tls" != "$SMTP_USE_TLS" ]] && { echo -e "    SMTP_USE_TLS: $orig_tls → ${YELLOW}$SMTP_USE_TLS${NC}"; changes=true; }
  
  if [[ "$changes" == "false" ]]; then
    echo -e "    ${DIM}No changes${NC}"
    return
  fi
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    _cfg_save_var SMTP_ENABLED
    _cfg_save_var SMTP_HOST
    _cfg_save_var SMTP_PORT
    _cfg_save_var SMTP_USER
    _cfg_save_var SMTP_PASSWORD
    _cfg_save_var SMTP_FROM
    _cfg_save_var SMTP_USE_TLS
    ok "Changes saved to $ENV_FILE"
    _cfg_offer_update
  else
    echo -e "  ${DIM}Changes discarded.${NC}"
  fi
}

# --- Config Section: LDAP ---
_cfg_section_ldap() {
  _cfg_header "LDAP / Active Directory Configuration"
  
  local orig_enabled="$LDAP_ENABLED"
  local orig_url="$LDAP_URL"
  local orig_bind_dn="$LDAP_BIND_DN"
  local orig_bind_pass="$LDAP_BIND_PASSWORD"
  local orig_base_dn="$LDAP_BASE_DN"
  local orig_login_attr="$LDAP_LOGIN_ATTR"
  
  _cfg_yesno LDAP_ENABLED "Enable LDAP?"
  
  if [[ "$LDAP_ENABLED" == "true" ]]; then
    _cfg_input LDAP_URL "LDAP URL" "e.g. ldaps://ad.example.com"
    _cfg_input LDAP_BASE_DN "Base DN" "e.g. dc=example,dc=com"
    _cfg_input LDAP_BIND_DN "Bind DN" "service account DN"
    _cfg_password LDAP_BIND_PASSWORD "Bind password"
    _cfg_input LDAP_LOGIN_ATTR "Login attribute" "sAMAccountName for AD, uid for OpenLDAP"
  fi
  
  _cfg_rule
  echo -e "  ${BOLD}Changes:${NC}"
  local changes=false
  [[ "$orig_enabled" != "$LDAP_ENABLED" ]] && { echo -e "    LDAP_ENABLED: $orig_enabled → ${YELLOW}$LDAP_ENABLED${NC}"; changes=true; }
  [[ "$orig_url" != "$LDAP_URL" ]] && { echo -e "    LDAP_URL: $orig_url → ${YELLOW}$LDAP_URL${NC}"; changes=true; }
  [[ "$orig_base_dn" != "$LDAP_BASE_DN" ]] && { echo -e "    LDAP_BASE_DN: $orig_base_dn → ${YELLOW}$LDAP_BASE_DN${NC}"; changes=true; }
  [[ "$orig_bind_dn" != "$LDAP_BIND_DN" ]] && { echo -e "    LDAP_BIND_DN: $orig_bind_dn → ${YELLOW}$LDAP_BIND_DN${NC}"; changes=true; }
  [[ "$orig_bind_pass" != "$LDAP_BIND_PASSWORD" ]] && { echo -e "    LDAP_BIND_PASSWORD: ${DIM}[changed]${NC}"; changes=true; }
  [[ "$orig_login_attr" != "$LDAP_LOGIN_ATTR" ]] && { echo -e "    LDAP_LOGIN_ATTR: $orig_login_attr → ${YELLOW}$LDAP_LOGIN_ATTR${NC}"; changes=true; }
  
  if [[ "$changes" == "false" ]]; then
    echo -e "    ${DIM}No changes${NC}"
    return
  fi
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    _cfg_save_var LDAP_ENABLED
    _cfg_save_var LDAP_URL
    _cfg_save_var LDAP_BASE_DN
    _cfg_save_var LDAP_BIND_DN
    _cfg_save_var LDAP_BIND_PASSWORD
    _cfg_save_var LDAP_LOGIN_ATTR
    ok "Changes saved to $ENV_FILE"
    _cfg_offer_update
  else
    echo -e "  ${DIM}Changes discarded.${NC}"
  fi
}

# --- Config Section: Office ---
_cfg_section_office() {
  _cfg_header "Office Suite Configuration"
  
  local orig_suite="$OFFICE_SUITE"
  
  echo -e "  ${DIM}Current: ${OFFICE_SUITE:-collabora}${NC}"
  echo ""
  _cfg_select OFFICE_SUITE "Select office suite:" "collabora" "onlyoffice"
  
  if [[ "$orig_suite" != "$OFFICE_SUITE" ]]; then
    _cfg_rule
    echo -e "  ${BOLD}Change:${NC}"
    echo -e "    OFFICE_SUITE: $orig_suite → ${YELLOW}$OFFICE_SUITE${NC}"
    
    if [[ "$OFFICE_SUITE" == "onlyoffice" ]]; then
      echo ""
      echo -e "  ${YELLOW}Note:${NC} OnlyOffice requires at least 8GB RAM."
    fi
    
    echo ""
    echo -e "    ${BOLD}1${NC}  Save and switch"
    echo -e "    ${BOLD}2${NC}  Cancel"
    echo ""
    read -r -p "  Select [1-2]: " sel
    
    if [[ "$sel" == "1" ]]; then
      _cfg_save_var OFFICE_SUITE
      ok "Office suite will switch to $OFFICE_SUITE"
      _cfg_offer_update
    else
      echo -e "  ${DIM}Cancelled.${NC}"
    fi
  else
    echo -e "  ${DIM}No change.${NC}"
  fi
}

# --- Config Section: Features ---
_cfg_section_features() {
  _cfg_header "Optional Features"
  
  echo -e "  ${DIM}Enter numbers to toggle (e.g. 1 3), Enter to save and continue.${NC}"
  echo ""
  
  local features=(
    "CLAMAV_ENABLED:Antivirus scanning (ClamAV)"
    "SEAFDAV_ENABLED:WebDAV access"
    "GC_ENABLED:Garbage collection"
    "BACKUP_ENABLED:Automated backup"
    "ENABLE_GUEST:Guest accounts (external sharing)"
    "FORCE_2FA:Force two-factor authentication"
    "ENABLE_SIGNUP:Allow public registration"
    "SHARE_LINK_FORCE_USE_PASSWORD:Require passwords on share links"
    "AUDIT_ENABLED:Audit logging"
  )
  
  local orig_values=()
  for f in "${features[@]}"; do
    local var="${f%%:*}"
    orig_values+=("${!var:-false}")
  done

  _display_features() {
    echo ""
    local -a _OPT_COLORS=("$GREEN" "$CYAN" "$YELLOW" "$PURPLE" "$BOLD")
    local i=1
    for f in "${features[@]}"; do
      local var="${f%%:*}"
      local label="${f#*:}"
      local val="${!var:-false}"
      local mark="[ ]"
      [[ "$val" == "true" ]] && mark="[${GREEN}x${NC}]"
      local _c="${_OPT_COLORS[$(( (i-1) % ${#_OPT_COLORS[@]} ))]}"
      echo -e "    ${_c}${BOLD}$i${NC}  $mark $label"
      ((i++))
    done
    echo ""
  }

  _display_features
  
  while true; do
    read -r -p "  Toggle [1-${#features[@]}] or Enter to continue: " sel
    
    if [[ -z "$sel" ]]; then
      # Show review of changes
      echo ""
      echo -e "  ${BOLD}Current selections:${NC}"
      for f in "${features[@]}"; do
        local var="${f%%:*}"
        local label="${f#*:}"
        local val="${!var:-false}"
        if [[ "$val" == "true" ]]; then
          echo -e "    ${GREEN}✓${NC} $label"
        else
          echo -e "    ${DIM}✗ $label${NC}"
        fi
      done
      echo ""
      break
    fi

    # Parse multiple space-separated numbers
    local _toggled=false
    for num in $sel; do
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#features[@]} )); then
        local var="${features[$((num-1))]%%:*}"
        local current="${!var:-false}"
        if [[ "$current" == "true" ]]; then
          eval "$var=false"
        else
          eval "$var=true"
        fi
        _toggled=true
      fi
    done

    if [[ "$_toggled" == "true" ]]; then
      _display_features
    fi
  done
  
  _cfg_rule
  echo -e "  ${BOLD}Changes:${NC}"
  local changes=false
  local j=0
  for f in "${features[@]}"; do
    local var="${f%%:*}"
    local label="${f#*:}"
    local current="${!var:-false}"
    local orig="${orig_values[$j]}"
    if [[ "$orig" != "$current" ]]; then
      echo -e "    $var: $orig → ${YELLOW}$current${NC}"
      changes=true
    fi
    ((j++))
  done
  
  if [[ "$changes" == "false" ]]; then
    echo -e "    ${DIM}No changes${NC}"
    return
  fi
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    for f in "${features[@]}"; do
      local var="${f%%:*}"
      _cfg_save_var "$var"
    done
    ok "Changes saved to $ENV_FILE"
    _cfg_offer_update
  else
    echo -e "  ${DIM}Changes discarded.${NC}"
  fi
}

# --- Config Section: Storage ---
_cfg_section_storage() {
  _cfg_header "Storage Configuration"
  
  # Check for active migration
  if [[ -f "$MIGRATION_CONF" ]]; then
    echo -e "  ${YELLOW}Storage migration in progress.${NC}"
    # shellcheck disable=SC1090
    source "$MIGRATION_CONF"
    echo ""
    echo -e "  ${DIM}Source:${NC} ${SOURCE_TYPE:-unknown} → ${SOURCE_MOUNT:-unknown}"
    echo -e "  ${DIM}Target:${NC} ${STORAGE_TYPE:-unknown} → ${SEAFILE_VOLUME:-unknown}"
    echo -e "  ${DIM}Progress:${NC} ${SYNC_PERCENT:-0}%"
    echo ""
    echo -e "    ${BOLD}1${NC}  Check migration status"
    echo -e "    ${BOLD}2${NC}  Perform cutover (finalize migration)"
    echo -e "    ${BOLD}3${NC}  Cancel migration"
    echo -e "    ${BOLD}4${NC}  Back"
    echo ""
    read -r -p "  Select [1-4]: " sel
    case "$sel" in
      1) _storage_migration_status ;;
      2) _storage_migration_cutover ;;
      3) _storage_migration_cancel ;;
    esac
    return
  fi
  
  echo -e "  ${DIM}Current:${NC} ${STORAGE_TYPE:-nfs}"
  case "${STORAGE_TYPE:-nfs}" in
    nfs) echo -e "  ${DIM}Server:${NC}  ${NFS_SERVER:-not set}:${NFS_EXPORT:-not set}" ;;
    smb) echo -e "  ${DIM}Server:${NC}  ${SMB_SERVER:-not set}/${SMB_SHARE:-not set}" ;;
    glusterfs) echo -e "  ${DIM}Server:${NC}  ${GLUSTER_SERVER:-not set}:${GLUSTER_VOLUME:-not set}" ;;
    iscsi) echo -e "  ${DIM}Portal:${NC}  ${ISCSI_PORTAL:-not set}" ;;
    local) echo -e "  ${DIM}Path:${NC}    ${SEAFILE_VOLUME:-/mnt/seafile_nfs}" ;;
  esac
  echo -e "  ${DIM}Mount:${NC}   ${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
  echo ""
  
  echo -e "    ${BOLD}1${NC}  Update current storage settings ${DIM}(same type)${NC}"
  echo -e "    ${BOLD}2${NC}  Migrate to different storage ${DIM}(guided migration)${NC}"
  echo -e "    ${BOLD}3${NC}  Storage classes ${DIM}(multi-backend: ${MULTI_BACKEND_ENABLED:-disabled})${NC}"
  echo -e "    ${BOLD}4${NC}  Back"
  echo ""
  read -r -p "  Select [1-4]: " sel
  
  case "$sel" in
    1) _storage_update_settings ;;
    2) _storage_start_migration ;;
    3) _storage_classes_config ;;
  esac
}

_storage_classes_config() {
  _cfg_header "Storage Classes (Multi-Backend)"

  local current="${MULTI_BACKEND_ENABLED:-false}"

  if [[ "$current" == "true" ]]; then
    echo -e "  ${GREEN}Enabled${NC} — policy: ${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}"
    echo ""
    echo -e "  ${DIM}Defined classes:${NC}"
    local _n=1
    while true; do
      local _id_var="BACKEND_${_n}_ID"
      local _name_var="BACKEND_${_n}_NAME"
      local _default_var="BACKEND_${_n}_DEFAULT"
      local _id="${!_id_var:-}"
      [[ -z "$_id" ]] && break
      local _name="${!_name_var:-Backend $_n}"
      local _is_default="${!_default_var:-false}"
      local _marker=""
      [[ "$_is_default" == "true" ]] && _marker=" ${DIM}(default)${NC}"
      echo -e "    ${BOLD}${_n}${NC}  ${_name} ${DIM}[${_id}]${NC}${_marker}"
      ((_n++))
    done
    echo ""

    local _menu_n=$((_n))
    local _add_n=$_menu_n
    local _pol_n=$((_menu_n+1))
    local _dis_n=$((_menu_n+2))
    echo -e "    ${GREEN}${BOLD}${_add_n}${NC}  Add a storage class"
    echo -e "    ${CYAN}${BOLD}${_pol_n}${NC}  Change mapping policy"
    echo -e "    ${YELLOW}${BOLD}${_dis_n}${NC}  Disable multi-backend"
    echo -e "    ${DIM} 0  Back${NC}"
    echo ""
    read -r -p "  Select: " sel

    if [[ "$sel" == "$_add_n" ]]; then
        local _next_n=$((_n))
        echo ""
        local _new_id=""
        while true; do
          echo -ne "  ${BOLD}ID${NC} ${DIM}(internal, no spaces):${NC} "
          read -r _new_id
          _new_id=$(echo "$_new_id" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
          [[ -n "$_new_id" ]] && break
        done
        local _new_name=""
        while true; do
          echo -ne "  ${BOLD}Name${NC} ${DIM}(visible to users):${NC} "
          read -r _new_name
          [[ -n "$_new_name" ]] && break
        done
        eval "BACKEND_${_next_n}_ID='${_new_id}'"
        eval "BACKEND_${_next_n}_NAME='${_new_name}'"
        eval "BACKEND_${_next_n}_DEFAULT='false'"
        _cfg_save_var "BACKEND_${_next_n}_ID"
        _cfg_save_var "BACKEND_${_next_n}_NAME"
        _cfg_save_var "BACKEND_${_next_n}_DEFAULT"
        ok "Added storage class: ${_new_name} [${_new_id}]"
        _cfg_offer_update
    elif [[ "$sel" == "$_pol_n" ]]; then
        echo ""
        echo -e "  ${BOLD}Mapping policy:${NC}"
        echo -e "    ${GREEN}${BOLD}1${NC}  USER_SELECT — users choose$([ "${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}" == "USER_SELECT" ] && echo " ← current")"
        echo -e "    ${CYAN}${BOLD}2${NC}  ROLE_BASED — admin assigns per role$([ "${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}" == "ROLE_BASED" ] && echo " ← current")"
        echo -e "    ${YELLOW}${BOLD}3${NC}  REPO_ID_MAPPING — automatic distribution$([ "${STORAGE_CLASS_MAPPING_POLICY:-USER_SELECT}" == "REPO_ID_MAPPING" ] && echo " ← current")"
        echo ""
        read -r -p "  Select [1-3]: " _pol
        case "$_pol" in
          1) STORAGE_CLASS_MAPPING_POLICY="USER_SELECT" ;;
          2) STORAGE_CLASS_MAPPING_POLICY="ROLE_BASED" ;;
          3) STORAGE_CLASS_MAPPING_POLICY="REPO_ID_MAPPING" ;;
          *) ;;
        esac
        if [[ -n "${_pol:-}" && "$_pol" =~ ^[1-3]$ ]]; then
          _cfg_save_var STORAGE_CLASS_MAPPING_POLICY
          ok "Mapping policy updated."
          _cfg_offer_update
        fi
    elif [[ "$sel" == "$_dis_n" ]]; then
        MULTI_BACKEND_ENABLED="false"
        _cfg_save_var MULTI_BACKEND_ENABLED
        ok "Multi-backend disabled. Run seafile update to apply."
    fi
  else
    echo -e "  ${DIM}Multi-backend storage is disabled.${NC}"
    echo -e "  ${DIM}Storage classes let you organize libraries into categories${NC}"
    echo -e "  ${DIM}like \"Active Projects\" and \"Archive\".${NC}"
    echo ""
    if [[ "${STORAGE_TYPE:-nfs}" == "local" ]]; then
      echo -e "  ${YELLOW}Not available with local storage.${NC}"
      echo -e "  ${DIM}Multi-backend requires network storage (NFS, SMB, etc.).${NC}"
      echo ""
      return
    fi
    echo -e "    ${BOLD}1${NC}  Enable multi-backend storage"
    echo -e "    ${BOLD}2${NC}  Back"
    echo ""
    read -r -p "  Select [1-2]: " sel
    if [[ "$sel" == "1" ]]; then
      MULTI_BACKEND_ENABLED="true"
      _cfg_save_var MULTI_BACKEND_ENABLED

      # Ensure at least the primary backend exists
      if [[ -z "${BACKEND_1_ID:-}" ]]; then
        BACKEND_1_ID="primary"
        BACKEND_1_NAME="Primary Storage"
        BACKEND_1_DEFAULT="true"
        _cfg_save_var BACKEND_1_ID
        _cfg_save_var BACKEND_1_NAME
        _cfg_save_var BACKEND_1_DEFAULT
        echo ""
        echo -e "  ${DIM}Created default primary backend. Add more with${NC}"
        echo -e "  ${DIM}seafile config storage → Storage classes → Add.${NC}"
      fi
      ok "Multi-backend enabled."
      _cfg_offer_update
    fi
  fi
}

_storage_update_settings() {
  _cfg_header "Update Storage Settings"
  
  case "${STORAGE_TYPE:-nfs}" in
    nfs)
      _cfg_input NFS_SERVER "NFS server" "IP or hostname"
      _cfg_input NFS_EXPORT "NFS export path"
      ;;
    smb)
      _cfg_input SMB_SERVER "SMB server" "IP or hostname"
      _cfg_input SMB_SHARE "Share name"
      _cfg_input SMB_USERNAME "Username"
      _cfg_password SMB_PASSWORD "Password"
      _cfg_input SMB_DOMAIN "Domain" "leave blank for workgroup"
      ;;
    glusterfs)
      _cfg_input GLUSTER_SERVER "GlusterFS server"
      _cfg_input GLUSTER_VOLUME "Volume name"
      ;;
    iscsi)
      _cfg_input ISCSI_PORTAL "iSCSI portal" "IP:port"
      _cfg_input ISCSI_TARGET_IQN "Target IQN"
      ;;
  esac
  
  _cfg_input SEAFILE_VOLUME "Mount point"
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    case "${STORAGE_TYPE:-nfs}" in
      nfs)
        _cfg_save_var NFS_SERVER
        _cfg_save_var NFS_EXPORT
        ;;
      smb)
        _cfg_save_var SMB_SERVER
        _cfg_save_var SMB_SHARE
        _cfg_save_var SMB_USERNAME
        _cfg_save_var SMB_PASSWORD
        _cfg_save_var SMB_DOMAIN
        ;;
      glusterfs)
        _cfg_save_var GLUSTER_SERVER
        _cfg_save_var GLUSTER_VOLUME
        ;;
      iscsi)
        _cfg_save_var ISCSI_PORTAL
        _cfg_save_var ISCSI_TARGET_IQN
        ;;
    esac
    _cfg_save_var SEAFILE_VOLUME
    ok "Changes saved to $ENV_FILE"
    echo ""
    warn "Storage changes require remounting. This may require a reboot."
  fi
}

_storage_start_migration() {
  _cfg_header "Storage Migration"
  
  echo -e "  ${YELLOW}This will migrate all data to a new storage backend.${NC}"
  echo ""
  echo -e "  ${DIM}The process has 4 phases:${NC}"
  echo -e "    1. Background sync ${DIM}(system stays online)${NC}"
  echo -e "    2. Quick restart ${DIM}(~30 seconds)${NC}"
  echo -e "    3. Continue syncing while online"
  echo -e "    4. Final cutover ${DIM}(~2-5 minutes downtime)${NC}"
  echo ""
  echo -e "  ${DIM}You can cancel anytime before Phase 4.${NC}"
  echo ""
  
  echo -e "  ${BOLD}Select new storage type:${NC}"
  echo ""
  echo -e "    ${BOLD}1${NC}  NFS"
  echo -e "    ${BOLD}2${NC}  SMB/CIFS"
  echo -e "    ${BOLD}3${NC}  GlusterFS"
  echo -e "    ${BOLD}4${NC}  iSCSI"
  echo -e "    ${BOLD}5${NC}  Cancel"
  echo ""
  read -r -p "  Select [1-5]: " sel
  
  local new_type=""
  case "$sel" in
    1) new_type="nfs" ;;
    2) new_type="smb" ;;
    3) new_type="glusterfs" ;;
    4) new_type="iscsi" ;;
    *) return ;;
  esac
  
  if [[ "$new_type" == "${STORAGE_TYPE:-nfs}" ]]; then
    warn "That's the same type you're currently using."
    echo -e "  ${DIM}Use 'Update current storage settings' to change server/path.${NC}"
    return
  fi
  
  # Collect new storage details
  _cfg_header "Configure New $new_type Storage"
  
  local new_mount="/mnt/seafile_${new_type}"
  
  case "$new_type" in
    nfs)
      local NEW_NFS_SERVER NEW_NFS_EXPORT
      _cfg_input NEW_NFS_SERVER "NFS server" "IP or hostname"
      _cfg_input NEW_NFS_EXPORT "NFS export path"
      new_mount="/mnt/seafile_nfs"
      ;;
    smb)
      local NEW_SMB_SERVER NEW_SMB_SHARE NEW_SMB_USERNAME NEW_SMB_PASSWORD NEW_SMB_DOMAIN
      _cfg_input NEW_SMB_SERVER "SMB server" "IP or hostname"
      _cfg_input NEW_SMB_SHARE "Share name"
      _cfg_input NEW_SMB_USERNAME "Username"
      _cfg_password NEW_SMB_PASSWORD "Password"
      _cfg_input NEW_SMB_DOMAIN "Domain" "leave blank for workgroup"
      new_mount="/mnt/seafile_smb"
      ;;
    glusterfs)
      local NEW_GLUSTER_SERVER NEW_GLUSTER_VOLUME
      _cfg_input NEW_GLUSTER_SERVER "GlusterFS server"
      _cfg_input NEW_GLUSTER_VOLUME "Volume name"
      new_mount="/mnt/seafile_gluster"
      ;;
    iscsi)
      local NEW_ISCSI_PORTAL NEW_ISCSI_TARGET_IQN
      _cfg_input NEW_ISCSI_PORTAL "iSCSI portal" "IP:port"
      _cfg_input NEW_ISCSI_TARGET_IQN "Target IQN"
      new_mount="/mnt/seafile_iscsi"
      ;;
  esac
  
  _cfg_rule
  echo -e "  ${BOLD}Migration Summary${NC}"
  echo ""
  echo -e "  ${DIM}From:${NC} ${STORAGE_TYPE:-nfs} → ${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
  echo -e "  ${DIM}To:${NC}   $new_type → $new_mount"
  echo ""
  echo -e "    ${BOLD}1${NC}  Start migration"
  echo -e "    ${BOLD}2${NC}  Cancel"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" != "1" ]]; then
    echo -e "  ${DIM}Migration cancelled.${NC}"
    return
  fi
  
  # Create migration config
  cat > "$MIGRATION_CONF" << MIGCONF
# Storage Migration State
# Generated: $(date -Iseconds)
# Do not edit manually

MIGRATION_ID=migrate_$(date +%Y%m%d_%H%M%S)
MIGRATION_STARTED=$(date -Iseconds)
MIGRATION_PHASE=1

# Source (migrating FROM)
SOURCE_STORAGE_ID=old_${STORAGE_TYPE:-nfs}
SOURCE_TYPE=${STORAGE_TYPE:-nfs}
SOURCE_MOUNT=${SEAFILE_VOLUME:-/mnt/seafile_nfs}
MIGCONF

  # Add source credentials to migration conf
  case "${STORAGE_TYPE:-nfs}" in
    nfs)
      echo "SOURCE_NFS_SERVER=${NFS_SERVER:-}" >> "$MIGRATION_CONF"
      echo "SOURCE_NFS_EXPORT=${NFS_EXPORT:-}" >> "$MIGRATION_CONF"
      ;;
    smb)
      echo "SOURCE_SMB_SERVER=${SMB_SERVER:-}" >> "$MIGRATION_CONF"
      echo "SOURCE_SMB_SHARE=${SMB_SHARE:-}" >> "$MIGRATION_CONF"
      echo "SOURCE_SMB_USERNAME=${SMB_USERNAME:-}" >> "$MIGRATION_CONF"
      echo "SOURCE_SMB_PASSWORD=${SMB_PASSWORD:-}" >> "$MIGRATION_CONF"
      echo "SOURCE_SMB_DOMAIN=${SMB_DOMAIN:-}" >> "$MIGRATION_CONF"
      ;;
  esac
  
  # Add target info
  cat >> "$MIGRATION_CONF" << MIGCONF

# Target (migrating TO)
TARGET_STORAGE_ID=new_${new_type}
TARGET_TYPE=${new_type}
TARGET_MOUNT=${new_mount}

# Sync progress
SYNC_STARTED=
SYNC_LAST_RUN=
SYNC_BYTES_TOTAL=0
SYNC_BYTES_COPIED=0
SYNC_PERCENT=0
MIGCONF

  chmod 600 "$MIGRATION_CONF"
  
  # Update .env with new target
  STORAGE_TYPE="$new_type"
  SEAFILE_VOLUME="$new_mount"
  _cfg_save_var STORAGE_TYPE
  _cfg_save_var SEAFILE_VOLUME
  
  case "$new_type" in
    nfs)
      NFS_SERVER="$NEW_NFS_SERVER"
      NFS_EXPORT="$NEW_NFS_EXPORT"
      _cfg_save_var NFS_SERVER
      _cfg_save_var NFS_EXPORT
      ;;
    smb)
      SMB_SERVER="$NEW_SMB_SERVER"
      SMB_SHARE="$NEW_SMB_SHARE"
      SMB_USERNAME="$NEW_SMB_USERNAME"
      SMB_PASSWORD="$NEW_SMB_PASSWORD"
      SMB_DOMAIN="$NEW_SMB_DOMAIN"
      _cfg_save_var SMB_SERVER
      _cfg_save_var SMB_SHARE
      _cfg_save_var SMB_USERNAME
      _cfg_save_var SMB_PASSWORD
      _cfg_save_var SMB_DOMAIN
      ;;
  esac
  
  ok "Migration configuration created"
  
  # Start sync service
  echo ""
  echo -e "  ${DIM}Starting background sync service...${NC}"
  systemctl start seafile-storage-sync 2>/dev/null && \
    ok "Sync service started" || \
    err "Failed to start sync service"
  
  echo ""
  ok "Migration Phase 1 started!"
  echo ""
  echo -e "  ${DIM}Background sync is now running.${NC}"
  echo -e "  ${DIM}Check progress with: ${BOLD}seafile config storage${NC}"
  echo -e "  ${DIM}Or: ${BOLD}journalctl -u seafile-storage-sync -f${NC}"
  echo ""
}

_storage_migration_status() {
  _cfg_header "Migration Status"
  
  if [[ ! -f "$MIGRATION_CONF" ]]; then
    echo -e "  ${DIM}No migration in progress.${NC}"
    return
  fi
  
  # shellcheck disable=SC1090
  source "$MIGRATION_CONF"
  
  echo -e "  ${DIM}Migration ID:${NC}  $MIGRATION_ID"
  echo -e "  ${DIM}Started:${NC}       $MIGRATION_STARTED"
  echo -e "  ${DIM}Phase:${NC}         $MIGRATION_PHASE"
  echo ""
  echo -e "  ${DIM}Source:${NC}        $SOURCE_TYPE → $SOURCE_MOUNT"
  echo -e "  ${DIM}Target:${NC}        $TARGET_TYPE → $TARGET_MOUNT"
  echo ""
  
  local total_hr=$(numfmt --to=iec-i --suffix=B "$SYNC_BYTES_TOTAL" 2>/dev/null || echo "$SYNC_BYTES_TOTAL bytes")
  local copied_hr=$(numfmt --to=iec-i --suffix=B "$SYNC_BYTES_COPIED" 2>/dev/null || echo "$SYNC_BYTES_COPIED bytes")
  
  echo -e "  ${DIM}Progress:${NC}      ${SYNC_PERCENT:-0}% ($copied_hr / $total_hr)"
  echo -e "  ${DIM}Last sync:${NC}     ${SYNC_LAST_RUN:-not started}"
  echo ""
  
  if systemctl is-active --quiet seafile-storage-sync 2>/dev/null; then
    ok "Sync service is running"
  else
    warn "Sync service is not running"
  fi
  echo ""
}

_storage_migration_cutover() {
  _cfg_header "Storage Migration Cutover"
  
  if [[ ! -f "$MIGRATION_CONF" ]]; then
    echo -e "  ${DIM}No migration in progress.${NC}"
    return
  fi
  
  echo -e "  ${YELLOW}This will finalize the migration.${NC}"
  echo ""
  echo -e "  ${DIM}Steps:${NC}"
  echo -e "    1. Stop Seafile"
  echo -e "    2. Final sync (deltas only)"
  echo -e "    3. Update database storage IDs"
  echo -e "    4. Remove old storage config"
  echo -e "    5. Restart Seafile"
  echo ""
  echo -e "  ${DIM}Expected downtime: 2-5 minutes${NC}"
  echo ""
  echo -e "  ${BOLD}Proceed with cutover? [y/N]:${NC} "
  read -r confirm
  
  if [[ ! "${confirm,,}" =~ ^y ]]; then
    echo -e "  ${DIM}Cutover cancelled.${NC}"
    return
  fi
  
  echo ""
  echo -e "  ${DIM}Signaling final sync...${NC}"
  touch /opt/seafile/.storage-migration-cutover
  
  echo -e "  ${DIM}Waiting for sync to complete...${NC}"
  local timeout=300
  local waited=0
  while [[ ! -f "$MIGRATION_CONF" ]] || ! grep -q "FINAL_SYNC_COMPLETE" "$MIGRATION_CONF" 2>/dev/null; do
    sleep 5
    ((waited+=5))
    if [[ $waited -ge $timeout ]]; then
      err "Timeout waiting for final sync"
      return 1
    fi
    echo -e "  ${DIM}Waiting... (${waited}s)${NC}"
  done
  
  ok "Final sync complete"
  
  # Stop sync service
  systemctl stop seafile-storage-sync 2>/dev/null
  systemctl disable seafile-storage-sync 2>/dev/null
  
  # Clean up migration config
  rm -f "$MIGRATION_CONF"
  rm -f /opt/seafile/.storage-migration-cutover
  
  ok "Migration complete!"
  echo ""
  echo -e "  ${DIM}Your deployment is now using the new storage.${NC}"
  echo -e "  ${DIM}Old storage data can be manually deleted when ready.${NC}"
  echo ""
  
  # Run update to apply config
  _cfg_offer_update
}

_storage_migration_cancel() {
  _cfg_header "Cancel Storage Migration"
  
  echo -e "  ${YELLOW}This will cancel the migration and revert to the original storage.${NC}"
  echo ""
  echo -e "  ${BOLD}Are you sure? [y/N]:${NC} "
  read -r confirm
  
  if [[ ! "${confirm,,}" =~ ^y ]]; then
    echo -e "  ${DIM}Cancelled.${NC}"
    return
  fi
  
  # Stop sync service
  systemctl stop seafile-storage-sync 2>/dev/null
  
  # Source migration config to get original values
  if [[ -f "$MIGRATION_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$MIGRATION_CONF"
    
    # Restore original storage config
    STORAGE_TYPE="$SOURCE_TYPE"
    SEAFILE_VOLUME="$SOURCE_MOUNT"
    _cfg_save_var STORAGE_TYPE
    _cfg_save_var SEAFILE_VOLUME
    
    # Restore type-specific vars
    case "$SOURCE_TYPE" in
      nfs)
        NFS_SERVER="$SOURCE_NFS_SERVER"
        NFS_EXPORT="$SOURCE_NFS_EXPORT"
        _cfg_save_var NFS_SERVER
        _cfg_save_var NFS_EXPORT
        ;;
      smb)
        SMB_SERVER="$SOURCE_SMB_SERVER"
        SMB_SHARE="$SOURCE_SMB_SHARE"
        SMB_USERNAME="$SOURCE_SMB_USERNAME"
        SMB_PASSWORD="$SOURCE_SMB_PASSWORD"
        SMB_DOMAIN="$SOURCE_SMB_DOMAIN"
        _cfg_save_var SMB_SERVER
        _cfg_save_var SMB_SHARE
        _cfg_save_var SMB_USERNAME
        _cfg_save_var SMB_PASSWORD
        _cfg_save_var SMB_DOMAIN
        ;;
    esac
    
    rm -f "$MIGRATION_CONF"
  fi
  
  rm -f /opt/seafile/.storage-migration-cutover
  
  ok "Migration cancelled. Original storage configuration restored."
  echo ""
}

# --- Config Section: Database ---
DB_MIGRATION_CONF="/opt/seafile/.db-migration.conf"

_cfg_section_database() {
  _cfg_header "Database Configuration"
  
  local is_internal="${DB_INTERNAL:-true}"
  
  echo -e "  ${DIM}Current mode:${NC} $([ "$is_internal" == "true" ] && echo "Bundled (MariaDB container)" || echo "External MySQL/MariaDB")"
  
  if [[ "$is_internal" != "true" ]]; then
    echo -e "  ${DIM}Host:${NC}         ${SEAFILE_MYSQL_DB_HOST:-not set}"
    echo -e "  ${DIM}User:${NC}         ${SEAFILE_MYSQL_DB_USER:-seafile}"
    echo -e "  ${DIM}Port:${NC}         ${SEAFILE_MYSQL_DB_PORT:-3306}"
  else
    echo -e "  ${DIM}Volume:${NC}       ${DB_INTERNAL_VOLUME:-/opt/seafile-db}"
  fi
  echo ""
  
  if [[ "$is_internal" == "true" ]]; then
    echo -e "    ${BOLD}1${NC}  Update bundled DB settings"
    echo -e "    ${BOLD}2${NC}  Migrate to external database ${DIM}(guided)${NC}"
    echo -e "    ${BOLD}3${NC}  Back"
    echo ""
    read -r -p "  Select [1-3]: " sel
    case "$sel" in
      1) _db_update_bundled ;;
      2) _db_migrate_to_external ;;
    esac
  else
    echo -e "    ${BOLD}1${NC}  Update external DB settings"
    echo -e "    ${BOLD}2${NC}  Migrate to bundled database ${DIM}(guided)${NC}"
    echo -e "    ${BOLD}3${NC}  Back"
    echo ""
    read -r -p "  Select [1-3]: " sel
    case "$sel" in
      1) _db_update_external ;;
      2) _db_migrate_to_bundled ;;
    esac
  fi
}

_db_update_bundled() {
  _cfg_header "Update Bundled Database Settings"
  
  _cfg_input DB_INTERNAL_VOLUME "Database volume path"
  _cfg_input DB_INTERNAL_IMAGE "MariaDB image tag"
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    _cfg_save_var DB_INTERNAL_VOLUME
    _cfg_save_var DB_INTERNAL_IMAGE
    ok "Changes saved"
    _cfg_offer_update
  fi
}

_db_update_external() {
  _cfg_header "Update External Database Settings"
  
  _cfg_input SEAFILE_MYSQL_DB_HOST "Database host" "IP or hostname"
  _cfg_input SEAFILE_MYSQL_DB_PORT "Database port"
  _cfg_input SEAFILE_MYSQL_DB_USER "Database user"
  _cfg_password SEAFILE_MYSQL_DB_PASSWORD "Database password"
  
  echo ""
  echo -e "    ${BOLD}1${NC}  Save changes"
  echo -e "    ${BOLD}2${NC}  Discard"
  echo ""
  read -r -p "  Select [1-2]: " sel
  
  if [[ "$sel" == "1" ]]; then
    _cfg_save_var SEAFILE_MYSQL_DB_HOST
    _cfg_save_var SEAFILE_MYSQL_DB_PORT
    _cfg_save_var SEAFILE_MYSQL_DB_USER
    _cfg_save_var SEAFILE_MYSQL_DB_PASSWORD
    ok "Changes saved"
    _cfg_offer_update
  fi
}

_db_migrate_to_external() {
  _cfg_header "Migrate to External Database"
  
  echo -e "  ${YELLOW}This will export your bundled database and import to an external server.${NC}"
  echo ""
  echo -e "  ${DIM}Prerequisites:${NC}"
  echo -e "    • External MySQL/MariaDB server accessible from this host"
  echo -e "    • Empty databases created: ccnet_db, seafile_db, seahub_db"
  echo -e "    • User with full privileges on those databases"
  echo ""
  echo -e "  ${DIM}See README → Step 3: Set Up the Database${NC}"
  echo ""
  
  if ! _cfg_yesno "Have you prepared the external database?"; then
    echo -e "  ${DIM}Please prepare the database first, then return.${NC}"
    return
  fi
  
  _cfg_rule
  echo -e "  ${BOLD}Step 1: External Database Details${NC}"
  echo ""
  
  local NEW_DB_HOST NEW_DB_PORT NEW_DB_USER NEW_DB_PASSWORD NEW_DB_ROOT_PASSWORD
  _cfg_input NEW_DB_HOST "External DB host" "IP or hostname"
  NEW_DB_PORT="${SEAFILE_MYSQL_DB_PORT:-3306}"
  _cfg_input NEW_DB_PORT "External DB port"
  NEW_DB_USER="${SEAFILE_MYSQL_DB_USER:-seafile}"
  _cfg_input NEW_DB_USER "Database user"
  _cfg_password NEW_DB_PASSWORD "Database password"
  echo ""
  echo -e "  ${DIM}Root password needed for import:${NC}"
  _cfg_password NEW_DB_ROOT_PASSWORD "External DB root password"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 2: Test Connection${NC}"
  echo ""
  echo -e "  ${DIM}Testing connection to ${NEW_DB_HOST}:${NEW_DB_PORT}...${NC}"
  
  if ! command -v mysql &>/dev/null; then
    warn "mysql client not installed — installing..."
    apt-get install -y mariadb-client &>/dev/null || {
      err "Failed to install mysql client"
      return 1
    }
  fi
  
  if ! MYSQL_PWD="$NEW_DB_ROOT_PASSWORD" mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -e "SELECT 1" &>/dev/null; then
    err "Cannot connect to external database"
    echo -e "  ${DIM}Check host, port, and root credentials.${NC}"
    return 1
  fi
  ok "Connection successful"
  
  # Check databases exist
  echo -e "  ${DIM}Checking databases exist...${NC}"
  for db in ccnet_db seafile_db seahub_db; do
    if ! MYSQL_PWD="$NEW_DB_ROOT_PASSWORD" mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -e "USE $db" &>/dev/null; then
      err "Database $db does not exist on external server"
      return 1
    fi
  done
  ok "All three databases found"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 3: Export from Bundled Database${NC}"
  echo ""
  
  local DUMP_FILE="/tmp/seafile_db_migration_$(date +%Y%m%d_%H%M%S).sql"
  touch "$DUMP_FILE"; chmod 600 "$DUMP_FILE"
  
  echo -e "  ${DIM}Stopping Seafile services...${NC}"
  docker compose -f /opt/seafile/docker-compose.yml stop seafile seadoc notification-server thumbnail-server seafile-metadata 2>/dev/null || true
  ok "Services stopped (database container still running)"
  
  echo -e "  ${DIM}Exporting databases...${NC}"
  local ROOT_PASS="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}"
  
  if ! docker exec -e MYSQL_PWD="$ROOT_PASS" seafile-db mysqldump -u root --single-transaction \
       --databases ccnet_db seafile_db seahub_db > "$DUMP_FILE" 2>/dev/null; then
    err "Failed to export databases"
    echo -e "  ${DIM}Starting services again...${NC}"
    docker compose -f /opt/seafile/docker-compose.yml up -d 2>/dev/null
    return 1
  fi
  
  local dump_size=$(du -h "$DUMP_FILE" | cut -f1)
  ok "Export complete: $DUMP_FILE ($dump_size)"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 4: Import to External Database${NC}"
  echo ""
  echo -e "  ${DIM}Importing to ${NEW_DB_HOST}...${NC}"
  
  if ! MYSQL_PWD="$NEW_DB_ROOT_PASSWORD" mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root < "$DUMP_FILE" 2>/dev/null; then
    err "Failed to import databases"
    echo -e "  ${DIM}Manual import: mysql -h $NEW_DB_HOST -u root -p < $DUMP_FILE${NC}"
    echo -e "  ${DIM}Starting services again...${NC}"
    docker compose -f /opt/seafile/docker-compose.yml up -d 2>/dev/null
    return 1
  fi
  ok "Import complete"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 5: Verify Import${NC}"
  echo ""
  
  local orig_count new_count
  orig_count=$(docker exec -e MYSQL_PWD="$ROOT_PASS" seafile-db mysql -u root -N -e "SELECT COUNT(*) FROM seahub_db.auth_user" 2>/dev/null || echo "0")
  new_count=$(MYSQL_PWD="$NEW_DB_ROOT_PASSWORD" mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -N -e "SELECT COUNT(*) FROM seahub_db.auth_user" 2>/dev/null || echo "0")
  
  echo -e "  ${DIM}User count - Original: $orig_count, External: $new_count${NC}"
  
  if [[ "$orig_count" != "$new_count" ]]; then
    warn "User counts don't match — verify manually"
    if ! _cfg_yesno "Continue anyway?"; then
      echo -e "  ${DIM}Starting original services...${NC}"
      docker compose -f /opt/seafile/docker-compose.yml up -d 2>/dev/null
      return 1
    fi
  else
    ok "Verification passed"
  fi
  
  _cfg_rule
  echo -e "  ${BOLD}Step 6: Update Configuration${NC}"
  echo ""
  
  DB_INTERNAL="false"
  SEAFILE_MYSQL_DB_HOST="$NEW_DB_HOST"
  SEAFILE_MYSQL_DB_PORT="$NEW_DB_PORT"
  SEAFILE_MYSQL_DB_USER="$NEW_DB_USER"
  SEAFILE_MYSQL_DB_PASSWORD="$NEW_DB_PASSWORD"
  
  _cfg_save_var DB_INTERNAL
  _cfg_save_var SEAFILE_MYSQL_DB_HOST
  _cfg_save_var SEAFILE_MYSQL_DB_PORT
  _cfg_save_var SEAFILE_MYSQL_DB_USER
  _cfg_save_var SEAFILE_MYSQL_DB_PASSWORD
  
  ok "Configuration updated"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 7: Apply Changes${NC}"
  echo ""
  echo -e "  ${DIM}Running seafile update to remove bundled DB and restart...${NC}"
  
  /opt/update.sh || true
  
  ok "Migration complete!"
  echo ""
  echo -e "  ${DIM}Dump file retained at: $DUMP_FILE${NC}"
  echo -e "  ${DIM}You can delete it after verifying everything works.${NC}"
  echo ""
  echo -e "  ${YELLOW}Note:${NC} The old bundled DB volume still exists at ${DB_INTERNAL_VOLUME:-/opt/seafile-db}"
  echo -e "  ${DIM}Delete it manually when ready: rm -rf ${DB_INTERNAL_VOLUME:-/opt/seafile-db}${NC}"
  echo ""
}

_db_migrate_to_bundled() {
  _cfg_header "Migrate to Bundled Database"
  
  echo -e "  ${YELLOW}This will export your external database and import to a bundled container.${NC}"
  echo ""
  echo -e "  ${DIM}This will:${NC}"
  echo -e "    1. Create a new MariaDB container"
  echo -e "    2. Export data from ${SEAFILE_MYSQL_DB_HOST:-external server}"
  echo -e "    3. Import to the bundled container"
  echo -e "    4. Switch configuration to use bundled DB"
  echo ""
  
  if ! _cfg_yesno "Proceed with migration?"; then
    return
  fi
  
  local DB_VOLUME="${DB_INTERNAL_VOLUME:-/opt/seafile-db}"
  _cfg_input DB_VOLUME "Bundled DB volume path"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 1: Export from External Database${NC}"
  echo ""
  
  local DUMP_FILE="/tmp/seafile_db_migration_$(date +%Y%m%d_%H%M%S).sql"
  touch "$DUMP_FILE"; chmod 600 "$DUMP_FILE"
  
  echo -e "  ${DIM}Stopping Seafile services...${NC}"
  docker compose -f /opt/seafile/docker-compose.yml stop seafile seadoc notification-server thumbnail-server seafile-metadata 2>/dev/null || true
  ok "Services stopped"
  
  echo -e "  ${DIM}Exporting from ${SEAFILE_MYSQL_DB_HOST}...${NC}"
  
  if ! command -v mysqldump &>/dev/null; then
    warn "mysqldump not installed — installing..."
    apt-get install -y mariadb-client &>/dev/null || {
      err "Failed to install mysql client"
      return 1
    }
  fi
  
  if ! MYSQL_PWD="${SEAFILE_MYSQL_DB_PASSWORD}" mysqldump -h "$SEAFILE_MYSQL_DB_HOST" -P "${SEAFILE_MYSQL_DB_PORT:-3306}" \
       -u "${SEAFILE_MYSQL_DB_USER:-seafile}" \
       --single-transaction --databases ccnet_db seafile_db seahub_db > "$DUMP_FILE" 2>/dev/null; then
    err "Failed to export databases"
    echo -e "  ${DIM}Starting services again...${NC}"
    docker compose -f /opt/seafile/docker-compose.yml up -d 2>/dev/null
    return 1
  fi
  
  local dump_size=$(du -h "$DUMP_FILE" | cut -f1)
  ok "Export complete: $DUMP_FILE ($dump_size)"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 2: Create Bundled Database Container${NC}"
  echo ""
  
  # Generate new root password for bundled DB
  local NEW_ROOT_PASS=$(openssl rand -base64 24 2>/dev/null || head -c 32 /dev/urandom | base64)
  
  echo -e "  ${DIM}Creating database volume at $DB_VOLUME...${NC}"
  mkdir -p "$DB_VOLUME"
  
  # Update config first so compose file includes the DB
  DB_INTERNAL="true"
  DB_INTERNAL_VOLUME="$DB_VOLUME"
  INIT_SEAFILE_MYSQL_ROOT_PASSWORD="$NEW_ROOT_PASS"
  
  _cfg_save_var DB_INTERNAL
  _cfg_save_var DB_INTERNAL_VOLUME
  _cfg_save_var INIT_SEAFILE_MYSQL_ROOT_PASSWORD
  
  echo -e "  ${DIM}Starting bundled database container...${NC}"
  /opt/update.sh --no-fix 2>/dev/null || true
  
  # Wait for DB to be ready
  echo -e "  ${DIM}Waiting for database to initialize...${NC}"
  local waited=0
  while ! docker exec -e MYSQL_PWD="$NEW_ROOT_PASS" seafile-db mysqladmin ping -u root &>/dev/null; do
    sleep 2
    ((waited+=2))
    if [[ $waited -ge 60 ]]; then
      err "Timeout waiting for database container"
      return 1
    fi
  done
  ok "Database container ready"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 3: Import to Bundled Database${NC}"
  echo ""
  
  echo -e "  ${DIM}Importing data...${NC}"
  if ! docker exec -i -e MYSQL_PWD="$NEW_ROOT_PASS" seafile-db mysql -u root < "$DUMP_FILE" 2>/dev/null; then
    err "Failed to import databases"
    return 1
  fi
  ok "Import complete"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 4: Restart Services${NC}"
  echo ""
  
  docker compose -f /opt/seafile/docker-compose.yml up -d 2>/dev/null
  /opt/seafile-config-fixes.sh 2>/dev/null || true
  
  ok "Migration complete!"
  echo ""
  echo -e "  ${DIM}Dump file retained at: $DUMP_FILE${NC}"
  echo -e "  ${DIM}External database is unchanged — you can decommission it when ready.${NC}"
  echo ""
}

# --- Config Section: Proxy ---
_cfg_section_proxy() {
  _cfg_header "Reverse Proxy Configuration"
  
  local current="${PROXY_TYPE:-nginx}"
  
  echo -e "  ${DIM}Current:${NC} $current"
  case "$current" in
    nginx) echo -e "  ${DIM}Mode:${NC}    External Nginx Proxy Manager or similar" ;;
    caddy-bundled) echo -e "  ${DIM}Mode:${NC}    Bundled Caddy with auto-SSL (ports 80/443)" ;;
    caddy-external) echo -e "  ${DIM}Mode:${NC}    External Caddy reverse proxy" ;;
    traefik) echo -e "  ${DIM}Mode:${NC}    Traefik with Docker labels" ;;
    haproxy) echo -e "  ${DIM}Mode:${NC}    External HAProxy" ;;
  esac
  echo -e "  ${DIM}Port:${NC}    ${CADDY_PORT:-7080}"
  echo ""
  
  echo -e "  ${BOLD}Select proxy type:${NC}"
  echo ""
  echo -e "    ${BOLD}1${NC}  Nginx Proxy Manager ${DIM}(external)${NC}$([ "$current" == "nginx" ] && echo " ← current")"
  echo -e "    ${BOLD}2${NC}  Caddy bundled ${DIM}(auto-SSL, ports 80/443)${NC}$([ "$current" == "caddy-bundled" ] && echo " ← current")"
  echo -e "    ${BOLD}3${NC}  Caddy external ${DIM}(your own Caddy)${NC}$([ "$current" == "caddy-external" ] && echo " ← current")"
  echo -e "    ${BOLD}4${NC}  Traefik ${DIM}(Docker labels)${NC}$([ "$current" == "traefik" ] && echo " ← current")"
  echo -e "    ${BOLD}5${NC}  HAProxy ${DIM}(external)${NC}$([ "$current" == "haproxy" ] && echo " ← current")"
  echo -e "    ${BOLD}6${NC}  Back"
  echo ""
  read -r -p "  Select [1-6]: " sel
  
  local new_type=""
  case "$sel" in
    1) new_type="nginx" ;;
    2) new_type="caddy-bundled" ;;
    3) new_type="caddy-external" ;;
    4) new_type="traefik" ;;
    5) new_type="haproxy" ;;
    *) return ;;
  esac
  
  local changed=false
  
  if [[ "$new_type" != "$current" ]]; then
    PROXY_TYPE="$new_type"
    changed=true
  fi
  
  # Type-specific configuration
  case "$new_type" in
    caddy-bundled)
      _cfg_rule
      echo -e "  ${BOLD}Caddy Bundled Configuration${NC}"
      echo ""
      echo -e "  ${DIM}Caddy will handle SSL automatically using Let's Encrypt.${NC}"
      echo -e "  ${DIM}Ports 80 and 443 must be available on this host.${NC}"
      echo ""
      CADDY_PORT="80"
      CADDY_HTTPS_PORT="443"
      SEAFILE_SERVER_PROTOCOL="https"
      changed=true
      ;;
    traefik)
      _cfg_rule
      echo -e "  ${BOLD}Traefik Configuration${NC}"
      echo ""
      local orig_enabled="$TRAEFIK_ENABLED"
      TRAEFIK_ENABLED="true"
      _cfg_input TRAEFIK_ENTRYPOINT "Traefik entrypoint"
      _cfg_input TRAEFIK_CERTRESOLVER "Traefik cert resolver"
      if [[ "$orig_enabled" != "true" ]]; then
        changed=true
      fi
      ;;
    nginx|caddy-external|haproxy)
      _cfg_rule
      echo -e "  ${BOLD}HTTP Port Configuration${NC}"
      echo ""
      echo -e "  ${DIM}This is the port the internal Caddy listens on.${NC}"
      echo -e "  ${DIM}Your external proxy should forward to this port.${NC}"
      echo ""
      local orig_port="$CADDY_PORT"
      _cfg_input CADDY_PORT "Internal HTTP port"
      if [[ "$orig_port" != "$CADDY_PORT" ]]; then
        changed=true
      fi
      ;;
  esac
  
  if [[ "$changed" == "true" ]]; then
    _cfg_rule
    echo -e "  ${BOLD}Changes:${NC}"
    [[ "$new_type" != "$current" ]] && echo -e "    PROXY_TYPE: $current → ${YELLOW}$new_type${NC}"
    echo ""
    echo -e "    ${BOLD}1${NC}  Save changes"
    echo -e "    ${BOLD}2${NC}  Discard"
    echo ""
    read -r -p "  Select [1-2]: " sel
    
    if [[ "$sel" == "1" ]]; then
      _cfg_save_var PROXY_TYPE
      case "$new_type" in
        caddy-bundled)
          _cfg_save_var CADDY_PORT
          _cfg_save_var CADDY_HTTPS_PORT
          _cfg_save_var SEAFILE_SERVER_PROTOCOL
          TRAEFIK_ENABLED="false"
          _cfg_save_var TRAEFIK_ENABLED
          ;;
        traefik)
          _cfg_save_var TRAEFIK_ENABLED
          _cfg_save_var TRAEFIK_ENTRYPOINT
          _cfg_save_var TRAEFIK_CERTRESOLVER
          ;;
        *)
          TRAEFIK_ENABLED="false"
          _cfg_save_var TRAEFIK_ENABLED
          _cfg_save_var CADDY_PORT
          ;;
      esac
      ok "Proxy configuration saved"
      _cfg_offer_update
    else
      echo -e "  ${DIM}Cancelled.${NC}"
    fi
  else
    echo -e "  ${DIM}No changes.${NC}"
  fi
}

# --- Config Section: Show ---
_cfg_section_show() {
  local show_secrets="${1:-false}"
  
  _cfg_header "Current Configuration"
  
  echo -e "  ${BOLD}Core${NC}"
  echo -e "    SEAFILE_SERVER_HOSTNAME:    ${SEAFILE_SERVER_HOSTNAME:-}"
  echo -e "    SEAFILE_SERVER_PROTOCOL:    ${SEAFILE_SERVER_PROTOCOL:-https}"
  echo -e "    INIT_SEAFILE_ADMIN_EMAIL:   ${INIT_SEAFILE_ADMIN_EMAIL:-}"
  echo ""
  
  echo -e "  ${BOLD}Storage${NC}"
  echo -e "    STORAGE_TYPE:               ${STORAGE_TYPE:-nfs}"
  echo -e "    SEAFILE_VOLUME:             ${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
  echo ""
  
  echo -e "  ${BOLD}Database${NC}"
  echo -e "    DB_INTERNAL:                ${DB_INTERNAL:-true}"
  [[ "${DB_INTERNAL:-true}" != "true" ]] && echo -e "    SEAFILE_MYSQL_DB_HOST:      ${SEAFILE_MYSQL_DB_HOST:-}"
  echo ""
  
  echo -e "  ${BOLD}Office Suite${NC}"
  echo -e "    OFFICE_SUITE:               ${OFFICE_SUITE:-collabora}"
  echo ""
  
  echo -e "  ${BOLD}Features${NC}"
  echo -e "    SMTP_ENABLED:               ${SMTP_ENABLED:-false}"
  echo -e "    LDAP_ENABLED:               ${LDAP_ENABLED:-false}"
  echo -e "    CLAMAV_ENABLED:             ${CLAMAV_ENABLED:-false}"
  echo -e "    SEAFDAV_ENABLED:            ${SEAFDAV_ENABLED:-false}"
  echo -e "    GC_ENABLED:                 ${GC_ENABLED:-true}"
  echo -e "    BACKUP_ENABLED:             ${BACKUP_ENABLED:-false}"
  echo -e "    MULTI_BACKEND_ENABLED:      ${MULTI_BACKEND_ENABLED:-false}"
  echo ""
  
  if [[ "$show_secrets" == "true" ]]; then
    echo -e "  ${BOLD}Secrets${NC}"
    echo -e "    JWT_PRIVATE_KEY:            ${JWT_PRIVATE_KEY:-[not set]}"
    echo -e "    REDIS_PASSWORD:             ${DIM}$([ -n "${REDIS_PASSWORD:-}" ] && echo "[set]" || echo "[not set]")${NC}"
    echo -e "    SMTP_PASSWORD:              ${DIM}$([ -n "${SMTP_PASSWORD:-}" ] && echo "[set]" || echo "[not set]")${NC}"
    [[ -n "${LDAP_BIND_PASSWORD:-}" ]] && echo -e "    LDAP_BIND_PASSWORD:         ${DIM}[set]${NC}"
    echo ""
  fi
}

# --- Main Config Menu ---
# --- Config: Portainer integration -------------------------------------------
_cfg_section_portainer() {
  _cfg_header "Portainer Integration"

  local current="${PORTAINER_MANAGED:-false}"

  echo -e "  ${DIM}Current:${NC} PORTAINER_MANAGED=${current}"
  if [[ "$current" == "true" ]]; then
    echo -e "  ${DIM}Webhook:${NC} ${PORTAINER_STACK_WEBHOOK:-${YELLOW}not set${NC}}"
    echo -e "  ${DIM}Git port:${NC} ${CONFIG_GIT_PORT:-9418}"
    if systemctl is-active --quiet seafile-config-server 2>/dev/null; then
      echo -e "  ${DIM}Git server:${NC} ${GREEN}running${NC}"
    else
      echo -e "  ${DIM}Git server:${NC} ${RED}not running${NC}"
    fi
  else
    echo -e "  ${DIM}Portainer Agent is installed for container monitoring.${NC}"
    echo -e "  ${DIM}Enable Portainer management to have Portainer control${NC}"
    echo -e "  ${DIM}the stack lifecycle (deploy/redeploy).${NC}"
  fi
  echo ""

  echo -e "    ${BOLD}1${NC}  $([ "$current" == "true" ] && echo "Disable" || echo "Enable") Portainer management"
  if [[ "$current" == "true" ]]; then
    echo -e "    ${BOLD}2${NC}  Set webhook URL"
    echo -e "    ${BOLD}3${NC}  Set git server port"
  fi
  echo -e "    ${BOLD}b${NC}  Back"
  echo ""
  read -r -p "  Select: " sel

  case "$sel" in
    1)
      local changed=false
      if [[ "$current" == "true" ]]; then
        PORTAINER_MANAGED="false"
        changed=true
        echo ""
        echo -e "  ${DIM}Portainer management will be disabled.${NC}"
        echo -e "  ${DIM}Docker Compose on this host will manage the stack.${NC}"
      else
        PORTAINER_MANAGED="true"
        changed=true
        echo ""
        echo -e "  ${DIM}Portainer management will be enabled.${NC}"
        echo -e "  ${DIM}The config git server will start automatically.${NC}"
        echo ""
        echo -e "  ${BOLD}To complete setup:${NC}"
        echo -e "  ${DIM}1. In Portainer: Stacks → Add Stack → Repository${NC}"
        echo -e "  ${DIM}2. Set URL: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${CONFIG_GIT_PORT:-9418}/${NC}"
        echo -e "  ${DIM}3. Enable webhook, copy the URL${NC}"
        echo -e "  ${DIM}4. Run: seafile config portainer → option 2 to set the webhook URL${NC}"

        if [[ -z "${PORTAINER_STACK_WEBHOOK:-}" ]]; then
          echo ""
          echo -ne "  ${BOLD}Portainer webhook URL${NC} ${DIM}(paste or press Enter to skip):${NC} "
          local _webhook=""
          read -r _webhook
          if [[ -n "$_webhook" ]]; then
            PORTAINER_STACK_WEBHOOK="$_webhook"
          fi
        fi
      fi

      if [[ "$changed" == "true" ]]; then
        _cfg_save_var PORTAINER_MANAGED
        [[ -n "${PORTAINER_STACK_WEBHOOK:-}" ]] && _cfg_save_var PORTAINER_STACK_WEBHOOK
        ok "Portainer configuration saved."
        _cfg_offer_update
      fi
      ;;
    2)
      if [[ "$current" == "true" ]]; then
        echo ""
        echo -ne "  ${BOLD}Portainer webhook URL:${NC} "
        local _webhook=""
        read -r _webhook
        if [[ -n "$_webhook" ]]; then
          PORTAINER_STACK_WEBHOOK="$_webhook"
          _cfg_save_var PORTAINER_STACK_WEBHOOK
          ok "Webhook URL saved."
        else
          echo -e "  ${DIM}No change.${NC}"
        fi
      fi
      ;;
    3)
      if [[ "$current" == "true" ]]; then
        local orig="${CONFIG_GIT_PORT:-9418}"
        _cfg_input CONFIG_GIT_PORT "Git server port"
        if [[ "${CONFIG_GIT_PORT}" != "$orig" ]]; then
          _cfg_save_var CONFIG_GIT_PORT
          ok "Git server port saved. Restart the service: sudo systemctl restart seafile-config-server"
        fi
      fi
      ;;
  esac
}

_cfg_main_menu() {
  while true; do
    _cfg_rule
    echo -e "  ${BOLD}Configuration Editor${NC}"
    echo ""
    echo -e "  ${DIM}Current deployment:${NC}"
    echo -e "    Hostname:   ${CYAN}${SEAFILE_SERVER_HOSTNAME:-not set}${NC}"
    echo -e "    Storage:    ${CYAN}${STORAGE_TYPE:-nfs}${NC} → ${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
    echo -e "    Database:   ${CYAN}${DB_INTERNAL:-true}${NC}"
    echo -e "    Office:     ${CYAN}${OFFICE_SUITE:-collabora}${NC}"
    _cfg_rule
    
    echo -e "    ${GREEN}${BOLD}1${NC}   Core settings          ${DIM}hostname, admin email${NC}"
    echo -e "    ${CYAN}${BOLD}2${NC}   Storage                ${DIM}NFS, SMB, migration${NC}"
    echo -e "    ${YELLOW}${BOLD}3${NC}   Database               ${DIM}bundled or external${NC}"
    echo -e "    ${PURPLE}${BOLD}4${NC}   Reverse proxy          ${DIM}nginx, traefik, caddy${NC}"
    echo -e "    ${GREEN}${BOLD}5${NC}   Office suite           ${DIM}Collabora, OnlyOffice${NC}"
    echo -e "    ${CYAN}${BOLD}6${NC}   Email / SMTP"
    echo -e "    ${YELLOW}${BOLD}7${NC}   LDAP / Active Directory"
    echo -e "    ${PURPLE}${BOLD}8${NC}   Optional features      ${DIM}ClamAV, WebDAV, etc.${NC}"
    echo -e "    ${GREEN}${BOLD}9${NC}   Portainer integration  ${DIM}$([ "${PORTAINER_MANAGED:-false}" == "true" ] && echo "${GREEN}enabled${NC}" || echo "${DIM}disabled${NC}")${NC}"
    echo ""
    echo -e "    ${BOLD}10${NC}  Open editor (nano)"
    echo -e "    ${BOLD}11${NC}  Show full config"
    echo -e "    ${DIM} 0${NC}  ${DIM}Back${NC}"
    echo ""
    
    read -r -p "  Select [0-11]: " sel
    
    case "$sel" in
      1) _cfg_section_core ;;
      2) _cfg_section_storage ;;
      3) _cfg_section_database ;;
      4) _cfg_section_proxy ;;
      5) _cfg_section_office ;;
      6) _cfg_section_smtp ;;
      7) _cfg_section_ldap ;;
      8) _cfg_section_features ;;
      9) _cfg_section_portainer ;;
      10)
        local editor="${EDITOR:-nano}"
        "$editor" "$ENV_FILE"
        # Reload env after manual edit
        _load_env "$ENV_FILE" 2>/dev/null || true
        ;;
      11) _cfg_section_show ;;
      0) return ;;
    esac
  done
}

# --- Command: config ---------------------------------------------------------
# --- Config history -----------------------------------------------------------
_cfg_history() {
  local flag="${1:-}"
  local HISTORY_DIR="/opt/seafile/.config-history"

  if [[ ! -d "$HISTORY_DIR/.git" ]]; then
    echo ""
    echo -e "  ${YELLOW}Config history is not initialized.${NC}"
    echo -e "  ${DIM}Run ${BOLD}seafile update${NC}${DIM} or ${BOLD}seafile fix${NC}${DIM} to initialize it.${NC}"
    echo ""
    return
  fi

  cd "$HISTORY_DIR" || return

  case "$flag" in
    --all)
      heading "Config History (all)"
      echo ""
      git log --format="  %C(dim)%h%C(reset)  %C(bold)%s%C(reset)" 2>/dev/null
      echo ""
      ;;
    --diff)
      heading "Config Changes (last commit)"
      echo ""
      if git log --oneline -1 >/dev/null 2>&1; then
        git diff HEAD~1 HEAD --stat 2>/dev/null || echo -e "  ${DIM}No previous commit to compare.${NC}"
        echo ""
        git diff HEAD~1 HEAD -- .env 2>/dev/null || true
      else
        echo -e "  ${DIM}Only one commit in history — nothing to diff.${NC}"
      fi

      # Show GitOps divergence if applicable
      if [[ "${GITOPS_INTEGRATION:-false}" == "true" && -f "${GITOPS_CLONE_PATH:-/opt/seafile-gitops}/.env" ]]; then
        echo ""
        echo -e "  ${BOLD}GitOps divergence:${NC}"
        if diff -q "${GITOPS_CLONE_PATH}/.env" /opt/seafile/.env >/dev/null 2>&1; then
          echo -e "  ${GREEN}  Local .env matches GitOps repo.${NC}"
        else
          echo -e "  ${YELLOW}  Local .env differs from GitOps repo:${NC}"
          diff --color "${GITOPS_CLONE_PATH}/.env" /opt/seafile/.env 2>/dev/null | head -30 || true
        fi
      fi
      echo ""
      ;;
    --reset)
      heading "Reset Config History"
      echo ""
      echo -e "  ${YELLOW}This will discard all history and start fresh with the current state.${NC}"
      echo ""
      echo -ne "  ${BOLD}Are you sure? [y/N]:${NC} "
      local confirm
      read -r confirm
      if [[ "${confirm,,}" == "y" ]]; then
        rm -rf "$HISTORY_DIR"
        mkdir -p "$HISTORY_DIR"
        cd "$HISTORY_DIR"
        git init --quiet
        git config user.email "seafile-deploy@localhost"
        git config user.name "seafile-deploy"
        cp /opt/seafile/.env "$HISTORY_DIR/.env" 2>/dev/null || true
        [[ -f /opt/seafile/docker-compose.yml ]] && cp /opt/seafile/docker-compose.yml "$HISTORY_DIR/docker-compose.yml" 2>/dev/null || true
        [[ -f /opt/seafile-config-fixes.sh ]] && cp /opt/seafile-config-fixes.sh "$HISTORY_DIR/seafile-config-fixes.sh" 2>/dev/null || true
        [[ -f /opt/update.sh ]] && cp /opt/update.sh "$HISTORY_DIR/update.sh" 2>/dev/null || true
        git add -A && git commit -m "History reset — current state" --quiet 2>/dev/null
        git update-server-info 2>/dev/null || true
        ok "Config history reset. Current state is the only entry."
      else
        echo -e "  ${DIM}Cancelled.${NC}"
      fi
      echo ""
      ;;
    *)
      local retain="${CONFIG_HISTORY_RETAIN:-50}"
      heading "Config History (last ${retain} changes)"
      echo ""
      local count
      count=$(git rev-list --count HEAD 2>/dev/null || echo "0")
      if [[ "$count" == "0" ]]; then
        echo -e "  ${DIM}No history recorded yet.${NC}"
      else
        git log -n "$retain" --format="  %C(dim)%h%C(reset)  %C(bold)%s%C(reset)" 2>/dev/null
        echo ""
        if [[ "$count" -gt "$retain" ]]; then
          echo -e "  ${DIM}Showing ${retain} of ${count} entries. Use ${BOLD}seafile config history --all${NC}${DIM} to see all.${NC}"
        fi
      fi
      echo ""
      echo -e "  ${DIM}Commands:${NC}"
      echo -e "  ${DIM}  seafile config history --diff   Show last change detail${NC}"
      echo -e "  ${DIM}  seafile config history --all    Show full history${NC}"
      echo -e "  ${DIM}  seafile config history --reset  Discard history, start fresh${NC}"
      echo -e "  ${DIM}  seafile config rollback         Revert to previous config${NC}"
      echo ""
      ;;
  esac
}

_cfg_rollback() {
  local HISTORY_DIR="/opt/seafile/.config-history"

  if [[ ! -d "$HISTORY_DIR/.git" ]]; then
    echo ""
    echo -e "  ${YELLOW}Config history is not initialized — cannot rollback.${NC}"
    echo ""
    return
  fi

  cd "$HISTORY_DIR" || return

  local count
  count=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  if [[ "$count" -lt 2 ]]; then
    echo ""
    echo -e "  ${YELLOW}Only one entry in history — nothing to roll back to.${NC}"
    echo ""
    return
  fi

  heading "Config Rollback"
  echo ""
  echo -e "  ${BOLD}Current:${NC}"
  git log -1 --format="    %h  %s" 2>/dev/null
  echo ""
  echo -e "  ${BOLD}Roll back to:${NC}"
  git log -1 --skip=1 --format="    %h  %s" 2>/dev/null
  echo ""
  echo -e "  ${BOLD}Changes that will be reverted:${NC}"
  git diff HEAD~1 HEAD --stat -- .env 2>/dev/null
  echo ""
  echo -ne "  ${BOLD}Proceed? [y/N]:${NC} "
  local confirm
  read -r confirm
  if [[ "${confirm,,}" == "y" ]]; then
    # Restore .env from previous commit
    git checkout HEAD~1 -- .env 2>/dev/null
    cp "$HISTORY_DIR/.env" /opt/seafile/.env
    chmod 600 /opt/seafile/.env
    git add -A && git commit -m "$(date '+%Y-%m-%d %H:%M:%S') Rolled back to previous config" --quiet 2>/dev/null
    git update-server-info 2>/dev/null || true
    ok ".env rolled back. Run ${BOLD}seafile update${NC} to apply changes."
  else
    echo -e "  ${DIM}Cancelled.${NC}"
  fi
  echo ""
}

cmd_config() {
  local subcommand="${1:-}"
  
  case "$subcommand" in
    "")
      _cfg_main_menu
      ;;
    core)
      _cfg_section_core
      ;;
    storage)
      local flag="${2:-}"
      case "$flag" in
        --status) _storage_migration_status ;;
        --cutover) _storage_migration_cutover ;;
        --cancel) _storage_migration_cancel ;;
        *) _cfg_section_storage ;;
      esac
      ;;
    database|db)
      _cfg_section_database
      ;;
    proxy)
      _cfg_section_proxy
      ;;
    smtp)
      _cfg_section_smtp
      ;;
    ldap)
      _cfg_section_ldap
      ;;
    office)
      _cfg_section_office
      ;;
    features)
      _cfg_section_features
      ;;
    portainer)
      _cfg_section_portainer
      ;;
    show)
      local flag="${2:-}"
      [[ "$flag" == "--secrets" ]] && _cfg_section_show true || _cfg_section_show false
      ;;
    edit)
      local editor="${EDITOR:-nano}"
      "$editor" "$ENV_FILE"
      ;;
    history)
      _cfg_history "${2:-}"
      ;;
    rollback)
      _cfg_rollback
      ;;
    *)
      echo -e "  ${DIM}Unknown config subcommand: $subcommand${NC}"
      echo -e "  ${DIM}Available: core, storage, database, proxy, smtp, ldap, office, features, portainer, show, edit, history, rollback${NC}"
      ;;
  esac
}

# --- Command: metadata --------------------------------------------------------
cmd_metadata() {
  local flag="${1:-}"

  if [[ "$flag" != "--enable-all" ]]; then
    heading "Metadata / Extended Properties"
    echo ""
    echo -e "  ${DIM}Usage:${NC}"
    echo -e "    ${BOLD}seafile metadata --enable-all${NC}   Enable Extended Properties on all libraries"
    echo ""
    echo -e "  ${DIM}Extended Properties (metadata indexing) must be enabled per library${NC}"
    echo -e "  ${DIM}for features like AI search, tagging, and advanced file info to work.${NC}"
    echo ""
    return
  fi

  heading "Enable Extended Properties — All Libraries"

  # Build the Seafile URL
  local base_url="${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}"
  local caddy_port="${CADDY_PORT:-7080}"
  local host_hdr="${SEAFILE_SERVER_HOSTNAME:-localhost}"
  # Use localhost to avoid DNS/SSL issues for API calls from the host
  local api_base="http://localhost:${caddy_port}"

  # Get admin credentials
  local admin_email="${INIT_SEAFILE_ADMIN_EMAIL:-}"
  if [[ -z "$admin_email" ]]; then
    echo -ne "  ${BOLD}Admin email:${NC} "
    read -r admin_email
  fi

  echo -ne "  ${BOLD}Admin password:${NC} "
  read -rs admin_pass
  echo ""

  if [[ -z "$admin_pass" ]]; then
    err "Password required."
    return
  fi

  # Get auth token
  echo -e "  ${DIM}Authenticating...${NC}"
  local token_response
  token_response=$(curl -sf -H "Host: ${host_hdr}" \
    -d "username=${admin_email}&password=${admin_pass}" \
    "${api_base}/api2/auth-token/" 2>/dev/null || true)

  if [[ -z "$token_response" ]] || ! echo "$token_response" | python3 -c "import sys,json; json.load(sys.stdin)['token']" &>/dev/null; then
    err "Authentication failed. Check email and password."
    return
  fi

  local token
  token=$(echo "$token_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

  # List all repos
  echo -e "  ${DIM}Fetching libraries...${NC}"
  local repos_json
  repos_json=$(curl -sf -H "Host: ${host_hdr}" \
    -H "Authorization: Token ${token}" \
    "${api_base}/api/v2.1/repos/?type=mine" 2>/dev/null || true)

  if [[ -z "$repos_json" ]]; then
    # Try admin endpoint
    repos_json=$(curl -sf -H "Host: ${host_hdr}" \
      -H "Authorization: Token ${token}" \
      "${api_base}/api/v2.1/repos/?type=admin" 2>/dev/null || true)
  fi

  if [[ -z "$repos_json" ]]; then
    err "Failed to fetch libraries. Is Seafile running?"
    return
  fi

  local repo_ids
  repo_ids=$(echo "$repos_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
repos = data.get('repos', data) if isinstance(data, dict) else data
for r in repos:
    print(r['id'])
" 2>/dev/null || true)

  if [[ -z "$repo_ids" ]]; then
    echo -e "  ${DIM}No libraries found.${NC}"
    return
  fi

  local count=0 enabled=0 failed=0
  while IFS= read -r repo_id; do
    [[ -z "$repo_id" ]] && continue
    ((count++))
    local result
    result=$(curl -sf -X PUT -H "Host: ${host_hdr}" \
      -H "Authorization: Token ${token}" \
      -H "Content-Type: application/json" \
      -d '{"enabled": true}' \
      "${api_base}/api/v2.1/repos/${repo_id}/metadata/" 2>/dev/null || true)

    if [[ -n "$result" ]]; then
      ((enabled++))
    else
      ((failed++))
    fi
  done <<< "$repo_ids"

  echo ""
  if [[ $enabled -gt 0 ]]; then
    ok "Extended Properties enabled on ${enabled} of ${count} libraries."
  fi
  if [[ $failed -gt 0 ]]; then
    warn "${failed} libraries could not be updated (may already be enabled or system libraries)."
  fi
  echo ""
}

# --- Command: proxy-config ---------------------------------------------------
cmd_proxy_config() {
  local host_ip
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  local caddy_port="${CADDY_PORT:-7080}"
  local proto="${SEAFILE_SERVER_PROTOCOL:-https}"

  heading "Reverse Proxy Configuration"

  case "${PROXY_TYPE:-nginx}" in
    caddy-bundled)
      echo -e "  ${GREEN}Caddy-bundled mode — no external proxy config needed.${NC}"
      echo -e "  ${DIM}Caddy handles SSL automatically via Let's Encrypt.${NC}"
      echo ""
      ;;
    traefik)
      echo -e "  ${GREEN}Traefik mode — routing handled via Docker labels.${NC}"
      echo -e "  ${DIM}Labels are in docker-compose.yml, configured from .env.${NC}"
      echo ""
      ;;
    nginx|caddy-external|haproxy)
      echo -e "  ${DIM}Proxy type: ${BOLD}${PROXY_TYPE:-nginx}${NC}"
      echo -e "  ${DIM}Forward to: ${BOLD}${host_ip}:${caddy_port}${NC}"
      echo ""

      if [[ "${PROXY_TYPE:-nginx}" == "nginx" ]]; then
        echo -e "  ${BOLD}Nginx Proxy Manager — Advanced tab config:${NC}"
        echo -e "  ${DIM}Copy everything below and paste into NPM → Proxy Host → Advanced tab${NC}"
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        cat << NPMCONF

location / {
    proxy_pass http://${host_ip}:${caddy_port};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto ${proto};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 1200s;
    proxy_buffering off;
    client_max_body_size 0;
}

NPMCONF
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${DIM}NPM Details tab settings:${NC}"
        echo -e "  ${DIM}  Domain:       ${SEAFILE_SERVER_HOSTNAME:-your-domain}${NC}"
        echo -e "  ${DIM}  Scheme:       http${NC}"
        echo -e "  ${DIM}  Forward IP:   ${host_ip}${NC}"
        echo -e "  ${DIM}  Forward Port: ${caddy_port}${NC}"
        echo -e "  ${DIM}  Websockets:   enabled${NC}"
        echo ""
      else
        echo -e "  ${DIM}Forward all traffic (HTTP + WebSocket) to ${host_ip}:${caddy_port}${NC}"
        echo -e "  ${DIM}Required headers: Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto: ${proto}${NC}"
        echo -e "  ${DIM}Required: WebSocket upgrade support, no upload size limit, 1200s read timeout${NC}"
        echo ""
      fi
      ;;
  esac
}

# --- Command: fix ------------------------------------------------------------
cmd_fix() {
  if [[ ! -f "$FIXES_SCRIPT" ]]; then
    err "seafile-config-fixes.sh not found at $FIXES_SCRIPT"
    echo "  Paste the contents of seafile-config-fixes.sh from the repo into that path."
    exit 1
  fi
  if [[ $EUID -ne 0 ]]; then
    sudo bash "$FIXES_SCRIPT"
  else
    bash "$FIXES_SCRIPT"
  fi
}

# --- Command: backup ---------------------------------------------------------
cmd_backup() {
  heading "Storage Backup Status"

  # Local storage has no network backup — DR is not available
  if [[ "${STORAGE_TYPE:-nfs}" == "local" ]]; then
    echo ""
    echo -e "  ${YELLOW}Disaster recovery backups are not available with local storage.${NC}"
    echo ""
    echo -e "  ${DIM}Your data is stored on this machine's disk only. If this VM is${NC}"
    echo -e "  ${DIM}lost, your data cannot be recovered.${NC}"
    echo ""
    echo -e "  ${DIM}To enable network storage backups and disaster recovery:${NC}"
    echo -e "  ${DIM}  1. Run: ${BOLD}seafile config storage${NC}"
    echo -e "  ${DIM}  2. Migrate to NFS, SMB, GlusterFS, or iSCSI${NC}"
    echo -e "  ${DIM}  3. See the README → Disaster Recovery section${NC}"
    echo ""
    return
  fi

  local nfs_vol="${SEAFILE_VOLUME:-}"
  if [[ -z "$nfs_vol" ]]; then
    warn "SEAFILE_VOLUME not set in $ENV_FILE — cannot check storage backup paths."
    return
  fi

  # .env backup
  local nfs_env="$nfs_vol/.env"
  if [[ -f "$nfs_env" ]]; then
    local age
    age=$(find "$nfs_env" -newer "$ENV_FILE" 2>/dev/null | wc -l)
    if [[ "$age" -gt 0 ]]; then
      ok ".env backup is ${BOLD}current${NC}"
    else
      warn ".env backup may be ${BOLD}stale${NC} (local file is newer)"
    fi
    echo -e "  ${DIM}  Last modified: $(stat -c '%y' "$nfs_env" 2>/dev/null | cut -d. -f1)${NC}"
  else
    err ".env backup not found at $nfs_env"
    echo -e "  ${DIM}  Is seafile-env-sync running? Check: systemctl status seafile-env-sync${NC}"
  fi

  # seafile-config-fixes.sh backup
  local nfs_fixes="$nfs_vol/seafile-config-fixes.sh"
  if [[ -f "$nfs_fixes" ]]; then
    ok "seafile-config-fixes.sh backup present"
    echo -e "  ${DIM}  Last modified: $(stat -c '%y' "$nfs_fixes" 2>/dev/null | cut -d. -f1)${NC}"
  else
    warn "seafile-config-fixes.sh not yet backed up to storage"
    echo -e "  ${DIM}  Run seafile-config-fixes.sh at least once to create the backup.${NC}"
  fi

  # update.sh backup
  local nfs_update="$nfs_vol/update.sh"
  if [[ -f "$nfs_update" ]]; then
    ok "update.sh backup present"
  else
    warn "update.sh backup not found at $nfs_update"
  fi

  echo ""
  # Trigger a sync by touching .env (seafile-env-sync watches for inotify events)
  echo -e "  ${DIM}Triggering seafile-env-sync...${NC}"
  systemctl is-active --quiet seafile-env-sync 2>/dev/null && \
    { touch "$ENV_FILE" && ok "Sync triggered." ; } || \
    warn "seafile-env-sync is not running — start it: systemctl start seafile-env-sync"
  echo ""
}

# --- Command: version --------------------------------------------------------
# --- Command: secrets ---------------------------------------------------------
cmd_secrets() {
  local secrets_file="/opt/seafile/.secrets"

  if [[ ! -f "$secrets_file" ]]; then
    echo -e "\n  ${DIM}No secrets file found at ${secrets_file}.${NC}"
    echo -e "  ${DIM}Secrets are recorded during initial setup and secret generation.${NC}\n"
    return
  fi

  heading "Generated Secrets Reference"

  echo -e "  ${DIM}This file records every auto-generated credential with timestamps.${NC}"
  echo -e "  ${DIM}It is not used by any script — it exists for troubleshooting only.${NC}"
  echo -e "  ${DIM}Location: ${secrets_file}${NC}"
  echo ""
  rule

  # Display with masked values by default
  if [[ "${1:-}" == "--show" ]]; then
    cat "$secrets_file"
  else
    while IFS= read -r line; do
      if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
        echo "$line"
        continue
      fi
      # Mask the value portion: "2026-03-12 01:11:05  KEY=value" → "2026-03-12 01:11:05  KEY=[set]"
      local timestamp="${line%%  *}"
      local kv="${line#*  }"
      local key="${kv%%=*}"
      echo -e "  ${DIM}${timestamp}${NC}  ${BOLD}${key}${NC}=${DIM}[set]${NC}"
    done < "$secrets_file"
    echo ""
    echo -e "  ${DIM}Values are hidden. To show plaintext:${NC}"
    echo -e "    ${BOLD}seafile secrets --show${NC}"
  fi
  echo ""
}

# --- Command: migrate ---------------------------------------------------------
# Post-install migration: import data from an existing Seafile instance into
# a running seafile-deploy stack. Stops the stack, imports, restarts.
# ---------------------------------------------------------------------------

# DB import helper (same logic as shared-lib _import_db_dumps)
_cli_import_db_dumps() {
  local dump_dir="$1" root_pass="$2" db_method="${3:-internal}"
  local _db_host="${SEAFILE_MYSQL_DB_HOST:-seafile-db}"
  local _db_port="${SEAFILE_MYSQL_DB_PORT:-3306}"

  for db in \
      "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
      "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
      "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

    local dump_file=""
    dump_file=$(ls -t "${dump_dir}/${db}_"*.sql.gz 2>/dev/null | head -1 || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls -t "${dump_dir}/${db}_"*.sql 2>/dev/null | head -1 || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls "${dump_dir}/${db}.sql.gz" 2>/dev/null || true)
    [[ -z "$dump_file" ]] && dump_file=$(ls "${dump_dir}/${db}.sql" 2>/dev/null || true)

    if [[ -z "$dump_file" ]]; then
      warn "No dump found for ${db} — skipping."
      continue
    fi

    echo -e "  ${DIM}Importing ${db} from $(basename "$dump_file")...${NC}"

    # Ensure target database exists
    if [[ "$db_method" == "internal" ]]; then
      docker exec -e MYSQL_PWD="${root_pass}" seafile-db mysql -u root \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    else
      MYSQL_PWD="${root_pass}" mysql -h "$_db_host" -P "$_db_port" -u root \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    fi

    local _ok=false
    if [[ "$dump_file" == *.gz ]]; then
      if [[ "$db_method" == "internal" ]]; then
        gunzip -c "$dump_file" | docker exec -i -e MYSQL_PWD="${root_pass}" seafile-db \
          mysql -u root "$db" 2>/dev/null && _ok=true
      else
        gunzip -c "$dump_file" | MYSQL_PWD="${root_pass}" mysql -h "$_db_host" -P "$_db_port" \
          -u root "$db" 2>/dev/null && _ok=true
      fi
    else
      if [[ "$db_method" == "internal" ]]; then
        docker exec -i -e MYSQL_PWD="${root_pass}" seafile-db mysql -u root "$db" \
          < "$dump_file" 2>/dev/null && _ok=true
      else
        MYSQL_PWD="${root_pass}" mysql -h "$_db_host" -P "$_db_port" -u root "$db" \
          < "$dump_file" 2>/dev/null && _ok=true
      fi
    fi

    if [[ "$_ok" == "true" ]]; then
      ok "${db} imported."
    else
      err "Failed to import ${db}."
    fi
  done
}

cmd_migrate() {
  heading "Migrate / Import Data"

  echo -e "  ${YELLOW}This will stop the running Seafile stack, import data from an${NC}"
  echo -e "  ${YELLOW}existing instance, then restart with the imported data.${NC}"
  echo ""
  echo -e "  ${DIM}Your current .env settings (hostname, proxy, features) will be${NC}"
  echo -e "  ${DIM}preserved. Only file data, databases, and user accounts are imported.${NC}"
  echo ""
  rule
  echo ""

  echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Adopt in place${NC}"
  echo -e "     ${DIM}Data and database already exist on the current volume.${NC}"
  echo -e "     ${DIM}Just restart and let config-fixes take over.${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  2  ${NC}${BOLD}Import from prepared backup${NC}"
  echo -e "     ${DIM}Database dumps (.sql.gz) and data directory on this machine.${NC}"
  echo ""
  echo -e "  ${YELLOW}${BOLD}  3  ${NC}${BOLD}Import from remote server (SSH)${NC}"
  echo -e "     ${DIM}Dump and copy from a running Seafile server over SSH.${NC}"
  echo ""
  echo -e "  ${DIM}  0  Cancel${NC}"
  echo ""

  local _choice
  while true; do
    read -r -p "  Select [0-3]: " _choice
    case "$_choice" in 0|1|2|3) break ;; *) echo -e "  ${DIM}Enter 0, 1, 2, or 3.${NC}" ;; esac
  done
  [[ "$_choice" == "0" ]] && return

  # Get root password for DB operations
  local _root_pass=""
  local _secrets_file="/opt/seafile/.secrets"
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    # Try to find root password from secrets file
    if [[ -f "$_secrets_file" ]]; then
      _root_pass=$(grep 'INIT_SEAFILE_MYSQL_ROOT_PASSWORD=' "$_secrets_file" | tail -1 | cut -d= -f2-)
    fi
    # Try docker inspect as fallback
    if [[ -z "$_root_pass" ]]; then
      _root_pass=$(docker inspect seafile-db --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep MYSQL_ROOT_PASSWORD | cut -d= -f2)
    fi
    if [[ -z "$_root_pass" ]]; then
      echo -ne "  ${BOLD}Database root password${NC}: "
      read -rs _root_pass
      echo ""
    fi
  fi

  local _sf_vol="${SEAFILE_VOLUME:-/opt/seafile-data}"

  case "$_choice" in
    # ── Adopt in place ────────────────────────────────────────────────────
    1)
      heading "Adopt in place"

      # Extract SECRET_KEY before restart
      local _key=""
      for _kf in "${_sf_vol}/seafile/conf/seahub_settings.py" "${_sf_vol}/conf/seahub_settings.py"; do
        if [[ -f "$_kf" ]]; then
          _key=$(grep "^SECRET_KEY" "$_kf" 2>/dev/null | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
          [[ -n "$_key" ]] && break
        fi
      done

      if [[ -n "$_key" ]]; then
        ok "SECRET_KEY found — sessions will be preserved."
      else
        warn "No SECRET_KEY found — a new one will be generated."
      fi

      echo ""
      echo -e "  ${DIM}Restarting stack with config-fixes...${NC}"
      if [[ -f "/opt/seafile-config-fixes.sh" ]]; then
        bash /opt/seafile-config-fixes.sh --yes
        ok "Stack restarted with seafile-deploy configuration."
      else
        err "config-fixes not found at /opt/seafile-config-fixes.sh"
      fi
      ;;

    # ── Prepared backup ───────────────────────────────────────────────────
    2)
      heading "Import from prepared backup"

      # Collect dump directory
      local _dump_dir=""
      while true; do
        echo -ne "  ${BOLD}Database dumps directory${NC}: "
        read -r _dump_dir
        _dump_dir="${_dump_dir%/}"
        if [[ -d "$_dump_dir" ]]; then
          local _cnt=$(ls "$_dump_dir"/*.sql* 2>/dev/null | wc -l)
          echo -e "  ${DIM}Found ${_cnt} dump file(s).${NC}"
          break
        fi
        echo -e "  ${RED}Directory not found.${NC}"
      done

      # Collect data directory
      local _data_dir=""
      echo ""
      echo -ne "  ${BOLD}Seafile data directory${NC} (containing seafile-data/): "
      read -r _data_dir
      _data_dir="${_data_dir%/}"

      # Confirm
      echo ""
      echo -e "  ${YELLOW}This will stop the stack and replace the database.${NC}"
      echo -ne "  ${BOLD}Continue? [y/N]:${NC} "
      read -r _confirm
      [[ "${_confirm,,}" != "y" ]] && echo -e "  ${DIM}Cancelled.${NC}" && return

      # Stop stack
      echo ""
      echo -e "  ${DIM}Stopping stack...${NC}"
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down 2>/dev/null

      # Start DB only
      if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
        echo -e "  ${DIM}Starting database...${NC}"
        _compute_compose_profiles
        COMPOSE_PROFILES="$_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
        sleep 10
      fi

      # Import DB
      echo -e "  ${DIM}Importing databases...${NC}"
      _cli_import_db_dumps "$_dump_dir" "$_root_pass" \
        "$([[ "${DB_INTERNAL:-true}" == "true" ]] && echo "internal" || echo "external")"

      # Copy data
      if [[ -n "$_data_dir" && -d "${_data_dir}/seafile-data" ]]; then
        echo -e "  ${DIM}Copying file data...${NC}"
        rsync -a --info=progress2 "${_data_dir}/seafile-data/" "${_sf_vol}/seafile-data/"
        ok "File data copied."
      fi

      # Copy avatars
      for _av in "${_data_dir}/seafile/seahub-data/avatars" "${_data_dir}/seahub-data/avatars"; do
        if [[ -d "$_av" ]]; then
          mkdir -p "${_sf_vol}/seafile/seahub-data/avatars"
          rsync -a "$_av/" "${_sf_vol}/seafile/seahub-data/avatars/"
          ok "Avatars copied."
          break
        fi
      done

      # SECRET_KEY
      local _conf_dir=""
      [[ -f "${_data_dir}/seafile/conf/seahub_settings.py" ]] && _conf_dir="${_data_dir}/seafile/conf"
      [[ -f "${_data_dir}/conf/seahub_settings.py" ]] && _conf_dir="${_data_dir}/conf"
      if [[ -n "$_conf_dir" ]]; then
        local _key=$(grep "^SECRET_KEY" "${_conf_dir}/seahub_settings.py" 2>/dev/null | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
        if [[ -n "$_key" ]]; then
          mkdir -p "${_sf_vol}/seafile/conf"
          echo "SECRET_KEY = \"${_key}\"" > "${_sf_vol}/seafile/conf/seahub_settings.py"
          ok "SECRET_KEY preserved."
        fi
      fi

      # Restart with config-fixes
      echo -e "  ${DIM}Applying configuration and starting stack...${NC}"
      if [[ -f "/opt/seafile-config-fixes.sh" ]]; then
        bash /opt/seafile-config-fixes.sh --yes
      fi
      _compute_compose_profiles
      COMPOSE_PROFILES="$_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1
      ok "Migration complete. Run: seafile ping"
      ;;

    # ── SSH import ────────────────────────────────────────────────────────
    3)
      heading "Import from remote server (SSH)"

      # Collect SSH details
      local _ssh_host _ssh_user _ssh_port
      echo -ne "  ${BOLD}SSH host${NC}: "
      read -r _ssh_host
      echo -ne "  ${BOLD}SSH user${NC} [root]: "
      read -r _ssh_user; _ssh_user="${_ssh_user:-root}"
      echo -ne "  ${BOLD}SSH port${NC} [22]: "
      read -r _ssh_port; _ssh_port="${_ssh_port:-22}"

      local _ssh_cmd="ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${_ssh_port} ${_ssh_user}@${_ssh_host}"

      # Test connection
      echo ""
      echo -e "  ${DIM}Testing SSH connection...${NC}"
      if ! $_ssh_cmd "echo ok" &>/dev/null; then
        err "Cannot connect to ${_ssh_user}@${_ssh_host}:${_ssh_port}"
        echo -e "  ${DIM}Ensure SSH key auth is configured:${NC}"
        echo -e "    ${DIM}ssh-copy-id -p ${_ssh_port} ${_ssh_user}@${_ssh_host}${NC}"
        return 1
      fi
      ok "Connected."

      # Auto-detect remote Seafile
      echo -e "  ${DIM}Detecting remote Seafile installation...${NC}"
      local _remote_data="" _remote_conf="" _remote_db_type="" _remote_db_user="" _remote_db_pass=""

      # Docker?
      _remote_data=$($_ssh_cmd "docker inspect seafile --format '{{range .Mounts}}{{if eq .Destination \"/shared\"}}{{.Source}}{{end}}{{end}}'" 2>/dev/null || true)
      if [[ -n "$_remote_data" ]]; then
        ok "Docker deployment at ${_remote_data}"
        _remote_conf="${_remote_data}/seafile/conf"
        _remote_db_type="docker"
        _remote_db_user=$($_ssh_cmd "docker exec seafile grep -oP 'user\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
        _remote_db_pass=$($_ssh_cmd "docker exec seafile grep -oP 'password\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
      else
        # Manual install
        for _tp in "/opt/seafile/conf" "/opt/seafile/seafile/conf"; do
          if $_ssh_cmd "test -f ${_tp}/seahub_settings.py" 2>/dev/null; then
            _remote_conf="$_tp"
            break
          fi
        done
        if [[ -n "$_remote_conf" ]]; then
          local _dd=$($_ssh_cmd "grep -oP 'dir\s*=\s*\K.*' ${_remote_conf}/seafile.conf 2>/dev/null | head -1" || true)
          _remote_data=$(dirname "${_dd:-/opt/seafile/seafile-data}")
          ok "Manual install at ${_remote_data}"
          _remote_db_type="local"
          _remote_db_user=$($_ssh_cmd "grep -oP 'user\s*=\s*\K.*' ${_remote_conf}/seafile.conf 2>/dev/null | head -1" || true)
          _remote_db_pass=$($_ssh_cmd "grep -oP 'password\s*=\s*\K.*' ${_remote_conf}/seafile.conf 2>/dev/null | head -1" || true)
        else
          err "Could not detect Seafile on remote server."
          return 1
        fi
      fi
      _remote_db_user="${_remote_db_user:-seafile}"

      if [[ -z "$_remote_db_pass" ]]; then
        echo -ne "  ${BOLD}Remote database password${NC}: "
        read -rs _remote_db_pass; echo ""
      fi

      local _data_size=$($_ssh_cmd "du -sh ${_remote_data}/seafile-data 2>/dev/null | cut -f1" || true)
      [[ -n "$_data_size" ]] && echo -e "  ${DIM}Remote data size: ${_data_size}${NC}"
      echo ""

      # Confirm
      echo -e "  ${YELLOW}This will stop the local stack and replace the database.${NC}"
      echo -ne "  ${BOLD}Continue? [y/N]:${NC} "
      read -r _confirm
      [[ "${_confirm,,}" != "y" ]] && echo -e "  ${DIM}Cancelled.${NC}" && return

      # Stop stack
      echo ""
      echo -e "  ${DIM}Stopping stack...${NC}"
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down 2>/dev/null

      # Start DB only
      if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
        echo -e "  ${DIM}Starting database...${NC}"
        _compute_compose_profiles
        COMPOSE_PROFILES="$_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
        sleep 10
      fi

      # Dump + import databases
      echo -e "  ${DIM}Dumping remote databases...${NC}"
      local _tmp_dumps=$(mktemp -d /tmp/seafile-cli-migrate.XXXXXX)
      chmod 700 "$_tmp_dumps"

      for _rdb in \
          "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
          "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
          "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

        echo -e "  ${DIM}  Dumping ${_rdb}...${NC}"
        case "$_remote_db_type" in
          docker)
            $_ssh_cmd "docker exec -e MYSQL_PWD='${_remote_db_pass}' seafile-db mysqldump \
              -u '${_remote_db_user}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_tmp_dumps}/${_rdb}.sql.gz"
            ;;
          *)
            $_ssh_cmd "MYSQL_PWD='${_remote_db_pass}' mysqldump \
              -u '${_remote_db_user}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_tmp_dumps}/${_rdb}.sql.gz"
            ;;
        esac

        local _sz=$(stat -c%s "${_tmp_dumps}/${_rdb}.sql.gz" 2>/dev/null || echo "0")
        if [[ "$_sz" -gt 100 ]]; then
          ok "${_rdb} dumped ($(du -h "${_tmp_dumps}/${_rdb}.sql.gz" | cut -f1))"
        else
          warn "${_rdb} dump appears empty."
        fi
      done

      echo -e "  ${DIM}Importing into local database...${NC}"
      _cli_import_db_dumps "$_tmp_dumps" "$_root_pass" \
        "$([[ "${DB_INTERNAL:-true}" == "true" ]] && echo "internal" || echo "external")"
      rm -rf "$_tmp_dumps"

      # Rsync file data
      echo -e "  ${DIM}Copying file data from remote (this may take a while)...${NC}"
      mkdir -p "${_sf_vol}/seafile-data"
      if $_ssh_cmd "test -d '${_remote_data}/seafile-data'" 2>/dev/null; then
        rsync -avz --info=progress2 \
          -e "ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${_ssh_port}" \
          "${_ssh_user}@${_ssh_host}:${_remote_data}/seafile-data/" \
          "${_sf_vol}/seafile-data/"
        ok "File data copied."
      else
        warn "Remote seafile-data not found."
      fi

      # Avatars
      for _av_remote in "${_remote_data}/seafile/seahub-data/avatars" "${_remote_data}/seahub-data/avatars"; do
        if $_ssh_cmd "test -d '${_av_remote}'" 2>/dev/null; then
          mkdir -p "${_sf_vol}/seafile/seahub-data/avatars"
          rsync -avz \
            -e "ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${_ssh_port}" \
            "${_ssh_user}@${_ssh_host}:${_av_remote}/" \
            "${_sf_vol}/seafile/seahub-data/avatars/"
          ok "Avatars copied."
          break
        fi
      done

      # SECRET_KEY
      if [[ -n "$_remote_conf" ]]; then
        local _key=$($_ssh_cmd "grep '^SECRET_KEY' '${_remote_conf}/seahub_settings.py' 2>/dev/null | head -1" 2>/dev/null || true)
        _key=$(echo "$_key" | sed "s/.*['\"]//;s/['\"].*//" | tr -d '[:space:]')
        if [[ -n "$_key" ]]; then
          mkdir -p "${_sf_vol}/seafile/conf"
          echo "SECRET_KEY = \"${_key}\"" > "${_sf_vol}/seafile/conf/seahub_settings.py"
          ok "SECRET_KEY preserved."
        fi
      fi

      # Restart with config-fixes
      echo -e "  ${DIM}Applying configuration and starting stack...${NC}"
      if [[ -f "/opt/seafile-config-fixes.sh" ]]; then
        bash /opt/seafile-config-fixes.sh --yes
      fi
      _compute_compose_profiles
      COMPOSE_PROFILES="$_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1
      ok "SSH migration complete. Run: seafile ping"
      ;;
  esac

  echo ""
}

# Helper to compute compose profiles in CLI context
_compute_compose_profiles() {
  local _p=()
  case "${OFFICE_SUITE:-collabora}" in
    onlyoffice) _p+=(onlyoffice) ;;
    none)       ;;
    *)          _p+=(collabora)  ;;
  esac
  [[ "${CLAMAV_ENABLED:-false}" == "true" ]] && _p+=(clamav)
  [[ "${DB_INTERNAL:-true}" == "true" ]] && _p+=(internal-db)
  _PROFILES=$(IFS=','; echo "${_p[*]}")
}

cmd_version() {
  heading "Image Versions"

  printf "  ${BOLD}%-28s %-36s %s${NC}\n" "Container" "Running" ".env value"
  rule

  declare -A ENV_IMAGES=(
    [seafile-caddy]="CADDY_IMAGE"
    [seafile-redis]="SEAFILE_REDIS_IMAGE"
    [seafile]="SEAFILE_IMAGE"
    [seadoc]="SEADOC_IMAGE"
    [notification-server]="NOTIFICATION_SERVER_IMAGE"
    [thumbnail-server]="THUMBNAIL_SERVER_IMAGE"
    [seafile-metadata]="MD_IMAGE"
    [seafile-collabora]="COLLABORA_IMAGE"
    [seafile-onlyoffice]="ONLYOFFICE_IMAGE"
    [seafile-db]="DB_INTERNAL_IMAGE"
    [seafile-clamav]="CLAMAV_IMAGE"
  )

  for c in "${CONTAINERS[@]}"; do
    local running env_val env_var
    running=$(docker inspect --format='{{.Config.Image}}' "$c" 2>/dev/null || echo "not running")
    env_var="${ENV_IMAGES[$c]:-}"
    env_val="${!env_var:-not set}"

    local colour="$NC"
    if [[ "$running" == "$env_val" ]]; then
      colour="$GREEN"
    elif [[ "$running" == "not running" ]]; then
      colour="$RED"
    else
      colour="$YELLOW"  # running but tag differs from .env
    fi

    printf "  %-28s ${colour}%-36s${NC} %s\n" "$(_display_name "$c")" "$running" "$env_val"
  done
  echo ""
  echo -e "  ${DIM}Yellow = container running a different tag than .env — run ${BOLD}seafile update${NC}${DIM} to reconcile.${NC}\n"
}


# --- Command: gc -------------------------------------------------------------
cmd_gc() {
  local flag="${1:-}"

  if [[ "${GC_ENABLED:-true}" != "true" && "$flag" != "--force" ]]; then
    warn "GC_ENABLED is not true in .env."
    echo -e "  ${DIM}  Set GC_ENABLED=true and re-run: seafile fix${NC}"
    echo -e "  ${DIM}  Or run manually: seafile gc --force${NC}"
    return
  fi

  if [[ "$flag" == "--status" ]]; then
    heading "Garbage Collection"
    echo -e "  ${DIM}Schedule:${NC}       ${GC_SCHEDULE:-0 3 * * 0}"
    echo -e "  ${DIM}Remove deleted:${NC} ${GC_REMOVE_DELETED:-true}"
    echo -e "  ${DIM}Dry run:${NC}        ${GC_DRY_RUN:-false}"
    if [ -f /etc/cron.d/seafile-gc ]; then
      ok "Cron installed at /etc/cron.d/seafile-gc"
    else
      warn "Cron not installed — run: seafile fix"
    fi
    if [ -f /var/log/seafile-gc.log ]; then
      echo ""
      echo -e "  ${BOLD}Last GC log entries:${NC}"
      tail -20 /var/log/seafile-gc.log | sed 's/^/  /'
    else
      echo -e "  ${DIM}  No GC log yet (/var/log/seafile-gc.log)${NC}"
    fi
    return
  fi

  if [[ "$flag" == "--dry-run" ]]; then
    heading "Garbage Collection (dry run)"
    echo -e "  ${YELLOW}!${NC}  This will show what GC would collect but NOT remove anything."
    echo ""
    docker exec seafile /scripts/gc.sh --dry-run
    return
  fi

  # Live run
  heading "Garbage Collection"
  echo -e "  ${YELLOW}!${NC}  GC briefly stops the Seafile service (~30–120s)."
  echo ""
  read -r -p "  Run GC now? [y/N] " confirm
  [[ ! "$confirm" =~ ^[yY] ]] && { echo "  Cancelled."; return; }
  echo ""

  local -a gc_flags=()
  [[ "${GC_REMOVE_DELETED:-true}" == "true" ]] && gc_flags+=("-r")
  [[ "${GC_DRY_RUN:-false}"       == "true" ]] && gc_flags+=("--dry-run")

  info "Running GC..."
  docker exec seafile /scripts/gc.sh "${gc_flags[@]}"
  echo ""
  ok "GC complete."
  echo ""
}

# --- Command: gitops ---------------------------------------------------------
cmd_gitops() {
  heading "GitOps Integration"

  local enabled="${GITOPS_INTEGRATION:-false}"
  if [[ "${enabled,,}" != "true" ]]; then
    warn "GitOps is disabled (GITOPS_INTEGRATION=false in .env)"
    echo -e "  ${DIM}See README → GitOps Integration for setup instructions.${NC}\n"
    return
  fi

  # Service status
  if systemctl is-active --quiet seafile-gitops-sync 2>/dev/null; then
    ok "seafile-gitops-sync service is ${BOLD}running${NC}"
  else
    err "seafile-gitops-sync service is ${BOLD}not running${NC}"
    echo -e "  ${DIM}Start it: sudo systemctl start seafile-gitops-sync${NC}"
  fi

  # Config summary
  echo ""
  echo -e "  ${DIM}Repo:      ${NC}${GITOPS_REPO_URL:-not set}"
  echo -e "  ${DIM}Branch:    ${NC}${GITOPS_BRANCH:-main}"
  echo -e "  ${DIM}Port:      ${NC}${GITOPS_WEBHOOK_PORT:-9002}"
  echo -e "  ${DIM}Clone at:  ${NC}${GITOPS_CLONE_PATH:-/opt/seafile-gitops}"
  if [[ -n "${PORTAINER_STACK_WEBHOOK:-}" ]]; then
    echo -e "  ${DIM}Portainer: ${NC}configured"
  else
    echo -e "  ${DIM}Portainer: ${NC}${YELLOW}not configured${NC} (PORTAINER_STACK_WEBHOOK is blank)"
  fi

  # Last 8 journal lines
  echo ""
  rule
  echo -e "\n  ${BOLD}Recent listener activity:${NC}\n"
  journalctl -u seafile-gitops-sync -n 8 --no-pager 2>/dev/null | \
    sed 's/^/  /' || echo "  (no journal entries)"
  echo ""
}

# --- Command: help -----------------------------------------------------------
cmd_help() {
  echo ""
  echo -e "  ${BOLD}${CYAN}seafile${NC} — Seafile stack management"
  echo ""
  rule
  echo ""
  printf "  ${BOLD}%-24s${NC} %s\n" "status"              "Container health, storage mount, and disk usage"
  printf "  ${BOLD}%-24s${NC} %s\n" "logs [name]"         "Tail container logs (interactive picker if omitted)"
  printf "  ${BOLD}%-24s${NC} %s\n" "restart [name]"      "Restart one or all containers"
  printf "  ${BOLD}%-24s${NC} %s\n" "shell [name]"        "Open a shell inside a container"
  printf "  ${BOLD}%-24s${NC} %s\n" "update"              "Run update.sh — apply .env changes and restart"
  printf "  ${BOLD}%-24s${NC} %s\n" "update --check"      "Show what changed in .env since last update"
  echo ""
  printf "  ${BOLD}%-24s${NC} %s\n" "config"              "Interactive configuration editor"
  printf "  ${BOLD}%-24s${NC} %s\n" "config [section]"    "Jump to: core, storage, smtp, ldap, office, features"
  printf "  ${BOLD}%-24s${NC} %s\n" "config show"         "Display current configuration"
  printf "  ${BOLD}%-24s${NC} %s\n" "config edit"         "Open .env in editor directly"
  printf "  ${BOLD}%-24s${NC} %s\n" "config history"      "Browse config change history"
  printf "  ${BOLD}%-24s${NC} %s\n" "config rollback"     "Revert .env to previous version"
  echo ""
  printf "  ${BOLD}%-24s${NC} %s\n" "fix"                 "Run seafile-config-fixes.sh"
  printf "  ${BOLD}%-24s${NC} %s\n" "backup"              "Check storage backup status and trigger sync"
  printf "  ${BOLD}%-24s${NC} %s\n" "ping"                "Check HTTP endpoints (notification, thumbnail, office)"
  printf "  ${BOLD}%-24s${NC} %s\n" "proxy-config"        "Show reverse proxy config (ready to paste for NPM)"
  printf "  ${BOLD}%-24s${NC} %s\n" "metadata --enable-all" "Enable Extended Properties on all libraries"
  printf "  ${BOLD}%-24s${NC} %s\n" "secrets"             "View generated secrets reference (masked)"
  printf "  ${BOLD}%-24s${NC} %s\n" "secrets --show"      "View generated secrets in plaintext"
  printf "  ${BOLD}%-24s${NC} %s\n" "migrate"             "Import data from an existing Seafile instance"
  printf "  ${BOLD}%-24s${NC} %s\n" "version"             "Show running image tags vs .env values"
  printf "  ${BOLD}%-24s${NC} %s\n" "gc"                  "Run garbage collection"
  printf "  ${BOLD}%-24s${NC} %s\n" "gc --status"         "Show GC schedule, last run, and log tail"
  printf "  ${BOLD}%-24s${NC} %s\n" "gitops"              "GitOps listener status and recent activity"
  printf "  ${BOLD}%-24s${NC} %s\n" "help"                "Show this help"
  echo ""
  rule
  echo -e "\n  ${DIM}Examples:${NC}"
  echo -e "  ${DIM}  seafile status${NC}"
  echo -e "  ${DIM}  seafile config smtp${NC}"
  echo -e "  ${DIM}  seafile config storage --status${NC}"
  echo -e "  ${DIM}  seafile logs seafile${NC}\n"
}

# --- Dispatch ----------------------------------------------------------------
CMD="${1:-help}"
shift || true

case "$CMD" in
  status)  cmd_status ;;
  logs)    cmd_logs "$@" ;;
  restart) cmd_restart "$@" ;;
  shell)   cmd_shell "$@" ;;
  update)  cmd_update "$@" ;;
  config)  cmd_config "$@" ;;
  fix)     cmd_fix ;;
  backup)  cmd_backup ;;
  ping)    cmd_ping ;;
  proxy-config) cmd_proxy_config ;;
  metadata) cmd_metadata "$@" ;;
  version) cmd_version ;;
  secrets) cmd_secrets "$@" ;;
  migrate) cmd_migrate ;;
  gitops)  cmd_gitops ;;
  gc)      cmd_gc "$@" ;;
  help|--help|-h) cmd_help ;;
  *)
    err "Unknown command: $CMD"
    cmd_help
    exit 1
    ;;
esac
