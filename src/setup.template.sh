#!/bin/bash
# =============================================================================
# Seafile 13 — Unified Setup Script (install + recover)
# =============================================================================
# Handles both fresh installs and disaster recovery from a single codebase.
# Called by seafile-deploy.sh with SETUP_MODE=install or SETUP_MODE=recover.
#
# MODE=install: Sources .env from /opt/seafile/.env (placed by wizard),
#               installs everything, deploys the stack.
# MODE=recover: Early-mounts storage to restore .env, then runs the same
#               setup phases, then installs recovery-finalize service.
# =============================================================================

set -e
trap 'echo -e "\n${RED}[ERROR]${NC}  setup.sh failed at line $LINENO — check output above."; exit 1' ERR

# ---------------------------------------------------------------------------
# Shared library (defaults, helpers, normalize, menu, etc.)
# ---------------------------------------------------------------------------
{{EMBED:src/shared-lib.sh}}

info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
heading() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

[ "$EUID" -ne 0 ] && error "Please run as root or with sudo."

# ---------------------------------------------------------------------------
# Determine mode
# ---------------------------------------------------------------------------
SETUP_MODE="${SETUP_MODE:-install}"
if [[ "$SETUP_MODE" != "install" && "$SETUP_MODE" != "recover" ]]; then
  error "Unknown SETUP_MODE '$SETUP_MODE'. Must be 'install' or 'recover'."
fi

ENV_FILE="/opt/seafile/.env"

# =============================================================================
# MODE-SPECIFIC PREAMBLE
# =============================================================================

if [[ "$SETUP_MODE" == "recover" ]]; then
  # ── Recovery: early-mount storage to restore .env ─────────────────────────
  STORAGE_TYPE="${STORAGE_TYPE:-nfs}"
  STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/seafile_nfs}"
  NFS_SERVER="${NFS_SERVER:-}"
  NFS_EXPORT="${NFS_EXPORT:-}"
  SMB_SERVER="${SMB_SERVER:-}"
  SMB_SHARE="${SMB_SHARE:-}"
  SMB_USERNAME="${SMB_USERNAME:-}"
  SMB_PASSWORD="${SMB_PASSWORD:-}"
  SMB_DOMAIN="${SMB_DOMAIN:-}"
  GLUSTER_SERVER="${GLUSTER_SERVER:-}"
  GLUSTER_VOLUME="${GLUSTER_VOLUME:-}"
  ISCSI_PORTAL="${ISCSI_PORTAL:-}"
  ISCSI_TARGET_IQN="${ISCSI_TARGET_IQN:-}"
  ISCSI_FILESYSTEM="${ISCSI_FILESYSTEM:-ext4}"
  ISCSI_CHAP_USERNAME="${ISCSI_CHAP_USERNAME:-}"
  ISCSI_CHAP_PASSWORD="${ISCSI_CHAP_PASSWORD:-}"

  if [[ "$STORAGE_TYPE" == "local" ]]; then
    error "Recovery Mode requires network storage. STORAGE_TYPE=local cannot recover data from a lost VM."
  fi

  # Validate required storage vars
  case "$STORAGE_TYPE" in
    nfs)
      [ -z "$NFS_SERVER" ] && error "NFS_SERVER is not set."
      [ -z "$NFS_EXPORT" ] && error "NFS_EXPORT is not set."
      ;;
    smb)
      [ -z "$SMB_SERVER"   ] && error "SMB_SERVER is not set."
      [ -z "$SMB_SHARE"    ] && error "SMB_SHARE is not set."
      [ -z "$SMB_USERNAME" ] && error "SMB_USERNAME is not set."
      [ -z "$SMB_PASSWORD" ] && error "SMB_PASSWORD is not set."
      ;;
    glusterfs)
      [ -z "$GLUSTER_SERVER" ] && error "GLUSTER_SERVER is not set."
      [ -z "$GLUSTER_VOLUME" ] && error "GLUSTER_VOLUME is not set."
      ;;
    iscsi)
      [ -z "$ISCSI_PORTAL"     ] && error "ISCSI_PORTAL is not set."
      [ -z "$ISCSI_TARGET_IQN" ] && error "ISCSI_TARGET_IQN is not set."
      ;;
    *) error "Unknown STORAGE_TYPE '${STORAGE_TYPE}'." ;;
  esac

  info "Starting Seafile disaster recovery on $(hostname)"
  case "$STORAGE_TYPE" in
    nfs)       info "NFS server:      $NFS_SERVER"; info "NFS export:      $NFS_EXPORT" ;;
    smb)       info "SMB server:      $SMB_SERVER"; info "SMB share:       //$SMB_SERVER/$SMB_SHARE" ;;
    glusterfs) info "Gluster server:  $GLUSTER_SERVER"; info "Gluster volume:  $GLUSTER_VOLUME" ;;
    iscsi)     info "iSCSI portal:    $ISCSI_PORTAL"; info "iSCSI IQN:       $ISCSI_TARGET_IQN" ;;
  esac
  info "Mount point:     $STORAGE_MOUNT"

  # Install storage client for early mount
  info "Installing storage client package..."
  apt-get update -qq
  case "$STORAGE_TYPE" in
    nfs)       apt-get install -y -qq nfs-common ;;
    smb)       apt-get install -y -qq cifs-utils ;;
    glusterfs) apt-get install -y -qq glusterfs-client ;;
    iscsi)     apt-get install -y -qq open-iscsi ;;
  esac

  # Early mount — minimal options, just enough to read the .env backup
  _SM="$STORAGE_MOUNT"
  mkdir -p "$_SM"
  if mountpoint -q "$_SM" 2>/dev/null; then
    info "Storage already mounted at $_SM."
  else
    info "Mounting storage at $_SM..."
    case "$STORAGE_TYPE" in
      nfs)
        mount -t nfs -o rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nfsvers=4 \
          "${NFS_SERVER}:${NFS_EXPORT}" "$_SM" \
          || error "Failed to mount NFS share. Check NFS_SERVER and NFS_EXPORT."
        ;;
      smb)
        printf 'username=%s\npassword=%s\n' "$SMB_USERNAME" "$SMB_PASSWORD" \
          > /etc/seafile-smb-credentials
        [[ -n "$SMB_DOMAIN" ]] && echo "domain=${SMB_DOMAIN}" >> /etc/seafile-smb-credentials
        chmod 600 /etc/seafile-smb-credentials
        mount -t cifs "//${SMB_SERVER}/${SMB_SHARE}" "$_SM" \
          -o "credentials=/etc/seafile-smb-credentials,uid=0,gid=0,file_mode=0700,dir_mode=0700" \
          || error "Failed to mount SMB share."
        ;;
      glusterfs)
        mount -t glusterfs "${GLUSTER_SERVER}:/${GLUSTER_VOLUME}" "$_SM" \
          || error "Failed to mount GlusterFS volume."
        ;;
      iscsi)
        iscsiadm -m discovery -t sendtargets -p "$ISCSI_PORTAL" \
          || error "iSCSI discovery failed."
        if [[ -n "${ISCSI_CHAP_USERNAME:-}" && -n "${ISCSI_CHAP_PASSWORD:-}" ]]; then
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.authmethod -v CHAP 2>/dev/null || true
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.username    -v "$ISCSI_CHAP_USERNAME" 2>/dev/null || true
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.password    -v "$ISCSI_CHAP_PASSWORD" 2>/dev/null || true
        fi
        iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" --login \
          || error "iSCSI login failed."
        _dev=""
        for _i in {1..15}; do
          _dev=$(iscsiadm -m session -P 3 2>/dev/null | grep "Attached scsi disk" | awk '{print $NF}' | head -1 || true)
          [[ -n "$_dev" ]] && break; sleep 1
        done
        [[ -z "$_dev" ]] && error "iSCSI block device did not appear."
        mount "/dev/${_dev}" "$_SM" \
          || error "Failed to mount iSCSI device /dev/${_dev}."
        ;;
    esac
    info "Storage mounted at $_SM."
  fi

  # Restore .env from storage backup
  STORAGE_ENV="${STORAGE_MOUNT}/.env"
  [ ! -f "$STORAGE_ENV" ] && error ".env backup not found at $STORAGE_ENV.
  If the backup was lost, recreate /opt/seafile/.env manually and run Fresh Install instead."

  info "Restoring .env from storage backup..."
  mkdir -p /opt/seafile
  cp "$STORAGE_ENV" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  info "Restored $ENV_FILE from $STORAGE_ENV"

  # Source the restored .env
  _load_env "$ENV_FILE"
  info ".env loaded successfully."

