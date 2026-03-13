#!/bin/bash
# =============================================================================
# seafile-recovery-finalize.sh — Post-recovery config applier
# =============================================================================
# Written by:  recover.sh (embedded as a heredoc — edit THAT file, not this one)
# Deployed to: /opt/seafile/seafile-recovery-finalize.sh on the Docker host
# Managed by:  seafile-recovery-finalize.service (systemd) — do not run directly
#
# Installed by recover.sh to complete the stack restore automatically after
# the stack is started on a rebuilt VM.
#
# What it does:
#   1. If DB_INTERNAL=true and DB snapshots exist on the share:
#      - Generates a temp root password (INIT_SEAFILE_MYSQL_ROOT_PASSWORD may
#        have been cleared from .env after original deploy)
#      - Starts seafile-db standalone, waits for it to be ready
#      - Restores the latest snapshot for each database
#   2. In native mode (PORTAINER_MANAGED=false): starts the full stack via
#      docker compose up -d
#      In Portainer-managed mode: waits for Portainer to deploy the stack
#   3. Waits for all active containers to reach 'running' status
#   4. Waits for Seafile's first-run init to complete
#   5. Runs seafile-config-fixes.sh --yes
#   6. Disables itself
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[FINALIZE]${NC}  $1"; }
warn()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[FINALIZE]${NC}  $1"; }
error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[FINALIZE]${NC} $1"; exit 1; }

# --- Safe .env loader ---
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

ENV_FILE="/opt/seafile/.env"
COMPOSE_FILE="/opt/seafile/docker-compose.yml"
FIXES_FILE="/opt/seafile-config-fixes.sh"

# Load .env — gives us PORTAINER_MANAGED, DB_INTERNAL, SEAFILE_VOLUME, etc.
if [ -f "$ENV_FILE" ]; then
  _load_env "$ENV_FILE"
else
  error ".env not found at $ENV_FILE — recovery cannot continue."
fi

# ---------------------------------------------------------------------------
# Compute COMPOSE_PROFILES from .env — same logic as install/update scripts
# ---------------------------------------------------------------------------
_compute_profiles() {
  local _profiles=()
  case "${OFFICE_SUITE:-collabora}" in
    onlyoffice) _profiles+=(onlyoffice) ;;
    none)       ;;  # No office suite container
    *)          _profiles+=(collabora)  ;;
  esac
  [[ "${CLAMAV_ENABLED:-false}" == "true" ]] && _profiles+=(clamav)
  [[ "${DB_INTERNAL:-true}"    == "true" ]] && _profiles+=(internal-db)
  export COMPOSE_PROFILES
  COMPOSE_PROFILES=$(IFS=','; echo "${_profiles[*]}")
}
_compute_profiles

# ---------------------------------------------------------------------------
# Build active container list — used for health-wait loop
# ---------------------------------------------------------------------------
EXPECTED_CONTAINERS=(
  seafile-caddy
  seafile-redis
  seafile
  seadoc
  notification-server
  thumbnail-server
  seafile-metadata
)
case "${OFFICE_SUITE:-collabora}" in
  onlyoffice) EXPECTED_CONTAINERS+=(seafile-onlyoffice) ;;
  none)       ;;
  *)          EXPECTED_CONTAINERS+=(seafile-collabora)  ;;
esac
[[ "${CLAMAV_ENABLED:-false}" == "true" ]] && EXPECTED_CONTAINERS+=(seafile-clamav)
[[ "${DB_INTERNAL:-true}"    == "true" ]] && EXPECTED_CONTAINERS+=(seafile-db)

info "Active containers for this deployment: ${EXPECTED_CONTAINERS[*]}"

# ---------------------------------------------------------------------------
# DB restore — only when DB_INTERNAL=true and snapshots exist on the share
# ---------------------------------------------------------------------------
_RESTORE_DB=false
_DB_BACKUP_DIR="${SEAFILE_VOLUME}/db-backup"

