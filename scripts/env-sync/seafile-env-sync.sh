#!/bin/bash
# =============================================================================
# seafile-env-sync.sh — .env mirror, version history, and Portainer sync
# =============================================================================
# Written by:  setup.sh (first install / recovery)
# Deployed to: /opt/seafile/seafile-env-sync.sh on the Docker host
# Managed by:  seafile-env-sync.service (systemd) — do not run directly
#
# Three responsibilities:
#   1. Mirror /opt/seafile/.env to the storage share (disaster recovery)
#   2. Commit changes to the local config history git repo (versioning)
#   3. Trigger Portainer redeploy when .env changes (if PORTAINER_MANAGED=true)
#
# Supports all STORAGE_TYPE values: nfs, smb, glusterfs, iscsi, local.
# =============================================================================

LOCAL_ENV="/opt/seafile/.env"
HISTORY_DIR="/opt/seafile/.config-history"

# Read settings from .env
STORAGE_DIR="${SEAFILE_VOLUME:-/mnt/seafile_nfs}"
STORAGE_TYPE_VAL="nfs"
CONFIG_HISTORY="true"
PORTAINER_MANAGED_VAL="false"
PORTAINER_WEBHOOK=""

if [ -f "$LOCAL_ENV" ]; then
  STORAGE_DIR=$(grep "^SEAFILE_VOLUME=" "$LOCAL_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
  STORAGE_TYPE_VAL=$(grep "^STORAGE_TYPE=" "$LOCAL_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
  CONFIG_HISTORY=$(grep "^CONFIG_HISTORY_ENABLED=" "$LOCAL_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
  PORTAINER_MANAGED_VAL=$(grep "^PORTAINER_MANAGED=" "$LOCAL_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
  PORTAINER_WEBHOOK=$(grep "^PORTAINER_STACK_WEBHOOK=" "$LOCAL_ENV" | cut -d'=' -f2- | tr -d '[:space:]')
  STORAGE_DIR="${STORAGE_DIR:-/mnt/seafile_nfs}"
  STORAGE_TYPE_VAL="${STORAGE_TYPE_VAL:-nfs}"
  CONFIG_HISTORY="${CONFIG_HISTORY:-true}"
  PORTAINER_MANAGED_VAL="${PORTAINER_MANAGED_VAL:-false}"
fi
STORAGE_ENV="${STORAGE_DIR}/.env"
# Note: .secrets is NOT synced to the network share for security.
# Use "seafile secrets --show" on the host to view generated credentials.

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[ENV-SYNC]${NC} $1"; }
warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[ENV-SYNC]${NC} $1"; }
err()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ENV-SYNC]${NC} $1"; }

# --- Commit to config history repo ---
_commit_history() {
  [[ "$CONFIG_HISTORY" != "true" ]] && return 0
  [[ ! -d "$HISTORY_DIR/.git" ]] && return 0

  cp "$LOCAL_ENV" "$HISTORY_DIR/.env" 2>/dev/null || return 0
  cd "$HISTORY_DIR" || return 0
  git add -A 2>/dev/null || return 0
  git diff --cached --quiet 2>/dev/null && return 0
  git commit -m "$(date '+%Y-%m-%d %H:%M:%S') .env changed" --quiet 2>/dev/null || true
  git update-server-info 2>/dev/null || true
  log "Config history updated"
}

# --- Trigger Portainer redeploy ---
_notify_portainer() {
  [[ "$PORTAINER_MANAGED_VAL" != "true" ]] && return 0
  [[ -z "$PORTAINER_WEBHOOK" ]] && return 0

  if curl -sf -X POST "$PORTAINER_WEBHOOK" --max-time 10 >/dev/null 2>&1; then
    log "Portainer stack webhook triggered"
  else
    warn "Portainer webhook failed — URL: ${PORTAINER_WEBHOOK}"
  fi
}

# --- Wait for storage to be available (network types only) ---
if [[ "$STORAGE_TYPE_VAL" == "local" ]]; then
  mkdir -p "$STORAGE_DIR"
else
  RETRIES=12
  until mountpoint -q "$STORAGE_DIR" || [ "$RETRIES" -eq 0 ]; do
    warn "Waiting for storage share at $STORAGE_DIR... ($RETRIES retries left)"
    sleep 5
    RETRIES=$((RETRIES - 1))
  done
  if ! mountpoint -q "$STORAGE_DIR"; then
    err "Storage share not mounted at $STORAGE_DIR after waiting. Cannot sync .env."
    exit 1
  fi
fi

# --- Startup: restore from storage backup if local .env is missing ---
if [ ! -f "$LOCAL_ENV" ]; then
  if [ -f "$STORAGE_ENV" ]; then
    log "Local .env not found — restoring from storage backup..."
    cp "$STORAGE_ENV" "$LOCAL_ENV"
    chmod 600 "$LOCAL_ENV"
    log "Restored $LOCAL_ENV from $STORAGE_ENV"
  else
    err "No .env found at $LOCAL_ENV or $STORAGE_ENV."
    err "Place your .env at $LOCAL_ENV and re-run: sudo bash /opt/seafile-config-fixes.sh"
    exit 1
  fi
else
  log "Local .env found — syncing to storage backup..."
  cp "$LOCAL_ENV" "$STORAGE_ENV"
  chmod 600 "$STORAGE_ENV"
  log "Synced $LOCAL_ENV → $STORAGE_ENV"

fi

# Initial history commit on startup
_commit_history

# --- Watch for changes ---
log "Watching $LOCAL_ENV for changes..."
while true; do
  inotifywait -e close_write,moved_to,create "$LOCAL_ENV" 2>/dev/null
  # Brief settle — avoids catching intermediate state during rapid successive writes
  sleep 0.5
  if [ -f "$LOCAL_ENV" ]; then
    # 1. Backup to storage share (DR)
    cp "$LOCAL_ENV" "$STORAGE_ENV"
    chmod 600 "$STORAGE_ENV"
    log "Change detected — synced $LOCAL_ENV → $STORAGE_ENV"


    # 2. Commit to config history (versioning)
    _commit_history

    # 3. Notify Portainer (if managed)
    _notify_portainer
  fi
done