else
  # ── Fresh Install: source existing .env ───────────────────────────────────
  [ ! -f "$ENV_FILE" ] && error ".env file not found at $ENV_FILE.
  Run seafile-deploy.sh to create one via the guided wizard."

  _load_env "$ENV_FILE"
  _normalize_env "$ENV_FILE"
  _load_env "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  info "Permissions set to 600 on $ENV_FILE"

  STORAGE_TYPE="${STORAGE_TYPE:-nfs}"
  STORAGE_MOUNT="${SEAFILE_VOLUME:-/mnt/seafile_nfs}"

  # Validate storage vars
  case "$STORAGE_TYPE" in
    nfs)
      [ -z "$NFS_SERVER" ] && error "NFS_SERVER is not set in $ENV_FILE."
      [ -z "$NFS_EXPORT" ] && error "NFS_EXPORT is not set in $ENV_FILE."
      ;;
    smb)
      [ -z "$SMB_SERVER"   ] && error "SMB_SERVER is not set in $ENV_FILE."
      [ -z "$SMB_SHARE"    ] && error "SMB_SHARE is not set in $ENV_FILE."
      [ -z "$SMB_USERNAME" ] && error "SMB_USERNAME is not set in $ENV_FILE."
      [ -z "$SMB_PASSWORD" ] && error "SMB_PASSWORD is not set in $ENV_FILE."
      ;;
    glusterfs)
      [ -z "$GLUSTER_SERVER" ] && error "GLUSTER_SERVER is not set in $ENV_FILE."
      [ -z "$GLUSTER_VOLUME" ] && error "GLUSTER_VOLUME is not set in $ENV_FILE."
      ;;
    iscsi)
      [ -z "$ISCSI_PORTAL"     ] && error "ISCSI_PORTAL is not set in $ENV_FILE."
      [ -z "$ISCSI_TARGET_IQN" ] && error "ISCSI_TARGET_IQN is not set in $ENV_FILE."
      ;;
    local)
      : # No network credentials required
      ;;
    *)
      error "Unknown STORAGE_TYPE '${STORAGE_TYPE}' in $ENV_FILE."
      ;;
  esac

  info "Starting Seafile host preparation on $(hostname)"
  info "Storage type:    $STORAGE_TYPE"
  case "$STORAGE_TYPE" in
    nfs)       info "NFS server:      $NFS_SERVER"; info "NFS export:      $NFS_EXPORT" ;;
    smb)       info "SMB server:      $SMB_SERVER"; info "SMB share:       //$SMB_SERVER/$SMB_SHARE" ;;
    glusterfs) info "Gluster server:  $GLUSTER_SERVER"; info "Gluster volume:  $GLUSTER_VOLUME" ;;
    iscsi)     info "iSCSI portal:    $ISCSI_PORTAL"; info "iSCSI IQN:       $ISCSI_TARGET_IQN" ;;
    local)     info "Storage path:    $STORAGE_MOUNT (local disk — no network mount)" ;;
  esac
  info "Mount point:     $STORAGE_MOUNT"