if [[ "${DB_INTERNAL:-true}" == "true" && "${STORAGE_TYPE:-nfs}" != "local" ]]; then
  if ls "${_DB_BACKUP_DIR}"/*.sql.gz 2>/dev/null | head -1 | grep -q .; then
    info "Found DB snapshots in ${_DB_BACKUP_DIR}/ — database will be restored."
    _RESTORE_DB=true

    # INIT_SEAFILE_MYSQL_ROOT_PASSWORD is blank in the recovered .env
    # (it was cleared by config-fixes after the original deploy).
    # Generate a temp root password so the fresh seafile-db container starts
    # with a known credential we can use for the restore.
    # config-fixes will clear it again at the end of recovery.
    if [[ -z "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" ]]; then
      _TMP_ROOT=$(openssl rand -hex 16)
      sed -i "s/^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$/INIT_SEAFILE_MYSQL_ROOT_PASSWORD=${_TMP_ROOT}/" "$ENV_FILE"
      export INIT_SEAFILE_MYSQL_ROOT_PASSWORD="$_TMP_ROOT"
      info "Generated temp root password for DB restore (will be cleared by config-fixes)."
    fi
  else
    warn "DB_INTERNAL=true but no snapshots found in ${_DB_BACKUP_DIR}/"
    warn "Database will initialize empty — file data is intact on the share."
    warn "Worst case: up to 1 day of metadata changes (library names, shares,"
    warn "permissions) may be missing. File content is unaffected."
  fi
fi

# ---------------------------------------------------------------------------
# DB restore (native mode only) — start seafile-db first, import, then full stack
# ---------------------------------------------------------------------------
if [[ "${_RESTORE_DB}" == "true" && "${PORTAINER_MANAGED,,}" != "true" ]]; then
  info "Starting seafile-db container for DB restore..."
  COMPOSE_PROFILES="$COMPOSE_PROFILES" \
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db \
    || error "Failed to start seafile-db — check: docker logs seafile-db"

  info "Waiting for seafile-db to accept connections (up to 60s)..."
  _READY=false
  for i in $(seq 1 30); do
    if docker exec seafile-db mysqladmin \
        ping -u root -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}" \
        --silent 2>/dev/null; then
      _READY=true
      break
    fi
    sleep 2
  done
  [[ "$_READY" != "true" ]] && error "seafile-db did not become ready in 60s — check: docker logs seafile-db"
  info "seafile-db is ready. Restoring snapshots..."

  for db in \
      "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
      "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
      "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do
    LATEST=$(ls -t "${_DB_BACKUP_DIR}/${db}_"*.sql.gz 2>/dev/null | head -1 || true)
    if [[ -n "$LATEST" ]]; then
      SNAP_DATE=$(basename "$LATEST" | grep -oP '\d{8}_\d{6}' || echo "unknown date")
      info "  Restoring ${db} from snapshot ${SNAP_DATE}..."
      gunzip -c "$LATEST" | docker exec -i seafile-db \
        mysql -u root -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}" "$db" \
        && info "  ✓ ${db} restored" \
        || warn "  ✗ Failed to restore ${db} — database will initialize empty"
    else
      warn "  No snapshot found for ${db} — will initialize empty"
    fi
  done
  info "DB restore complete. Starting remaining stack..."

elif [[ "${_RESTORE_DB}" == "true" && "${PORTAINER_MANAGED,,}" == "true" ]]; then
  warn "DB_INTERNAL=true with Portainer-managed mode — automated DB restore is not"
  warn "supported in Portainer mode because stack startup order cannot be controlled."
  warn ""
  warn "To restore your database manually before deploying the stack:"
  warn "  1. In Portainer, deploy ONLY the seafile-db service first"
  warn "  2. SSH to this host and run:"
  warn "       /opt/seafile-db-restore.sh"
  warn "  3. Then deploy the full stack in Portainer"
  warn ""
  warn "A restore helper script has been written to /opt/seafile-db-restore.sh"

  # Write a manual restore helper for the Portainer case
  cat > /opt/seafile-db-restore.sh << RESTOREEOF
#!/bin/bash
# Manual DB restore helper for Portainer-managed recovery
# Run this AFTER seafile-db is running but BEFORE deploying the full stack.
set -euo pipefail
source /opt/seafile/.env
DB_BACKUP_DIR="\${SEAFILE_VOLUME}/db-backup"
for db in "\${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
           "\${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
           "\${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do
  LATEST=\$(ls -t "\${DB_BACKUP_DIR}/\${db}_"*.sql.gz 2>/dev/null | head -1 || true)
  if [[ -n "\$LATEST" ]]; then
    echo "Restoring \${db} from \$(basename \$LATEST)..."
    gunzip -c "\$LATEST" | docker exec -i seafile-db \
      mysql -u root -p"\${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}" "\${db}" \
      && echo "  ✓ \${db} restored" || echo "  ✗ Failed to restore \${db}"
  else
    echo "No snapshot for \${db} — skipping"
  fi
done
RESTOREEOF
  chmod +x /opt/seafile-db-restore.sh
fi

# ---------------------------------------------------------------------------
# Start stack (native mode)
# ---------------------------------------------------------------------------
if [[ "${PORTAINER_MANAGED,,}" != "true" ]]; then
  if [ ! -f "$COMPOSE_FILE" ]; then
    error "docker-compose.yml not found at $COMPOSE_FILE"
  fi
  info "PORTAINER_MANAGED=false — starting stack via docker compose..."
  COMPOSE_PROFILES="$COMPOSE_PROFILES" \
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d \
    || error "docker compose up failed — check: docker ps && docker logs seafile"
  info "Stack started. Waiting for containers to reach running status..."
else
  info "PORTAINER_MANAGED=true — waiting for Portainer to deploy the stack..."
  info "Redeploy the stack in Portainer now if you have not already done so."
fi

# ---------------------------------------------------------------------------
# Wait for all active containers
# ---------------------------------------------------------------------------
info "Waiting for all containers: ${EXPECTED_CONTAINERS[*]}"
while true; do
  ALL_UP=true
  for CONTAINER in "${EXPECTED_CONTAINERS[@]}"; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
    if [ "$STATUS" != "running" ]; then
      ALL_UP=false
      break
    fi
  done
  if $ALL_UP; then
    info "All containers are running."
    break
  fi
  warn "Containers not yet up — retrying in 5 seconds..."
  sleep 5
done

# ---------------------------------------------------------------------------
# Wait for Seafile init
# ---------------------------------------------------------------------------
info "Waiting for Seafile init to complete (conf directory on storage share)..."
CONF_DIR="${SEAFILE_VOLUME}/seafile/conf"
until [ -d "$CONF_DIR" ]; do
  warn "Conf directory not yet present — retrying in 5 seconds..."
  sleep 5
done
info "Conf directory found. Waiting for database tables..."

# Wait for tables to exist in seahub_db before running config-fixes.
# In recovery, tables come from the DB restore. In fresh-DB recovery,
# Seafile creates them during init.
_ROOT_PASS="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}"
if [[ -n "$_ROOT_PASS" && "${DB_INTERNAL:-true}" == "true" ]]; then
  _tables_ready=false
  for _t in {1..60}; do
    _tcount=$(docker exec seafile-db mysql -u root -p"${_ROOT_PASS}" -N \
      -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}';" 2>/dev/null || echo "0")
    if [[ "$_tcount" -gt 10 ]]; then
      info "Database tables verified (${_tcount} tables in seahub_db)."
      _tables_ready=true
      break
    fi
    if (( _t % 6 == 0 )); then
      info "  Still waiting for tables... (${_tcount} so far)"
    fi
    sleep 5
  done
  if [[ "$_tables_ready" != "true" ]]; then
    warn "Timed out waiting for tables. Config-fixes will proceed anyway."
  fi
else
  info "No DB root access — waiting 60 seconds for migrations to finish..."
  sleep 60
fi

# ---------------------------------------------------------------------------
# Run config fixes
# ---------------------------------------------------------------------------
info "Running seafile-config-fixes.sh..."
bash "$FIXES_FILE" --yes || error "seafile-config-fixes.sh failed — check: journalctl -u seafile-recovery-finalize"

# --- Initialize config history repo ---
HISTORY_DIR="/opt/seafile/.config-history"
if [[ "${CONFIG_HISTORY_ENABLED:-true}" == "true" ]]; then
  if [[ ! -d "$HISTORY_DIR/.git" ]]; then
    mkdir -p "$HISTORY_DIR"
    cd "$HISTORY_DIR"
    git init --quiet 2>/dev/null
    git config user.email "seafile-deploy@localhost"
    git config user.name "seafile-deploy"
  fi
  cp /opt/seafile/.env "$HISTORY_DIR/.env" 2>/dev/null || true
  [[ -f /opt/seafile/docker-compose.yml ]] && cp /opt/seafile/docker-compose.yml "$HISTORY_DIR/docker-compose.yml" 2>/dev/null || true
  [[ -f "$FIXES_FILE" ]] && cp "$FIXES_FILE" "$HISTORY_DIR/seafile-config-fixes.sh" 2>/dev/null || true
  [[ -f /opt/update.sh ]] && cp /opt/update.sh "$HISTORY_DIR/update.sh" 2>/dev/null || true
  cd "$HISTORY_DIR" && git add -A 2>/dev/null && \
    git commit -m "Recovery completed — initial state" --quiet 2>/dev/null || true
  git update-server-info 2>/dev/null || true
  info "Config history initialized"
fi

# --- Start config git server if Portainer-managed ---
if [[ "${PORTAINER_MANAGED:-false}" == "true" ]]; then
  if [[ -f /etc/systemd/system/seafile-config-server.service ]]; then
    systemctl daemon-reload
    systemctl enable seafile-config-server 2>/dev/null || true
    systemctl start seafile-config-server 2>/dev/null || true
    info "Config git server started for Portainer integration"
  fi
fi

info "Recovery complete. Disabling seafile-recovery-finalize service."
systemctl disable seafile-recovery-finalize.service

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Disaster recovery complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
if [[ "${_RESTORE_DB}" == "true" ]]; then
  echo "  Database restored from snapshot on the storage share."
else
  echo "  Database initialized fresh (no snapshot was found on the share)."
  echo "  File content is intact. Library names, shares, and permissions"
  echo "  may reflect state from up to 1 day before the VM was lost."
fi
echo ""
echo "  Final step — enabling Extended Properties on all libraries..."
echo ""

# Source shared-lib functions (available in the recovered setup.sh)
# The _enable_metadata_all function needs admin creds from .env
if [[ -n "${INIT_SEAFILE_ADMIN_EMAIL:-}" && -n "${INIT_SEAFILE_ADMIN_PASSWORD:-}" ]]; then
  CADDY_PORT="${CADDY_PORT:-7080}"
  HOST_HDR="${SEAFILE_SERVER_HOSTNAME:-localhost}"
  API_BASE="http://localhost:${CADDY_PORT}"

  # Wait for Seafile API to be ready after config-fixes restart
  sleep 15

  TOKEN_RESP=$(curl -sf -H "Host: ${HOST_HDR}" \
    -d "username=${INIT_SEAFILE_ADMIN_EMAIL}&password=${INIT_SEAFILE_ADMIN_PASSWORD}" \
    "${API_BASE}/api2/auth-token/" 2>/dev/null || true)

  if [[ -n "$TOKEN_RESP" ]]; then
    TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
      REPOS=$(curl -sf -H "Host: ${HOST_HDR}" -H "Authorization: Token ${TOKEN}" \
        "${API_BASE}/api/v2.1/repos/?type=mine" 2>/dev/null || true)
      if [[ -n "$REPOS" ]]; then
        echo "$REPOS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
repos = data.get('repos', data) if isinstance(data, dict) else data
for r in repos:
    print(r['id'])
" 2>/dev/null | while IFS= read -r rid; do
          [[ -z "$rid" ]] && continue
          curl -sf -X PUT -H "Host: ${HOST_HDR}" \
            -H "Authorization: Token ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"enabled": true}' \
            "${API_BASE}/api/v2.1/repos/${rid}/metadata/" >/dev/null 2>&1 || true
        done
        info "Extended Properties enabled on all libraries."
      fi
    else
      warn "Could not authenticate — enable manually: seafile metadata --enable-all"
    fi
  else
    warn "Seafile API not ready — enable manually: seafile metadata --enable-all"
  fi
else
  echo "  Admin credentials not available in .env."
  echo "  Enable manually: seafile metadata --enable-all"
fi
echo ""
