#!/bin/bash
# =============================================================================
# Seafile 13 — Update & Configuration Sync
# =============================================================================
# Written by:  install-dependencies.sh (embedded, deployed to /opt/update.sh)
# Backed up to: $SEAFILE_VOLUME/update.sh (NFS, for recover.sh)
# Run from:    /opt/update.sh
#
# Run this script whenever you:
#   - Change any value in /opt/seafile/.env
#   - Want to update one or more container images
#   - Want to verify the deployment is healthy
#
# HOW TO RUN:
#   sudo bash update.sh
#
# WHAT THIS SCRIPT DOES:
#   1. Updates system packages (apt update && apt upgrade)
#   2. Validates that all required .env variables are filled in
#   3. Shows a diff of what has changed since the last run and asks to proceed
#   4. Pulls updated images for any containers whose tag has changed
#   5. Re-applies Seafile config files (seahub_settings.py, seafile.conf, etc.)
#   6. Restarts containers that have changed
#   7. Runs health checks and prints a summary
#
# NOTE ON IMAGE UPDATES:
#   To update a container image, edit its tag in /opt/seafile/.env and re-run
#   this script. The script will detect the tag change, pull the new image, and
#   restart only that container. It will NOT pull images whose tags are unchanged.
#
# SAFE TO RE-RUN:
#   Running this script when nothing has changed is harmless — it will report
#   "no changes detected" and run health checks.
# =============================================================================

set -e
trap 'echo -e "\n${RED}[ERROR]${NC}  update.sh failed at line $LINENO — check output above."; exit 1' ERR

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
heading() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }
# Shared library provides: _compute_profiles, _mask_secret, _get_default,
# _is_dnc, _pfv, _DEFAULTS, _DNC_VARS, _normalize_env, _set_env_secret,
# _show_phase_menu, _run_phase_menu
{{EMBED:src/shared-lib.sh}}

ok()      { echo -e "${GREEN}  ✓${NC}  $1"; }
fail()    { echo -e "${RED}  ✗${NC}  $1"; }
changed() { echo -e "${YELLOW}  ~${NC}  $1"; }

# ---------------------------------------------------------------------------
# .env review helpers — used by the diff confirmation prompt
# ---------------------------------------------------------------------------



[ "$EUID" -ne 0 ] && error "Please run as root or with sudo."

# ---------------------------------------------------------------------------
# Version — read pinned Seafile image tag from .env for display in splash
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
# Splash screen
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
  echo -e "  ${BOLD}nicogits92 / seafile-deploy${NC}   ${DIM}Seafile ${_SEAFILE_VERSION} CE  ·  ${DEPLOY_VERSION}  ·  update.sh${NC}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${DIM}Community deployment · not affiliated with Seafile Ltd.${NC}"
  echo ""
  echo ""
}

ENV_FILE="/opt/seafile/.env"
SNAPSHOT_FILE="/opt/seafile/.env.snapshot"

_PHASES=(
  "Update system packages (apt-get upgrade)"
  "Apply deployment changes (validate .env, diff, pull images, apply config, restart)"
  "Update GitOps integration (skipped unless GITOPS_INTEGRATION=true)"
  "Run health checks (containers, storage, disk usage)"
)
_SELECTED=(true true true true)

# ─────────────────────────────────────────────────────────────────────────────
# Pre-run menu — list steps and allow toggling before execution
# ─────────────────────────────────────────────────────────────────────────────