fi

# =============================================================================
# PHASE LIST (built dynamically based on mode)
# =============================================================================
_PHASES=(
  "Update and upgrade system packages"
  "Install required packages (Docker, storage client, inotify-tools, etc.)"
  "Enable automatic security updates (unattended-upgrades)"
  "Enable fail2ban SSH brute-force protection"
  "Create host directories and write Caddyfile"
  "Mount network storage and add to /etc/fstab"
  "Install Portainer Agent"
  "Install services (env-sync, storage-sync, CLI)"
)
if [[ "$SETUP_MODE" == "install" ]]; then
  _PHASES+=(
    "Write scripts to /opt (config-fixes, update.sh, docker-compose.yml)"
    "Deploy stack natively via Docker Compose (skipped when PORTAINER_MANAGED=true)"
    "Set up GitOps integration (skipped unless GITOPS_INTEGRATION=true)"
  )
else
  _PHASES+=(
    "Restore scripts from storage backup (config-fixes, update.sh)"
    "Install seafile-recovery-finalize service"
  )
fi
_SELECTED=()
for _ in "${_PHASES[@]}"; do _SELECTED+=(true); done

# Show menu unless called with --yes
if [[ "${1:-}" != "--yes" ]]; then
  _run_phase_menu "setup.sh — $SETUP_MODE mode"
fi

_START_TIME=$SECONDS

# =============================================================================
# PHASE 0: System update
# =============================================================================
if [[ "${_SELECTED[0]}" == "true" ]]; then
heading "System update"
info "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
info "System packages up to date."
fi

# =============================================================================
# PHASE 1: Install required packages
# =============================================================================
if [[ "${_SELECTED[1]}" == "true" ]]; then
heading "Installing required packages"
info "Installing required packages..."
apt-get install -y -qq \
  curl wget gnupg lsb-release ca-certificates apt-transport-https \
  openssl python3 jq bc git \
  inotify-tools fail2ban unattended-upgrades

# Storage-type-specific package
case "${STORAGE_TYPE:-nfs}" in
  nfs)       apt-get install -y -qq nfs-common ;;
  smb)       apt-get install -y -qq cifs-utils ;;
  glusterfs) apt-get install -y -qq glusterfs-client ;;
  iscsi)     apt-get install -y -qq open-iscsi ;;
  local)     : ;;
esac
info "Packages installed."

# --- Install Docker if not already present ---
if command -v docker &>/dev/null; then
  info "Docker already installed: $(docker --version)"
else
  info "Installing Docker from official repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  info "Docker installed: $(docker --version)"
  info "Docker Compose installed: $(docker compose version)"
fi
fi

# =============================================================================
# PHASE 2: Automatic security updates
# =============================================================================
if [[ "${_SELECTED[2]}" == "true" ]]; then
heading "Automatic security updates"
info "Enabling unattended security upgrades..."
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
info "Unattended upgrades enabled."
fi

# =============================================================================
# PHASE 3: fail2ban
# =============================================================================
if [[ "${_SELECTED[3]}" == "true" ]]; then
heading "fail2ban"
info "Enabling fail2ban..."
systemctl enable fail2ban
systemctl start fail2ban
info "fail2ban enabled."
fi

# =============================================================================
# PHASE 4: Create host directories and write Caddyfile
# =============================================================================
if [[ "${_SELECTED[4]}" == "true" ]]; then
heading "Host directories and Caddyfile"
info "Creating Seafile host directories..."
mkdir -p /opt/seafile-caddy/data
mkdir -p /opt/seafile-caddy/config
mkdir -p /opt/seadoc-data
mkdir -p "${THUMBNAIL_PATH:-/opt/seafile-thumbnails}"
mkdir -p "${METADATA_PATH:-/opt/seafile-metadata}"
if [[ "$SETUP_MODE" == "install" ]]; then
  mkdir -p "$STORAGE_MOUNT"
fi

info "Writing placeholder Caddyfile..."
# Write a minimal Caddyfile so Caddy can start without crash-looping.
# The real Caddyfile is generated by seafile-config-fixes.sh based on
# PROXY_TYPE and SEAFILE_SERVER_HOSTNAME from .env.
cat > /opt/seafile-caddy/Caddyfile << 'CADDYEOF'
:80 {
    respond "Seafile is starting — configuration in progress..." 200
}
CADDYEOF
info "Placeholder Caddyfile written (config-fixes will generate the real one)"
fi

# =============================================================================
# PHASE 5: Mount storage and add to /etc/fstab
# =============================================================================
if [[ "${_SELECTED[5]}" == "true" ]]; then
heading "Storage mount"

# =============================================================================
# Unified storage mount function — handles all five storage types
# =============================================================================
_mount_storage() {
  local mount_point="$1"
  local is_first_install="${2:-false}"    # true = may format iSCSI
  local stype="${STORAGE_TYPE:-nfs}"
  local opts

  mkdir -p "$mount_point"

  if [[ "$stype" == "local" ]]; then
    info "Storage type is local — using $mount_point as data directory (no network mount)."
    info "Local storage directory ready at $mount_point."
    return 0
  fi

  if mountpoint -q "$mount_point" 2>/dev/null; then
    info "Storage already mounted at $mount_point."
  else
    case "$stype" in
      nfs)
        opts="${NFS_OPTIONS:-auto,x-systemd.automount,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nofail}"
        info "Mounting NFS share ${NFS_SERVER}:${NFS_EXPORT} at ${mount_point}..."
        if ! grep -qF "$mount_point" /etc/fstab; then
          echo "${NFS_SERVER}:${NFS_EXPORT} ${mount_point} nfs ${opts} 0 0" >> /etc/fstab
          info "Added NFS entry to /etc/fstab."
        else
          warn "fstab entry already exists for $mount_point — skipping fstab write."
        fi
        systemctl daemon-reload
        mount "$mount_point" \
          || error "Failed to mount NFS share. Check NFS_SERVER and NFS_EXPORT, and ensure no_root_squash is set on the NFS server."
        info "NFS share mounted successfully."
        ;;

      smb)
        opts="${SMB_OPTIONS:-auto,x-systemd.automount,_netdev,nofail,uid=0,gid=0,file_mode=0700,dir_mode=0700}"
        local creds_file="/etc/seafile-smb-credentials"
        if [[ ! -f "$creds_file" ]]; then
          printf 'username=%s\npassword=%s\n' "$SMB_USERNAME" "$SMB_PASSWORD" > "$creds_file"
          [[ -n "${SMB_DOMAIN:-}" ]] && echo "domain=${SMB_DOMAIN}" >> "$creds_file"
          chmod 600 "$creds_file"
          info "SMB credentials written to $creds_file (chmod 600)"
        fi
        info "Mounting SMB share //${SMB_SERVER}/${SMB_SHARE} at ${mount_point}..."
        if ! grep -qF "$mount_point" /etc/fstab; then
          echo "//${SMB_SERVER}/${SMB_SHARE} ${mount_point} cifs credentials=${creds_file},${opts} 0 0" >> /etc/fstab
          info "Added SMB entry to /etc/fstab."
        else
          warn "fstab entry already exists for $mount_point — skipping fstab write."
        fi
        systemctl daemon-reload
        mount "$mount_point" \
          || error "Failed to mount SMB share. Check SMB_SERVER, SMB_SHARE, SMB_USERNAME, and SMB_PASSWORD."
        info "SMB share mounted successfully."
        ;;

      glusterfs)
        opts="${GLUSTER_OPTIONS:-defaults,_netdev,nofail}"
        info "Mounting GlusterFS volume ${GLUSTER_SERVER}:/${GLUSTER_VOLUME} at ${mount_point}..."
        if ! grep -qF "$mount_point" /etc/fstab; then
          echo "${GLUSTER_SERVER}:/${GLUSTER_VOLUME} ${mount_point} glusterfs ${opts} 0 0" >> /etc/fstab
          info "Added GlusterFS entry to /etc/fstab."
        else
          warn "fstab entry already exists for $mount_point — skipping fstab write."
        fi
        systemctl daemon-reload
        mount "$mount_point" \
          || error "Failed to mount GlusterFS volume. Check GLUSTER_SERVER and GLUSTER_VOLUME."
        info "GlusterFS volume mounted successfully."
        ;;

      iscsi)
        opts="${ISCSI_OPTIONS:-_netdev,auto,nofail}"
        local _fs="${ISCSI_FILESYSTEM:-ext4}"
        info "Discovering iSCSI targets at ${ISCSI_PORTAL}..."
        iscsiadm -m discovery -t sendtargets -p "$ISCSI_PORTAL" \
          || error "iSCSI discovery failed. Check ISCSI_PORTAL."

        if [[ -n "${ISCSI_CHAP_USERNAME:-}" && -n "${ISCSI_CHAP_PASSWORD:-}" ]]; then
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.authmethod -v CHAP 2>/dev/null || true
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.username    -v "$ISCSI_CHAP_USERNAME" 2>/dev/null || true
          iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" \
            --op=update -n node.session.auth.password    -v "$ISCSI_CHAP_PASSWORD" 2>/dev/null || true
        fi

        info "Logging in to iSCSI target ${ISCSI_TARGET_IQN}..."
        iscsiadm -m node -T "$ISCSI_TARGET_IQN" -p "$ISCSI_PORTAL" --login \
          || error "iSCSI login failed. Check ISCSI_TARGET_IQN."

        # Wait for block device
        local _dev=""
        for _i in {1..15}; do
          _dev=$(iscsiadm -m session -P 3 2>/dev/null | grep "Attached scsi disk" | awk '{print $NF}' | head -1 || true)
          [[ -n "$_dev" ]] && break; sleep 1
        done
        [[ -z "$_dev" ]] && error "iSCSI block device did not appear."
        info "Block device: /dev/${_dev}"

        # ── CRITICAL: Only format on FIRST INSTALL — never on recovery ──
        if [[ "$is_first_install" == "true" ]]; then
          if ! blkid "/dev/${_dev}" &>/dev/null; then
            warn "Block device has no filesystem — formatting as ${_fs}..."
            mkfs -t "$_fs" "/dev/${_dev}" \
              || error "Failed to format /dev/${_dev}."
            info "Formatted /dev/${_dev} as ${_fs}."
          else
            info "Block device already has a filesystem — skipping format."
          fi
        fi

        mount "/dev/${_dev}" "$mount_point" \
          || error "Failed to mount iSCSI device /dev/${_dev}."
        info "iSCSI device mounted at $mount_point."

        # Write fstab entry using UUID
        local _uuid
        _uuid=$(blkid -s UUID -o value "/dev/${_dev}" 2>/dev/null || true)
        if [[ -n "$_uuid" ]] && ! grep -qF "UUID=${_uuid}" /etc/fstab; then
          echo "UUID=${_uuid} ${mount_point} ${_fs} ${opts} 0 2" >> /etc/fstab
          info "Added iSCSI fstab entry (UUID=${_uuid})."
        fi
        ;;

      *)
        error "Unknown STORAGE_TYPE '${stype}'."
        ;;
    esac
  fi

  # Write fstab entry if storage was already mounted (e.g. recovery early mount)
  if mountpoint -q "$mount_point" 2>/dev/null && ! grep -qF "$mount_point" /etc/fstab; then
    info "Storage mounted — writing fstab entry..."
    case "${STORAGE_TYPE:-nfs}" in
      nfs)
        local _opts="${NFS_OPTIONS:-auto,x-systemd.automount,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nofail}"
        echo "${NFS_SERVER}:${NFS_EXPORT} ${mount_point} nfs ${_opts} 0 0" >> /etc/fstab
        ;;
      smb)
        local _opts="${SMB_OPTIONS:-auto,x-systemd.automount,_netdev,nofail,uid=0,gid=0,file_mode=0700,dir_mode=0700}"
        echo "//${SMB_SERVER}/${SMB_SHARE} ${mount_point} cifs credentials=/etc/seafile-smb-credentials,${_opts} 0 0" >> /etc/fstab
        ;;
      glusterfs)
        local _opts="${GLUSTER_OPTIONS:-defaults,_netdev,nofail}"
        echo "${GLUSTER_SERVER}:/${GLUSTER_VOLUME} ${mount_point} glusterfs ${_opts} 0 0" >> /etc/fstab
        ;;
      iscsi)
        local _dev _uuid _opts="${ISCSI_OPTIONS:-_netdev,auto,nofail}" _fs="${ISCSI_FILESYSTEM:-ext4}"
        _dev=$(iscsiadm -m session -P 3 2>/dev/null | grep "Attached scsi disk" | awk '{print $NF}' | head -1 || true)
        _uuid=$(blkid -s UUID -o value "/dev/${_dev}" 2>/dev/null || true)
        [[ -n "$_uuid" ]] && echo "UUID=${_uuid} ${mount_point} ${_fs} ${_opts} 0 2" >> /etc/fstab
        ;;
    esac
    systemctl daemon-reload
    info "fstab entry written."
  fi
}