# --check: show diff against last snapshot and exit without applying anything
if [[ "$1" == "--check" ]]; then
  ENV_FILE="/opt/seafile/.env"
  SNAPSHOT_FILE="/opt/seafile/.env.snapshot"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "No .env found at $ENV_FILE"; exit 1
  fi
  if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "No snapshot found — run update.sh once to create a baseline."; exit 0
  fi
  _env_keys() { grep -v '^\s*#' "$1" | grep '=' | cut -d'=' -f1 | sort -u; }
  CHANGES=()
  while IFS= read -r key; do
    val_new=$(grep "^${key}=" "$ENV_FILE"      2>/dev/null | head -1 | cut -d'=' -f2-)
    val_old=$(grep "^${key}=" "$SNAPSHOT_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)
    [[ "$val_new" != "$val_old" ]] && CHANGES+=("  ~ ${key}")
  done < <(comm -12 <(_env_keys "$ENV_FILE") <(_env_keys "$SNAPSHOT_FILE"))
  if [[ ${#CHANGES[@]} -eq 0 ]]; then
    echo "No changes detected in .env since last run."
  else
    echo -e "\nThe following variables have changed since last update:\n"
    for c in "${CHANGES[@]}"; do echo "$c"; done
    echo ""
  fi
  exit 0
fi

# Skip the menu when called non-interactively (e.g. recovery finalizer, CI)
[[ "$1" != "--yes" ]] && _show_splash && _run_phase_menu "update.sh"

_START_TIME=$SECONDS

if [[ "${_SELECTED[0]}" == "true" ]]; then
# =============================================================================
# 1. System update
# =============================================================================
heading "System update"
info "Running apt-get update and apt-get upgrade..."
apt-get update -qq
apt-get upgrade -y -qq
info "System packages up to date."


fi

if [[ "${_SELECTED[1]}" == "true" ]]; then
# =============================================================================
# 2. Load and validate .env
# =============================================================================
heading "Validating configuration"

[ ! -f "$ENV_FILE" ] && error ".env not found at $ENV_FILE. Nothing to do."
chmod 600 "$ENV_FILE"

# shellcheck disable=SC1090
_load_env "$ENV_FILE"

# --- Normalize .env ---
_normalize_env "$ENV_FILE"

# Build active container list from .env (same logic as CLI and setup)
CONTAINERS=(seafile-caddy seafile-redis seafile seadoc notification-server thumbnail-server seafile-metadata)
case "${OFFICE_SUITE:-collabora}" in
  onlyoffice) CONTAINERS+=(seafile-onlyoffice) ;;
  none)       ;;  # No office suite container
  *)          CONTAINERS+=(seafile-collabora)  ;;
esac
[[ "${CLAMAV_ENABLED:-false}" == "true" ]] && CONTAINERS+=(seafile-clamav)
[[ "${DB_INTERNAL:-true}"    == "true" ]] && CONTAINERS+=(seafile-db)

# Required variables — these must be non-empty for the deployment to function.
# Each entry is "VARIABLE_NAME|human-readable description"
#
# Note: Office suite credentials (COLLABORA_*, ONLYOFFICE_*) and init-only vars
# (INIT_SEAFILE_ADMIN_*) are NOT listed here. They are auto-generated on first
# boot and can safely be left blank or cleared after setup.
REQUIRED_VARS=(
  "STORAGE_TYPE|Storage backend type (nfs, smb, glusterfs, iscsi, local)"
  "SEAFILE_SERVER_HOSTNAME|Your public domain name"
  "SEAFILE_MYSQL_DB_HOST|Database server IP or hostname"
  "SEAFILE_MYSQL_DB_PASSWORD|Database user password"
  "JWT_PRIVATE_KEY|Authentication token signing key"
)

MISSING=()
for entry in "${REQUIRED_VARS[@]}"; do
  var="${entry%%|*}"
  desc="${entry##*|}"
  val="${!var}"
  if [ -z "$val" ]; then
    MISSING+=("  ${YELLOW}${var}${NC} — ${desc}")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "\n${RED}${BOLD}The following required variables are not set in ${ENV_FILE}:${NC}\n"
  for m in "${MISSING[@]}"; do
    echo -e "$m"
  done
  echo ""
  echo -e "  Edit ${BOLD}${ENV_FILE}${NC} to fill in the missing values, then re-run:"
  echo -e "  ${BOLD}sudo bash /opt/update.sh${NC}"
  echo ""
  exit 1
else
  ok "All required variables are set."
fi

# =============================================================================
# 3. Diff against last snapshot — show what has changed
# =============================================================================
heading "Checking for changes"

# Strip blank lines and comments from .env for a clean diff
clean_env() { grep -v '^\s*#' "$1" | grep -v '^\s*$' | sort; }

CHANGES=()
IMAGES_TO_UPDATE=()
DNC_IN_CHANGES=()   # DNC vars that appear in this diff session

# Image variables — track separately so we can pull/restart selectively
IMAGE_VARS=(SEAFILE_IMAGE SEADOC_IMAGE NOTIFICATION_SERVER_IMAGE THUMBNAIL_SERVER_IMAGE MD_IMAGE SEAFILE_REDIS_IMAGE CADDY_IMAGE COLLABORA_IMAGE)

if [ -f "$SNAPSHOT_FILE" ]; then
  # Compare current .env to snapshot line by line
  while IFS= read -r line; do
    [[ "$line" =~ ^\s*# ]] && continue
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val_new="${line#*=}"
    val_old=$(grep "^${key}=" "$SNAPSHOT_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- || true)
    if [ "$val_new" != "$val_old" ]; then
      # Flag DO NOT CHANGE vars that are being changed this session
      _is_dnc_change=false
      for _d in "${_DNC_VARS[@]}"; do
        [[ "$_d" == "$key" ]] && _is_dnc_change=true && DNC_IN_CHANGES+=("$key") && break
      done
      _dnc_tag=""
      $_is_dnc_change && _dnc_tag="  ${YELLOW}⚠ DO NOT CHANGE${NC}"
      case "$key" in
        *PASSWORD*|*KEY*|*SECRET*)
          CHANGES+=("${key}: ${YELLOW}[hidden]${NC} → ${YELLOW}[hidden]${NC}${_dnc_tag}")
          ;;
        *)
          CHANGES+=("${key}: ${YELLOW}${val_old:-'(empty)'}${NC} → ${GREEN}${val_new}${NC}${_dnc_tag}")
          ;;
      esac
      for iv in "${IMAGE_VARS[@]}"; do
        [ "$key" = "$iv" ] && IMAGES_TO_UPDATE+=("$key") && break
      done
    fi
  done < "$ENV_FILE"
else
  warn "No previous snapshot found — this appears to be the first run."
  info "All current values will be applied. A snapshot will be saved after this run."
fi

if [ ${#CHANGES[@]} -eq 0 ] && [ -f "$SNAPSHOT_FILE" ]; then
  ok "No changes detected in .env since last run."
  echo ""
  RUN_APPLY=false
else
  if [ ${#CHANGES[@]} -gt 0 ]; then
    echo -e "\n${BOLD}The following variables have changed:${NC}\n"
    for c in "${CHANGES[@]}"; do
      echo -e "  $c"
    done
    echo ""
  fi

  # DNC warning block
  if [ ${#DNC_IN_CHANGES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}⚠  DO NOT CHANGE variables were modified${NC}"
    echo -e "  ${DIM}These variables control internal container wiring. Changing them on a${NC}"
    echo -e "  ${DIM}live deployment will break database connections or service discovery.${NC}"
    echo -e "  ${DIM}Only continue if you are certain this is intentional.${NC}"
    echo ""
    for _dnc_var in "${DNC_IN_CHANGES[@]}"; do
      echo -e "    ${YELLOW}$_dnc_var${NC}"
    done
    echo ""
  fi

  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}  y  ${NC}Apply changes and restart affected containers"
  echo -e "  ${BOLD}  v  ${NC}View full configuration review first"
  echo -e "  ${DIM}  n  ${NC}Abort — no changes applied"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  while true; do
    echo -ne "  ${BOLD}Select [y/v/n] (default: y):${NC} "
    read -r confirm
    confirm="${confirm:-y}"
    case "${confirm,,}" in
      y|yes)
        RUN_APPLY=true
        break
        ;;
      v|view)
        _print_config_review
        echo -e "\n${BOLD}Changes in this update:${NC}\n"
        for c in "${CHANGES[@]}"; do echo -e "  $c"; done
        echo ""
        if [ ${#DNC_IN_CHANGES[@]} -gt 0 ]; then
          echo -e "  ${YELLOW}${BOLD}⚠  DO NOT CHANGE variables in this diff:${NC}"
          for _dnc_var in "${DNC_IN_CHANGES[@]}"; do echo -e "    ${YELLOW}$_dnc_var${NC}"; done
          echo ""
        fi
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}  y  ${NC}Apply changes and restart affected containers"
        echo -e "  ${DIM}  n  ${NC}Abort — no changes applied"
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        while true; do
          echo -ne "  ${BOLD}Select [y/n] (default: y):${NC} "
          read -r confirm2
          confirm2="${confirm2:-y}"
          case "${confirm2,,}" in
            y|yes) RUN_APPLY=true;  break 2 ;;
            n|no)  info "Aborted — no changes applied."; RUN_APPLY=false; break 2 ;;
            *)     echo -e "  ${DIM}Enter y or n.${NC}" ;;
          esac
        done
        ;;
      n|no)
        info "Aborted — no changes applied."
        RUN_APPLY=false
        break
        ;;
      *) echo -e "  ${DIM}Enter y, v, or n.${NC}" ;;
    esac
  done
fi
# =============================================================================
# 4. Pull updated images
# =============================================================================
if [ "$RUN_APPLY" = true ] && [ ${#IMAGES_TO_UPDATE[@]} -gt 0 ]; then
  heading "Pulling updated images"
  for iv in "${IMAGES_TO_UPDATE[@]}"; do
    tag="${!iv}"
    info "Pulling ${tag}..."
    docker pull "$tag" && ok "Pulled ${tag}" || warn "Pull failed for ${tag} — will continue with existing image"
  done
fi

# =============================================================================
# 5. Apply Seafile configuration via seafile-config-fixes.sh
# =============================================================================
if [ "$RUN_APPLY" = true ]; then
  heading "Applying Seafile configuration"

  # seafile-config-fixes.sh is the single source of truth for config generation.
  # It handles all .env conditionals (OFFICE_SUITE, SMTP, LDAP, ClamAV, WebDAV,
  # user quotas, 2FA, etc.) and restarts containers with the correct dynamic list.
  CONFIG_FIXES_SCRIPT="/opt/seafile-config-fixes.sh"

  if [[ ! -f "$CONFIG_FIXES_SCRIPT" ]]; then
    warn "seafile-config-fixes.sh not found at $CONFIG_FIXES_SCRIPT"
    warn "Config files will not be updated. Run the installer again to restore it."
  else
    info "Running seafile-config-fixes.sh --yes..."
    if bash "$CONFIG_FIXES_SCRIPT" --yes; then
      ok "Config files written and containers restarted."
    else
      warn "seafile-config-fixes.sh reported an error — check output above."
    fi
  fi

  # --- Clear INIT_SEAFILE_MYSQL_ROOT_PASSWORD if still set ---
  if grep -q "^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=.\+" "$ENV_FILE" 2>/dev/null; then
    sed -i 's/^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=.*/INIT_SEAFILE_MYSQL_ROOT_PASSWORD=/' "$ENV_FILE"
    warn "INIT_SEAFILE_MYSQL_ROOT_PASSWORD has been cleared from ${ENV_FILE}."
    warn "Remember to also clear it in Portainer under Environment variables."
  fi

  # --- Save snapshot of applied config ---
  cp "$ENV_FILE" "$SNAPSHOT_FILE"
  chmod 600 "$SNAPSHOT_FILE"
  date > "${SNAPSHOT_FILE}.date"
  info "Configuration snapshot saved."

  # --- Write docker-compose.yml to disk (keeps it current with this version) ---
  COMPOSE_FILE="/opt/seafile/docker-compose.yml"
  cat > "$COMPOSE_FILE" << 'COMPOSEEOF'
{{EMBED:src/docker-compose.yml}}
COMPOSEEOF
  info "docker-compose.yml updated at $COMPOSE_FILE."

  # --- Back up update.sh to NFS (keeps recovery chain intact) ---
  NFS_UPDATE="${SEAFILE_VOLUME}/update.sh"
  cp "$0" "$NFS_UPDATE"
  chmod +x "$NFS_UPDATE"
  info "update.sh backed up to storage share."

  # --- Reconcile stack with Docker Compose (native mode only) ---
  if [[ "${PORTAINER_MANAGED,,}" != "true" ]]; then
    info "Running docker compose up -d to reconcile stack..."
    _compute_profiles
    info "Active profiles: ${COMPOSE_PROFILES}"
    if COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1; then
      ok "Stack reconciled — all services are up to date."
    else
      warn "docker compose up reported an issue — check: docker ps && docker logs seafile"
    fi
  else
    info "PORTAINER_MANAGED=true — skipping docker compose reconcile (Portainer manages the stack)."
  fi

  # --- Reconcile config git server based on PORTAINER_MANAGED ---
  if [[ -f /etc/systemd/system/seafile-config-server.service ]]; then
    if [[ "${PORTAINER_MANAGED,,}" == "true" ]]; then
      if ! systemctl is-active --quiet seafile-config-server 2>/dev/null; then
        systemctl daemon-reload
        systemctl enable seafile-config-server 2>/dev/null || true
        systemctl start seafile-config-server 2>/dev/null || true
        ok "Config git server started (PORTAINER_MANAGED=true)."
      fi
    else
      if systemctl is-active --quiet seafile-config-server 2>/dev/null; then
        systemctl stop seafile-config-server 2>/dev/null || true
        systemctl disable seafile-config-server 2>/dev/null || true
        info "Config git server stopped (PORTAINER_MANAGED=false)."
      fi
    fi
  fi
fi


fi

# =============================================================================
# Phase 2 — Update GitOps integration
# =============================================================================
if [[ "${_SELECTED[2]}" == "true" ]]; then

  heading "GitOps integration"

  if [[ "${GITOPS_INTEGRATION,,}" != "true" ]]; then
    info "GITOPS_INTEGRATION is not set to true — skipping."
  else

    GITOPS_MISSING=()
    [ -z "$GITOPS_REPO_URL"       ] && GITOPS_MISSING+=("GITOPS_REPO_URL")
    [ -z "$GITOPS_TOKEN"          ] && GITOPS_MISSING+=("GITOPS_TOKEN")
    [ -z "$GITOPS_WEBHOOK_SECRET" ] && GITOPS_MISSING+=("GITOPS_WEBHOOK_SECRET")

    if [ ${#GITOPS_MISSING[@]} -gt 0 ]; then
      warn "GitOps update skipped — the following .env variables are required but not set:"
      for v in "${GITOPS_MISSING[@]}"; do warn "  $v"; done
    else

      CLONE_PATH="${GITOPS_CLONE_PATH:-/opt/seafile-gitops}"
      BRANCH="${GITOPS_BRANCH:-main}"
      AUTHED_URL=$(echo "$GITOPS_REPO_URL" | sed "s|://|://oauth2:${GITOPS_TOKEN}@|")
      GITOPS_SCRIPT="/opt/seafile/seafile-gitops-sync.py"
      GITOPS_SERVICE="/etc/systemd/system/seafile-gitops-sync.service"

      # --- Test git connectivity (non-fatal) ---
      info "Testing connectivity to gitops repo..."
      if git ls-remote --heads "$AUTHED_URL" "$BRANCH" --timeout=10 > /dev/null 2>&1; then
        ok "Gitops repo is reachable."
        GIT_OK=true
      else
        warn "Cannot reach gitops repo at $GITOPS_REPO_URL."
        warn "GitOps update skipped — Seafile is unaffected. Check your Gitea server."
        warn "Re-run update.sh once the git server is reachable to retry."
        GIT_OK=false
      fi

      if [ "$GIT_OK" = true ]; then

        # --- Pull latest repo ---
        if [ -d "$CLONE_PATH/.git" ]; then
          git -C "$CLONE_PATH" remote set-url origin "$AUTHED_URL"
          git -C "$CLONE_PATH" pull --quiet \
            && ok "Gitops repo updated at $CLONE_PATH." \
            || warn "git pull failed — existing clone retained."
        else
          info "No clone found at $CLONE_PATH — cloning..."
          git clone --branch "$BRANCH" "$AUTHED_URL" "$CLONE_PATH" \
            && ok "Repo cloned." \
            || warn "git clone failed — GitOps integration may not be fully set up."
        fi
        # Lock down clone directory — .git/config contains the auth token
        [ -d "$CLONE_PATH" ] && chmod 700 "$CLONE_PATH"

        # --- Ensure listener script is current ---
        if [ ! -f "$GITOPS_SCRIPT" ]; then
          warn "$GITOPS_SCRIPT not found — run install-dependencies.sh to set up GitOps."
        fi

        # --- Ensure service is running ---
        if [ -f "$GITOPS_SERVICE" ]; then
          systemctl daemon-reload
          if ! systemctl is-active --quiet seafile-gitops-sync; then
            systemctl start seafile-gitops-sync \
              && ok "seafile-gitops-sync service started." \
              || warn "Failed to start seafile-gitops-sync — check: journalctl -u seafile-gitops-sync"
          else
            systemctl restart seafile-gitops-sync \
              && ok "seafile-gitops-sync service restarted." \
              || warn "Failed to restart seafile-gitops-sync — check: journalctl -u seafile-gitops-sync"
          fi
        else
          warn "seafile-gitops-sync.service not found — run install-dependencies.sh to set up GitOps."
        fi

      fi
    fi
  fi

fi
if [[ "${_SELECTED[3]}" == "true" ]]; then
# =============================================================================
# 8. Health checks
# =============================================================================
heading "Health checks"

# --- Container status ---
echo ""
echo -e "${BOLD}  Container status:${NC}"
ALL_HEALTHY=true
for c in "${CONTAINERS[@]}"; do
  status=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "not found")
  uptime=$(docker inspect --format='{{.State.StartedAt}}' "$c" 2>/dev/null || echo "")
  if [ "$status" = "running" ]; then
    _since=$(docker inspect --format='{{.State.StartedAt}}' "$c" 2>/dev/null | cut -dT -f1 || echo "")
    _up=""
    if [[ -n "$_since" ]]; then
      _start_epoch=$(date -d "$_since" +%s 2>/dev/null || echo "")
      if [[ -n "$_start_epoch" ]]; then
        _secs=$(( $(date +%s) - _start_epoch ))
        if   (( _secs < 3600 ));   then _up="${DIM}up $(( _secs / 60 ))m${NC}"
        elif (( _secs < 86400 ));  then _up="${DIM}up $(( _secs / 3600 ))h$(( (_secs % 3600) / 60 ))m${NC}"
        else                            _up="${DIM}up $(( _secs / 86400 ))d$(( (_secs % 86400) / 3600 ))h${NC}"
        fi
      fi
    fi
    ok "${c} — running  ${_up}"
  else
    fail "${c} — ${status}"
    ALL_HEALTHY=false
  fi
done

# --- Caddy HTTP reachability ---
echo ""
echo -e "${BOLD}  Network:${NC}"
CADDY_PORT_VAL="${CADDY_PORT:-7080}"
HOST_HDR="${SEAFILE_SERVER_HOSTNAME:-localhost}"
HTTP_CODE=$(curl -s -o /dev/null -H "Host: ${HOST_HDR}" -w "%{http_code}" --max-time 5 "http://localhost:${CADDY_PORT_VAL}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ]; then
  ok "Caddy responding on port ${CADDY_PORT_VAL} (HTTP ${HTTP_CODE})"
else
  fail "Caddy not responding on port ${CADDY_PORT_VAL} — check: docker logs seafile-caddy"
  ALL_HEALTHY=false
fi

# --- Network storage mount ---
STORAGE_PATH="${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
_STYPE="${STORAGE_TYPE:-nfs}"
if [[ "$_STYPE" == "local" ]]; then
  if [[ -d "$STORAGE_PATH" ]]; then
    ok "Local storage directory exists at ${STORAGE_PATH}"
  else
    fail "Local storage directory NOT found at ${STORAGE_PATH}"
    ALL_HEALTHY=false
  fi
elif mountpoint -q "$STORAGE_PATH"; then
  ok "${_STYPE} share mounted at ${STORAGE_PATH}"
else
  fail "${_STYPE} share NOT mounted at ${STORAGE_PATH}"
  ALL_HEALTHY=false
fi

# --- Disk usage ---
echo ""
echo -e "${BOLD}  Disk usage:${NC}"
NFS_USAGE=$(df -h "$STORAGE_PATH" 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full)"}' \
  || echo "unavailable")
LOCAL_USAGE=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full)"}' || echo "unavailable")
THUMB_USAGE=$(du -sh "${THUMBNAIL_PATH:-/opt/seafile-thumbnails}" 2>/dev/null | cut -f1 || echo "0")
META_USAGE=$(du -sh "${METADATA_PATH:-/opt/seafile-metadata}" 2>/dev/null | cut -f1 || echo "0")

echo -e "    Storage (${STORAGE_PATH}):          ${NFS_USAGE}"
echo -e "    Local disk (/opt):                  ${LOCAL_USAGE}"
echo -e "    Thumbnail cache:                    ${THUMB_USAGE}"
echo -e "    Metadata index:                     ${META_USAGE}"

# --- Disk usage warnings ---
_NFS_PCT=$(df "$STORAGE_PATH" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
_LOCAL_PCT=$(df /opt 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
if (( _NFS_PCT >= 90 )); then
  fail "Storage volume is ${_NFS_PCT}% full — consider freeing space immediately."
  ALL_HEALTHY=false
elif (( _NFS_PCT >= 80 )); then
  warn "Storage volume is ${_NFS_PCT}% full — getting close to capacity."
fi
if (( _LOCAL_PCT >= 85 )); then
  warn "Local disk (/opt) is ${_LOCAL_PCT}% full — thumbnail/metadata caches may need pruning."
fi

# --- Summary ---
echo ""
if [ "$ALL_HEALTHY" = true ]; then
  echo -e "${GREEN}${BOLD}  All checks passed.${NC}"
else
  echo -e "${YELLOW}${BOLD}  Some checks failed — review the items marked ✗ above.${NC}"
  echo -e "  Useful commands:"
  echo -e "    docker logs <container-name>"
  echo -e "    docker ps"
  echo -e "    journalctl -xe"
fi
echo ""

fi

# =============================================================================
# Config history
# =============================================================================
_config_history_init  # Ensures repo exists (handles upgrades from older versions)
_config_history_commit "$(date '+%Y-%m-%d %H:%M:%S') update.sh completed"

# =============================================================================
# Done
# =============================================================================
_LAST_RUN=""
if [[ -f "${SNAPSHOT_FILE}.date" ]]; then
  _LAST_RUN=$(cat "${SNAPSHOT_FILE}.date" 2>/dev/null | tr -d '\n' || true)
fi

_ELAPSED=$(( SECONDS - _START_TIME ))
if   (( _ELAPSED < 60 ));  then _DURATION="${_ELAPSED}s"
elif (( _ELAPSED < 3600 )); then _DURATION="$(( _ELAPSED / 60 ))m $(( _ELAPSED % 60 ))s"
else                              _DURATION="$(( _ELAPSED / 3600 ))h $(( (_ELAPSED % 3600) / 60 ))m"
fi

echo ""
[[ -n "$_LAST_RUN" ]] && echo -e "  ${DIM}Last updated: ${_LAST_RUN}${NC}"
echo -e "  ${DIM}Completed in ${_DURATION}.${NC}"
echo -e "  ${DIM}Review the health checks above — any ✗ items need attention.${NC}"
echo -e "  ${DIM}To re-check at any time:  seafile status${NC}"
if [[ "${PORTAINER_MANAGED,,}" == "true" ]] && [[ "$RUN_APPLY" == "true" ]]; then
  echo ""
  if [[ -n "${PORTAINER_STACK_WEBHOOK:-}" ]]; then
    if curl -sf -X POST "${PORTAINER_STACK_WEBHOOK}" --max-time 15 >/dev/null 2>&1; then
      echo -e "  ${DIM}  PORTAINER_MANAGED=true — Portainer notified via webhook.${NC}"
    else
      echo -e "  ${YELLOW}[WARN]${NC}  PORTAINER_MANAGED=true — webhook call failed."
      echo -e "  ${DIM}         Portainer may not redeploy automatically. Trigger manually.${NC}"
    fi
  else
    echo -e "  ${YELLOW}[WARN]${NC}  PORTAINER_MANAGED=true but PORTAINER_STACK_WEBHOOK is blank."
    echo -e "  ${DIM}         Set the webhook URL so Portainer redeploys automatically.${NC}"
    echo -e "  ${DIM}         See README → Portainer Integration for setup.${NC}"
  fi
fi
echo ""
echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}${BOLD}  ✓  Your Seafile deployment is up to date.${NC}"
echo ""