# Call the mount function
_is_first="false"
[[ "$SETUP_MODE" == "install" ]] && _is_first="true"
_mount_storage "${SEAFILE_VOLUME:-$STORAGE_MOUNT}" "$_is_first"

fi

# =============================================================================
# PHASE 6: Portainer Agent
# =============================================================================
if [[ "${_SELECTED[6]}" == "true" ]]; then
heading "Portainer Agent"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q portainer_agent; then
  info "Portainer Agent already running."
else
  info "Installing Portainer Agent..."
  docker volume create portainer_data 2>/dev/null || true
  docker run -d \
    --name portainer_agent \
    --restart=always \
    -p 9001:9001 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/agent:latest \
    && info "Portainer Agent installed and listening on port 9001." \
    || warn "Portainer Agent install failed — you can add it manually later."
fi
fi

# =============================================================================
# PHASE 7: Install background services and CLI
# =============================================================================
if [[ "${_SELECTED[7]}" == "true" ]]; then
heading "Background services and CLI"

# --- env-sync service ---
SYNC_SCRIPT="/opt/seafile/seafile-env-sync.sh"
SYNC_SERVICE="/etc/systemd/system/seafile-env-sync.service"

if [ ! -f "$SYNC_SCRIPT" ]; then
  cat > "$SYNC_SCRIPT" << 'SYNSCRIPTEOF'
{{EMBED:scripts/env-sync/seafile-env-sync.sh}}
SYNSCRIPTEOF
  chmod +x "$SYNC_SCRIPT"
  info "Wrote $SYNC_SCRIPT"
else
  info "$SYNC_SCRIPT already exists — skipping."
fi

cat > "$SYNC_SERVICE" << 'SYNCSERVICEOF'
[Unit]
Description=Seafile .env Sync — mirrors /opt/seafile/.env to storage and restores on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/seafile/seafile-env-sync.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYNCSERVICEOF

systemctl daemon-reload
systemctl enable seafile-env-sync
systemctl start seafile-env-sync
info "seafile-env-sync service installed and started."

# --- storage-sync service (disabled until migration) ---
STORAGE_SYNC_SCRIPT="/opt/seafile/storage-sync.sh"
STORAGE_SYNC_SERVICE="/etc/systemd/system/seafile-storage-sync.service"

cat > "$STORAGE_SYNC_SCRIPT" << 'STORAGESYNCSCRIPT'
{{EMBED:scripts/storage-sync/seafile-storage-sync.sh}}
STORAGESYNCSCRIPT
chmod +x "$STORAGE_SYNC_SCRIPT"

cat > "$STORAGE_SYNC_SERVICE" << 'STORAGESYNCSERVICE'
{{EMBED:scripts/storage-sync/seafile-storage-sync.service}}
STORAGESYNCSERVICE

systemctl daemon-reload
info "Storage-sync service installed (will be enabled during storage migration)."

# --- seafile CLI ---
CLI_DEST="/usr/local/bin/seafile"
info "Installing seafile CLI to $CLI_DEST..."
cat > "$CLI_DEST" << 'CLIFILE'
{{EMBED:scripts/seafile-cli.sh}}
CLIFILE
chmod +x "$CLI_DEST"
info "seafile CLI installed at $CLI_DEST"

# --- config git server (Portainer-managed mode only) ---
CONFIG_SERVER_SCRIPT="/opt/seafile/seafile-config-server.sh"
CONFIG_SERVER_SERVICE="/etc/systemd/system/seafile-config-server.service"

cat > "$CONFIG_SERVER_SCRIPT" << 'CONFIGSERVEREOF'
{{EMBED:scripts/config-git-server/seafile-config-server.sh}}
CONFIGSERVEREOF
chmod +x "$CONFIG_SERVER_SCRIPT"

cat > "$CONFIG_SERVER_SERVICE" << 'CONFIGSERVICEOF'
{{EMBED:scripts/config-git-server/seafile-config-server.service}}
CONFIGSERVICEOF

if [[ "${PORTAINER_MANAGED:-false}" == "true" ]]; then
  systemctl daemon-reload
  systemctl enable seafile-config-server
  systemctl start seafile-config-server
  info "Config git server installed and started (port ${CONFIG_GIT_PORT:-9418})."
else
  info "Config git server installed (inactive — enable via PORTAINER_MANAGED=true)."
fi

fi

# =============================================================================
# MODE-SPECIFIC FINALE
# =============================================================================

if [[ "$SETUP_MODE" == "install" ]]; then
# ─────────────────────────────────────────────────────────────────────────────
# INSTALL FINALE
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${_SELECTED[8]}" == "true" ]]; then
heading "Writing scripts to /opt"

# --- seafile-config-fixes.sh ---
FIXES_FILE="/opt/seafile-config-fixes.sh"
STORAGE_BACKUP="${STORAGE_MOUNT}"

# Check if a config-fixes already exists on the storage share (e.g. leftover from previous install)
STORAGE_FIXES="${STORAGE_BACKUP}/seafile-config-fixes.sh"
if [ ! -f "$FIXES_FILE" ]; then
  if [ -f "$STORAGE_FIXES" ]; then
    info "Restoring seafile-config-fixes.sh from storage backup..."
    cp "$STORAGE_FIXES" "$FIXES_FILE"
    chmod +x "$FIXES_FILE"
  else
    cat > "$FIXES_FILE" << 'FIXESEMBEDEOF'
{{EMBED:scripts/seafile-config-fixes.sh}}
FIXESEMBEDEOF
    chmod +x "$FIXES_FILE"
    info "Wrote $FIXES_FILE"
  fi
fi

# --- update.sh ---
UPDATE_FILE="/opt/update.sh"
STORAGE_UPDATE="${STORAGE_MOUNT}/update.sh"

if [ ! -f "$UPDATE_FILE" ]; then
  cat > "$UPDATE_FILE" << 'UPDATESHEOF'
{{EMBED:scripts/update.sh}}
UPDATESHEOF
  chmod +x "$UPDATE_FILE"
  info "Wrote $UPDATE_FILE"
fi

# Back up to storage
if [ -d "$STORAGE_MOUNT" ] && mountpoint -q "$STORAGE_MOUNT"; then
  cp "$FIXES_FILE" "$STORAGE_FIXES" 2>/dev/null && info "Backed up config-fixes to storage." || true
  cp "$UPDATE_FILE" "$STORAGE_UPDATE" 2>/dev/null && chmod +x "$STORAGE_UPDATE" && info "Backed up update.sh to storage." || true
fi

fi

if [[ "${_SELECTED[9]}" == "true" ]]; then
heading "Deploying stack"

# Load .env one more time to ensure all generated secrets are available
[[ -f "$ENV_FILE" ]] && _load_env "$ENV_FILE" 2>/dev/null || true

if [[ "${PORTAINER_MANAGED:-false}" == "true" ]]; then
  info "PORTAINER_MANAGED=true — skipping native deploy. Deploy the stack via Portainer."
  info "See README — Portainer-Managed Deployment for instructions."
else
  mkdir -p /opt/seafile
  COMPOSE_FILE="/opt/seafile/docker-compose.yml"
  cat > "$COMPOSE_FILE" << 'COMPOSEEOF'
{{EMBED:src/docker-compose.yml}}
COMPOSEEOF
  info "docker-compose.yml written to $COMPOSE_FILE."

  _compute_profiles
  info "Active profiles: ${COMPOSE_PROFILES}"
  info "Starting stack with docker compose..."
  if COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1; then
    info "Stack started successfully."
  else
    warn "docker compose up reported an issue — check: docker ps && docker logs seafile"
  fi

  # Wait for seafile container to be healthy
  info "Waiting for Seafile to initialize (this may take 1-3 minutes on first run)..."
  _retries=60
  while [[ $_retries -gt 0 ]]; do
    if docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -q "seafile.*healthy\|seafile.*Up"; then
      info "Seafile container is up."
      break
    fi
    sleep 5
    _retries=$((_retries - 1))
  done

  # Run config-fixes
  if [[ -f "/opt/seafile-config-fixes.sh" ]]; then
    info "Running seafile-config-fixes.sh..."
    if bash /opt/seafile-config-fixes.sh --yes; then
      info "Config files applied and containers restarted."
    else
      warn "seafile-config-fixes.sh reported an error — check output above."
    fi
  fi

  # Enable Extended Properties on all libraries (if any exist)
  # Wait briefly for Seafile to finish initializing after config-fixes restart
  sleep 10
  _enable_metadata_all

  # Save .env snapshot for future diffs
  cp "$ENV_FILE" /opt/seafile/.env.snapshot
  chmod 600 /opt/seafile/.env.snapshot
fi

fi

if [[ "${_SELECTED[10]}" == "true" ]]; then
heading "GitOps integration"

if [[ "${GITOPS_INTEGRATION:-false}" != "true" ]]; then
  info "GITOPS_INTEGRATION is not true — skipping."
else
  GITOPS_MISSING=()
  [ -z "${GITOPS_REPO_URL:-}" ]       && GITOPS_MISSING+=("GITOPS_REPO_URL")
  [ -z "${GITOPS_TOKEN:-}" ]          && GITOPS_MISSING+=("GITOPS_TOKEN")
  [ -z "${GITOPS_WEBHOOK_SECRET:-}" ] && GITOPS_MISSING+=("GITOPS_WEBHOOK_SECRET")

  if [[ ${#GITOPS_MISSING[@]} -gt 0 ]]; then
    warn "GitOps skipped — missing: ${GITOPS_MISSING[*]}"
  else
    GITOPS_CLONE="${GITOPS_CLONE_PATH:-/opt/seafile-gitops}"

    # Test repo reachability
    AUTHED_URL=$(echo "${GITOPS_REPO_URL}" | sed "s|://|://oauth2:${GITOPS_TOKEN}@|")
    if ! git ls-remote "$AUTHED_URL" HEAD &>/dev/null; then
      warn "Cannot reach GitOps repo — skipping."
    else
      # Clone the repo
      if [ -d "$GITOPS_CLONE/.git" ]; then
        info "GitOps repo already cloned at $GITOPS_CLONE."
      else
        mkdir -p "$GITOPS_CLONE"
        git clone -b "${GITOPS_BRANCH:-main}" "$AUTHED_URL" "$GITOPS_CLONE" \
          || { warn "git clone failed — GitOps setup skipped."; }
      fi

      # Push current .env and docker-compose.yml as initial commit
      if [ -d "$GITOPS_CLONE/.git" ]; then
        cp "$ENV_FILE" "$GITOPS_CLONE/.env" 2>/dev/null || true
        [[ -f /opt/seafile/docker-compose.yml ]] && \
          cp /opt/seafile/docker-compose.yml "$GITOPS_CLONE/docker-compose.yml" 2>/dev/null || true
        cd "$GITOPS_CLONE"
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
          git commit -m "Initial deployment configuration" --quiet 2>/dev/null || true
          if git push origin "${GITOPS_BRANCH:-main}" --quiet 2>/dev/null; then
            info "Pushed initial .env to GitOps repo."
          else
            warn "Could not push to repo — check token permissions."
          fi
        fi
        cd /
      fi

      if [ -d "$GITOPS_CLONE/.git" ]; then
        # Deploy the listener script
        GITOPS_SCRIPT="/opt/seafile/seafile-gitops-sync.py"
        GITOPS_SERVICE="/etc/systemd/system/seafile-gitops-sync.service"

        cat > "$GITOPS_SCRIPT" << 'GITOPSPYEOF'
{{EMBED:scripts/gitops/seafile-gitops-sync.py}}
GITOPSPYEOF
        chmod +x "$GITOPS_SCRIPT"

        cat > "$GITOPS_SERVICE" << 'GITOPSSERVICEOF'
{{EMBED:scripts/gitops/seafile-gitops-sync.service}}
GITOPSSERVICEOF

        systemctl daemon-reload
        systemctl enable seafile-gitops-sync
        systemctl start seafile-gitops-sync
        info "GitOps webhook listener installed and started (port ${GITOPS_WEBHOOK_PORT:-9002})."

        # --- Auto-create Gitea webhook ---
        # Parse owner/repo from URL: https://host/owner/repo.git
        _REPO_PATH=$(echo "${GITOPS_REPO_URL}" | sed 's|.*://[^/]*/||' | sed 's|\.git$||')
        _API_BASE=$(echo "${GITOPS_REPO_URL}" | sed 's|\(.*://[^/]*\)/.*|\1|')
        _VM_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        _WEBHOOK_URL="http://${_VM_IP}:${GITOPS_WEBHOOK_PORT:-9002}/webhook"

        if [[ -n "$_REPO_PATH" && -n "$_API_BASE" && -n "${GITOPS_WEBHOOK_SECRET:-}" ]]; then
          info "Creating webhook in git provider..."
          _WH_RESULT=$(curl -sf -X POST \
            -H "Authorization: token ${GITOPS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
              \"type\": \"gitea\",
              \"config\": {
                \"url\": \"${_WEBHOOK_URL}\",
                \"content_type\": \"json\",
                \"secret\": \"${GITOPS_WEBHOOK_SECRET}\"
              },
              \"events\": [\"push\"],
              \"active\": true
            }" \
            "${_API_BASE}/api/v1/repos/${_REPO_PATH}/hooks" 2>/dev/null || true)

          if [[ -n "$_WH_RESULT" ]] && echo "$_WH_RESULT" | python3 -c "import sys,json; json.load(sys.stdin)['id']" &>/dev/null; then
            info "Webhook created automatically in git repository."
          else
            warn "Could not auto-create webhook (may not be a Gitea instance)."
            warn "Create it manually in your git provider:"
            warn "  URL:     ${_WEBHOOK_URL}"
            warn "  Secret:  ${GITOPS_WEBHOOK_SECRET}"
            warn "  Events:  Push events only"
          fi
        else
          info "Webhook setup — add this to your git provider:"
          info "  URL:     ${_WEBHOOK_URL}"
          info "  Secret:  ${GITOPS_WEBHOOK_SECRET}"
          info "  Events:  Push events only"
        fi
      fi
    fi
  fi
fi

fi

  # ── Install complete message ──────────────────────────────────────────────
  if [[ "${PORTAINER_MANAGED:-false}" == "true" ]]; then
    echo ""
    echo -e "  ${GREEN}${BOLD}Machine setup complete!${NC}"
    echo ""
    echo "  Next steps:"
    echo "  1. Open your Portainer instance"
    echo "  2. Deploy the stack in Portainer:"
    echo "       - Environment → local → Stacks → Add stack"
    echo "       - Click Deploy the stack"
    echo "       - See README.md (Portainer-Managed Deployment) for details"
    echo ""
  else
    echo ""
    echo -e "  ${GREEN}${BOLD}Deployment complete!${NC}"
    echo ""
  fi

else
# ─────────────────────────────────────────────────────────────────────────────
# RECOVER FINALE
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${_SELECTED[8]}" == "true" ]]; then
heading "Restoring scripts from storage backup"

# --- seafile-config-fixes.sh ---
FIXES_FILE="/opt/seafile-config-fixes.sh"
STORAGE_FIXES="${SEAFILE_VOLUME:-/mnt/seafile_nfs}/seafile-config-fixes.sh"
[ ! -f "$STORAGE_FIXES" ] && error "seafile-config-fixes.sh not found at $STORAGE_FIXES.
  It should have been backed up automatically. See README — Disaster Recovery."

cp "$STORAGE_FIXES" "$FIXES_FILE"
chmod +x "$FIXES_FILE"
info "Restored $FIXES_FILE from storage backup."

# --- update.sh ---
UPDATE_FILE="/opt/update.sh"
STORAGE_UPDATE="${SEAFILE_VOLUME:-/mnt/seafile_nfs}/update.sh"
if [ -f "$STORAGE_UPDATE" ]; then
  cp "$STORAGE_UPDATE" "$UPDATE_FILE"
  chmod +x "$UPDATE_FILE"
  info "Restored $UPDATE_FILE from storage backup."
else
  warn "update.sh not found at $STORAGE_UPDATE — skipping restore."
  warn "Run seafile-deploy.sh → Fresh Install to recreate it."
fi

# --- docker-compose.yml (write from embedded copy) ---
mkdir -p /opt/seafile
COMPOSE_FILE="/opt/seafile/docker-compose.yml"
cat > "$COMPOSE_FILE" << 'COMPOSEEOF'
{{EMBED:src/docker-compose.yml}}
COMPOSEEOF
info "docker-compose.yml written to $COMPOSE_FILE."

fi

if [[ "${_SELECTED[9]}" == "true" ]]; then
heading "Installing recovery finalizer"

FINALIZE_SCRIPT="/opt/seafile/seafile-recovery-finalize.sh"
FINALIZE_SERVICE="/etc/systemd/system/seafile-recovery-finalize.service"

info "Writing recovery finalizer script..."
cat > "$FINALIZE_SCRIPT" << 'FINALIZEEOF'
{{EMBED:scripts/recovery-finalize/seafile-recovery-finalize.sh}}
FINALIZEEOF
chmod +x "$FINALIZE_SCRIPT"
info "Wrote $FINALIZE_SCRIPT"

info "Installing seafile-recovery-finalize service..."
cat > "$FINALIZE_SERVICE" << SERVICEOF
[Unit]
Description=Seafile Recovery Finalize — restores DB and starts stack after VM rebuild
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/seafile/seafile-recovery-finalize.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEOF

systemctl daemon-reload
systemctl enable seafile-recovery-finalize.service
systemctl start seafile-recovery-finalize.service
info "seafile-recovery-finalize service installed and started."

  echo ""
  echo -e "  ${GREEN}${BOLD}Machine setup complete!${NC}"
  echo ""
  echo "  The recovery finalizer is now running in the background."
  echo "  It will:"
  echo "    1. Start the database container"
  echo "    2. Restore your database from the latest nightly snapshot"
  echo "    3. Bring up the full stack"
  echo "    4. Run seafile-config-fixes.sh"
  echo ""
  echo "  You can safely close this terminal. Follow progress with:"
  echo "    journalctl -u seafile-recovery-finalize -f"
  echo ""

fi

fi

# =============================================================================
# Initialize config history repo (both install and recovery)
# =============================================================================
_config_history_init
info "Config history initialized at $HISTORY_DIR"

_ELAPSED=$(( SECONDS - _START_TIME ))
info "Setup completed in $((_ELAPSED / 60))m $((_ELAPSED % 60))s."
