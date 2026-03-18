#!/bin/bash
# =============================================================================
# Seafile 13 — Unified Setup Script (install + recover + migrate)
# =============================================================================
# Handles fresh installs, disaster recovery, and migration from a single codebase.
# Called by seafile-deploy.sh with SETUP_MODE=install, recover, or migrate.
#
# MODE=install:  Sources .env from /opt/seafile/.env (placed by wizard),
#                installs everything, deploys the stack.
# MODE=recover:  Early-mounts storage to restore .env, then runs the same
#                setup phases, then installs recovery-finalize service.
# MODE=migrate:  Runs install phases 1-8, then imports data from an existing
#                Seafile instance (adopt in place, prepared backup, or SSH).
# =============================================================================

set -e
trap 'echo -e "\n${RED}[ERROR]${NC}  setup.sh failed at line $LINENO — check output above."; exit 1' ERR

# Suppress interactive prompts from apt/dpkg (unattended-upgrades config, etc.)
export DEBIAN_FRONTEND=noninteractive

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
if [[ "$SETUP_MODE" != "install" && "$SETUP_MODE" != "recover" && "$SETUP_MODE" != "migrate" ]]; then
  error "Unknown SETUP_MODE '$SETUP_MODE'. Must be 'install', 'recover', or 'migrate'."
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
if [[ "$SETUP_MODE" == "install" || "$SETUP_MODE" == "migrate" ]]; then
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
if [[ "$SETUP_MODE" == "install" || "$SETUP_MODE" == "migrate" ]]; then
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
[[ "$SETUP_MODE" == "install" || "$SETUP_MODE" == "migrate" ]] && _is_first="true"
_mount_storage "${SEAFILE_VOLUME:-$STORAGE_MOUNT}" "$_is_first"

# ── Mount backup destination (if BACKUP_ENABLED and not local type) ──────
if [[ "${BACKUP_ENABLED:-false}" == "true" ]]; then
  _BACKUP_MOUNT="${BACKUP_MOUNT:-/mnt/seafile_backup}"
  _BACKUP_STYPE="${BACKUP_STORAGE_TYPE:-nfs}"

  mkdir -p "$_BACKUP_MOUNT"

  if [[ "$_BACKUP_STYPE" == "local" ]]; then
    info "Backup storage type is local — using ${_BACKUP_MOUNT} directly."
    mkdir -p "$_BACKUP_MOUNT"
  elif mountpoint -q "$_BACKUP_MOUNT" 2>/dev/null; then
    info "Backup destination already mounted at $_BACKUP_MOUNT."
  else
    case "$_BACKUP_STYPE" in
      nfs)
        _bk_opts="auto,x-systemd.automount,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nofail"
        info "Mounting backup NFS share ${BACKUP_NFS_SERVER}:${BACKUP_NFS_EXPORT} at ${_BACKUP_MOUNT}..."
        if ! grep -qF "$_BACKUP_MOUNT" /etc/fstab; then
          echo "${BACKUP_NFS_SERVER}:${BACKUP_NFS_EXPORT} ${_BACKUP_MOUNT} nfs ${_bk_opts} 0 0" >> /etc/fstab
          info "Added backup NFS entry to /etc/fstab."
        fi
        systemctl daemon-reload
        mount "$_BACKUP_MOUNT" \
          || warn "Failed to mount backup NFS share — backups will not work until mount is fixed."
        ;;
      smb)
        _bk_opts="auto,x-systemd.automount,_netdev,nofail,uid=0,gid=0,file_mode=0700,dir_mode=0700"
        _bk_creds="/etc/seafile-backup-smb-credentials"
        if [[ ! -f "$_bk_creds" ]]; then
          printf 'username=%s\npassword=%s\n' "${BACKUP_SMB_USERNAME}" "${BACKUP_SMB_PASSWORD}" > "$_bk_creds"
          [[ -n "${BACKUP_SMB_DOMAIN:-}" ]] && echo "domain=${BACKUP_SMB_DOMAIN}" >> "$_bk_creds"
          chmod 600 "$_bk_creds"
        fi
        info "Mounting backup SMB share //${BACKUP_SMB_SERVER}/${BACKUP_SMB_SHARE} at ${_BACKUP_MOUNT}..."
        if ! grep -qF "$_BACKUP_MOUNT" /etc/fstab; then
          echo "//${BACKUP_SMB_SERVER}/${BACKUP_SMB_SHARE} ${_BACKUP_MOUNT} cifs credentials=${_bk_creds},${_bk_opts} 0 0" >> /etc/fstab
          info "Added backup SMB entry to /etc/fstab."
        fi
        systemctl daemon-reload
        mount "$_BACKUP_MOUNT" \
          || warn "Failed to mount backup SMB share — backups will not work until mount is fixed."
        ;;
    esac
  fi
  info "Backup destination ready at $_BACKUP_MOUNT."
fi

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
  # Don't start yet — config-history repo is initialized later in the Portainer
  # deploy block. The git server will be started there after the repo exists.
  info "Config git server installed (will start after repo initialization)."
else
  info "Config git server installed (inactive — Portainer deployment only)."
fi

# --- Web configuration panel ---
CONFIGUI_SCRIPT="/opt/seafile/seafile-config-ui.py"
CONFIGUI_HTML="/opt/seafile/config-ui.html"
CONFIGUI_SERVICE="/etc/systemd/system/seafile-config-ui.service"

cat > "$CONFIGUI_SCRIPT" << 'CONFIGUIPYEOF'
{{EMBED:scripts/config-ui/seafile-config-ui.py}}
CONFIGUIPYEOF
chmod +x "$CONFIGUI_SCRIPT"

cat > "$CONFIGUI_HTML" << 'CONFIGUIHTMLEOF'
{{EMBED:scripts/config-ui/config-ui.html}}
CONFIGUIHTMLEOF

cat > "$CONFIGUI_SERVICE" << 'CONFIGUISVCEOF'
{{EMBED:scripts/config-ui/seafile-config-ui.service}}
CONFIGUISVCEOF

systemctl daemon-reload
systemctl enable seafile-config-ui
systemctl start seafile-config-ui
info "Web configuration panel installed and started (port 9443)."

fi

# =============================================================================
# MODE-SPECIFIC FINALE
# =============================================================================

if [[ "$SETUP_MODE" == "install" || "$SETUP_MODE" == "migrate" ]]; then
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
  # Portainer mode is not compatible with migration — migration requires
  # controlling container startup order (start DB → import → start rest),
  # which Portainer can't do. Migrate with standard mode first, then
  # reinstall with Portainer mode.
  if [[ "$SETUP_MODE" == "migrate" ]]; then
    warn "PORTAINER_MANAGED=true is not compatible with migration mode."
    warn "Migration requires controlling container startup order."
    warn "Please run migration with standard deployment mode, then"
    warn "reinstall with Portainer deployment (option 4) afterward."
    error "Cannot proceed with PORTAINER_MANAGED=true in migrate mode."
  fi

  # Portainer-managed mode: write compose file and config, but don't start containers.
  # The user deploys the stack from their Portainer dashboard.
  mkdir -p /opt/seafile
  COMPOSE_FILE="/opt/seafile/docker-compose.yml"
  cat > "$COMPOSE_FILE" << 'COMPOSEEOF'
{{EMBED:src/docker-compose.yml}}
COMPOSEEOF
  info "docker-compose.yml written to $COMPOSE_FILE."

  # Initialize config-history repo before starting git server
  # (shared-lib's _config_history_init normally runs later in setup, but the
  # git server needs the repo to exist NOW for Portainer to pull from it)
  _config_history_init

  # Ensure the internal git server has initial content committed
  if [[ -d "/opt/seafile/.config-history/.git" ]]; then
    cd /opt/seafile/.config-history
    cp "$COMPOSE_FILE" docker-compose.yml 2>/dev/null || true
    cp "$ENV_FILE" .env 2>/dev/null || true
    git add -A && git commit -m "Initial commit for Portainer deployment" 2>/dev/null || true
    git update-server-info 2>/dev/null || true
    cd /
  fi

  # Start the internal git server so Portainer can pull immediately
  systemctl daemon-reload
  systemctl enable seafile-config-server 2>/dev/null || true
  systemctl start seafile-config-server 2>/dev/null || true
  info "Internal git server started for Portainer stack sync."

  # Run config-fixes to pre-generate Caddyfile and Seafile config files
  # Use --no-restart since containers aren't running yet
  if [[ -f "/opt/seafile-config-fixes.sh" ]]; then
    bash /opt/seafile-config-fixes.sh --yes --no-restart 2>&1 || true
    info "Config files pre-generated for first boot."
  fi

  # Install the finalizer service — it waits for the user to deploy from
  # Portainer, then automatically runs config-fixes after Seafile's init
  # completes. This is critical because Seafile's first-boot init overwrites
  # our pre-generated config files with its own defaults.
  FINALIZE_SCRIPT="/opt/seafile/seafile-recovery-finalize.sh"
  FINALIZE_SERVICE="/etc/systemd/system/seafile-recovery-finalize.service"
  if [[ ! -f "$FINALIZE_SCRIPT" ]]; then
    cat > "$FINALIZE_SCRIPT" << 'FINALIZEEOF'
{{EMBED:scripts/recovery-finalize/seafile-recovery-finalize.sh}}
FINALIZEEOF
    chmod +x "$FINALIZE_SCRIPT"
  fi
  cat > "$FINALIZE_SERVICE" << SERVICEOF
[Unit]
Description=Seafile Post-Deploy Finalize — waits for Portainer stack deploy, then applies config
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
  info "Post-deploy finalizer started — waiting for Portainer stack deployment."
  info "Follow progress: journalctl -u seafile-recovery-finalize -f"
else
  mkdir -p /opt/seafile
  COMPOSE_FILE="/opt/seafile/docker-compose.yml"
  cat > "$COMPOSE_FILE" << 'COMPOSEEOF'
{{EMBED:src/docker-compose.yml}}
COMPOSEEOF
  info "docker-compose.yml written to $COMPOSE_FILE."

  _compute_profiles
  info "Active profiles: ${COMPOSE_PROFILES}"

  # ── Clean stale Seafile state on fresh install ───────────────────────────
  # If a previous install attempt left data behind, clear everything so
  # Seafile's first-boot init (setup-seafile-mysql.py) runs cleanly.
  # NEVER do this in recovery mode — that data belongs to the user.
  # In migrate mode: skip for "adopt" (data exists and we want it),
  # clean for "prepared"/"ssh" (we're importing fresh data).
  # ────────────────────────────────────────────────────────────────────────
  if [[ "$SETUP_MODE" == "install" || ( "$SETUP_MODE" == "migrate" && "${MIGRATE_TYPE:-}" != "adopt" ) ]]; then
    _SF_VOL="${SEAFILE_VOLUME:-/opt/seafile-data}"
    _stale=false
    for _dir in "${_SF_VOL}/seafile-data" "${_SF_VOL}/seafile" "${_SF_VOL}/seahub-data"; do
      if [[ -d "$_dir" ]]; then
        info "Removing stale ${_dir} from previous install attempt..."
        rm -rf "$_dir"
        _stale=true
      fi
    done
    if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
      _DB_VOL="${DB_INTERNAL_VOLUME:-/opt/seafile-db}"
      if [[ -d "$_DB_VOL" ]] && ls "$_DB_VOL"/* &>/dev/null 2>&1; then
        info "Clearing stale database data at ${_DB_VOL}..."
        rm -rf "${_DB_VOL:?}"/*
        _stale=true
      fi
    fi
    if [[ "$_stale" == "true" ]]; then
      info "Cleaned stale state — Seafile will run first-boot initialization."
    fi
  fi

  # ═══════════════════════════════════════════════════════════════════════════
  # DEPLOY BRANCH: Fresh Install vs Migration
  # ═══════════════════════════════════════════════════════════════════════════

  if [[ "$SETUP_MODE" == "install" ]]; then
  # ── FRESH INSTALL: Staged startup ────────────────────────────────────────

  # ── Stage 1: Start database first ───────────────────────────────────────
  # Seafile's init script (setup-seafile-mysql.py) needs the database to be
  # accepting connections BEFORE the seafile container starts. If the DB
  # isn't ready, Seafile retries briefly then gives up and starts without
  # completing init — leaving empty databases and no config files.
  # ────────────────────────────────────────────────────────────────────────
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    info "Stage 1: Starting database container..."
    COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
    
    info "Waiting for database to accept connections..."
    _db_ready=false
    for _attempt in {1..30}; do
      if docker exec -e MYSQL_PWD="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" seafile-db mysqladmin ping -u root --silent 2>/dev/null; then
        _db_ready=true
        break
      fi
      sleep 3
    done
    if [[ "$_db_ready" == "true" ]]; then
      info "Database is ready."
    else
      warn "Database did not become ready in 90 seconds — Seafile init may fail."
      warn "Check: docker logs seafile-db"
    fi
  else
    info "Stage 1: External database — verifying connectivity..."
    _ext_auth=$(_mysql_auth_file "root" "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}")
    _db_ready=false
    for _attempt in {1..18}; do
      if mysql --defaults-extra-file="$_ext_auth" -h "${SEAFILE_MYSQL_DB_HOST}" \
          -P "${SEAFILE_MYSQL_DB_PORT:-3306}" -e "SELECT 1" &>/dev/null; then
        _db_ready=true
        break
      fi
      sleep 5
    done
    if [[ "$_db_ready" == "true" ]]; then
      info "External database is reachable."
    else
      warn "Cannot reach external database — Seafile init may fail."
    fi
  fi

  # ── Stage 2: Start Seafile container and wait for init ──────────────────
  info "Stage 2: Starting Seafile container for first-boot initialization..."
  COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile 2>&1

  info "Waiting for Seafile to initialize (this may take 1-3 minutes on first run)..."

  # Build mysql command for table checking
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    _mysql_cmd() {
      docker exec -e MYSQL_PWD="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" seafile-db mysql -u root "$@" 2>/dev/null
    }
  else
    _mysql_cmd() {
      mysql --defaults-extra-file="${_ext_auth}" -h "${SEAFILE_MYSQL_DB_HOST}" \
        -P "${SEAFILE_MYSQL_DB_PORT:-3306}" "$@" 2>/dev/null
    }
  fi

  # Wait for tables to appear in seahub_db (indicates init completed)
  if [[ "$_db_ready" == "true" && -n "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" ]]; then
    _tables_ready=false
    for _t_attempt in {1..90}; do
      _tcount=$(_mysql_cmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}';" 2>/dev/null || echo "0")
      if [[ "$_tcount" -gt 10 ]]; then
        info "Seafile initialization complete (${_tcount} tables in seahub_db)."
        _tables_ready=true
        break
      fi
      if (( _t_attempt % 6 == 0 )); then
        info "  Still waiting... (${_tcount} tables so far, need 10+)"
      fi
      sleep 5
    done
    if [[ "$_tables_ready" != "true" ]]; then
      warn "Timed out waiting for Seafile init (found ${_tcount:-0} tables after 7.5 minutes)."
      warn "Check: docker logs seafile"
    fi
  else
    info "Waiting 90s for Seafile first-boot initialization..."
    sleep 90
  fi

  # ── Stage 3: Start remaining containers ─────────────────────────────────
  info "Stage 3: Starting remaining containers..."
  if COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1; then
    info "All containers started."
  else
    warn "docker compose up reported an issue — check: docker ps && docker logs seafile"
  fi
  sleep 10

  elif [[ "$SETUP_MODE" == "migrate" ]]; then
  # ── MIGRATION DEPLOY ─────────────────────────────────────────────────────

  _SF_VOL="${SEAFILE_VOLUME:-/opt/seafile-data}"

  case "${MIGRATE_TYPE}" in
    # ── Adopt in place ──────────────────────────────────────────────────────
    # Existing data is already on the volume. Extract SECRET_KEY from the
    # existing config, start the stack, and let config-fixes take over.
    # ──────────────────────────────────────────────────────────────────────
    adopt)
      heading "Migration: Adopt in place"

      # Extract SECRET_KEY from existing config
      _EXISTING_KEY=""
      for _conf_search in \
          "${_SF_VOL}/seafile/conf/seahub_settings.py" \
          "${_SF_VOL}/conf/seahub_settings.py" \
          "${MIGRATE_CONF_DIR:-/dev/null}/seahub_settings.py"; do
        if [[ -f "$_conf_search" ]]; then
          _EXISTING_KEY=$(grep "^SECRET_KEY" "$_conf_search" 2>/dev/null | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
          [[ -n "$_EXISTING_KEY" ]] && info "Extracted SECRET_KEY from ${_conf_search}" && break
        fi
      done
      if [[ -z "$_EXISTING_KEY" ]]; then
        warn "Could not find SECRET_KEY in existing config."
        warn "A new key will be generated — existing sessions will be invalidated."
      else
        # Write minimal seahub_settings.py so config-fixes preserves the key
        mkdir -p "${_SF_VOL}/seafile/conf"
        echo "SECRET_KEY = \"${_EXISTING_KEY}\"" > "${_SF_VOL}/seafile/conf/seahub_settings.py"
        info "SECRET_KEY written to config for preservation."
      fi

      # Verify existing data
      if [[ -d "${_SF_VOL}/seafile-data" ]]; then
        local _data_size=$(du -sh "${_SF_VOL}/seafile-data" 2>/dev/null | cut -f1)
        info "Existing seafile-data found (${_data_size})."
      else
        warn "No seafile-data directory found at ${_SF_VOL}/seafile-data."
        warn "File storage will be empty. If this is unexpected, check your volume mount."
      fi

      # Start DB (if internal)
      if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
        info "Starting database container..."
        COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
        info "Waiting for database..."
        for _attempt in {1..30}; do
          docker exec -e MYSQL_PWD="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" seafile-db mysqladmin ping -u root --silent 2>/dev/null && break
          sleep 3
        done
      fi

      # Start full stack — Seafile sees existing data and skips init
      info "Starting Seafile stack..."
      COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1
      info "Stack started. Waiting for containers to stabilize..."
      sleep 15
      ;;

    # ── Prepared backup ─────────────────────────────────────────────────────
    # User has database dumps and a data directory ready on this machine.
    # Same pattern as recovery-finalize: start DB, import, copy data, start.
    # ──────────────────────────────────────────────────────────────────────
    prepared)
      heading "Migration: Import from prepared backup"

      # Stage 1: Start DB
      if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
        info "Stage 1: Starting database container..."
        COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
        info "Waiting for database to accept connections..."
        _db_ready=false
        for _attempt in {1..30}; do
          if docker exec -e MYSQL_PWD="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" seafile-db mysqladmin ping -u root --silent 2>/dev/null; then
            _db_ready=true; break
          fi
          sleep 3
        done
        [[ "$_db_ready" != "true" ]] && warn "Database did not become ready in 90s."
      fi

      # Stage 2: Import database dumps
      if [[ -n "${MIGRATE_DUMP_DIR:-}" && -d "${MIGRATE_DUMP_DIR}" ]]; then
        info "Stage 2: Importing database dumps from ${MIGRATE_DUMP_DIR}..."
        _import_db_dumps "${MIGRATE_DUMP_DIR}" "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" "internal"
      else
        warn "No dump directory specified — database will be empty."
        warn "Seafile's first-boot init will create tables on startup."
      fi

      # Stage 3: Copy file data
      info "Stage 3: Copying file data..."
      if [[ -n "${MIGRATE_DATA_DIR:-}" && -d "${MIGRATE_DATA_DIR}" ]]; then
        # Detect source layout and copy appropriately
        if [[ -d "${MIGRATE_DATA_DIR}/seafile-data" ]]; then
          info "Copying seafile-data (this may take a while for large libraries)..."
          rsync -a --info=progress2 "${MIGRATE_DATA_DIR}/seafile-data/" "${_SF_VOL}/seafile-data/"
          info "File data copied."
        fi

        # Copy avatars
        for _avatar_src in \
            "${MIGRATE_DATA_DIR}/seafile/seahub-data/avatars" \
            "${MIGRATE_DATA_DIR}/seahub-data/avatars"; do
          if [[ -d "$_avatar_src" ]]; then
            mkdir -p "${_SF_VOL}/seafile/seahub-data/avatars"
            rsync -a "$_avatar_src/" "${_SF_VOL}/seafile/seahub-data/avatars/"
            info "Avatars copied."
            break
          fi
        done
      else
        warn "No data directory specified — file storage will be empty."
      fi

      # Stage 4: Extract SECRET_KEY
      _EXISTING_KEY=""
      if [[ -n "${MIGRATE_CONF_DIR:-}" && -f "${MIGRATE_CONF_DIR}/seahub_settings.py" ]]; then
        _EXISTING_KEY=$(grep "^SECRET_KEY" "${MIGRATE_CONF_DIR}/seahub_settings.py" 2>/dev/null | head -1 | cut -d'"' -f2 | cut -d"'" -f2)
      fi
      if [[ -n "$_EXISTING_KEY" ]]; then
        mkdir -p "${_SF_VOL}/seafile/conf"
        echo "SECRET_KEY = \"${_EXISTING_KEY}\"" > "${_SF_VOL}/seafile/conf/seahub_settings.py"
        info "SECRET_KEY preserved from source configuration."
      else
        warn "No SECRET_KEY found — a new key will be generated."
        warn "Existing user sessions will be invalidated (users will need to log in again)."
      fi

      # Stage 5: Start Seafile (sees imported data, skips setup-seafile-mysql.py)
      info "Stage 5: Starting Seafile..."
      COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile 2>&1
      sleep 10

      # Stage 6: Start remaining containers
      info "Stage 6: Starting remaining containers..."
      COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1
      sleep 10
      ;;

    # ── SSH migration ───────────────────────────────────────────────────────
    # Dump databases and rsync files from a remote Seafile server over SSH.
    # Uses the same _import_db_dumps helper as recovery and prepared migration.
    # ──────────────────────────────────────────────────────────────────────
    ssh)
      heading "Migration: Import from remote server via SSH"

      _SSH_CMD="ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${MIGRATE_SSH_PORT:-22} ${MIGRATE_SSH_USER:-root}@${MIGRATE_SSH_HOST}"
      _REMOTE_DATA="${MIGRATE_REMOTE_DATA_DIR}"
      _REMOTE_CONF="${MIGRATE_REMOTE_CONF_DIR}"
      _REMOTE_DB_TYPE="${MIGRATE_REMOTE_DB:-docker}"
      _REMOTE_DB_USER="${MIGRATE_REMOTE_DB_USER:-seafile}"
      _REMOTE_DB_PASS="${MIGRATE_REMOTE_DB_PASS:-}"
      _REMOTE_DB_HOST="${MIGRATE_REMOTE_DB_HOST:-}"

      # Stage 1: Start local DB
      if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
        info "Stage 1: Starting local database container..."
        COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile-db 2>&1
        info "Waiting for local database to accept connections..."
        _db_ready=false
        for _attempt in {1..30}; do
          if docker exec -e MYSQL_PWD="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" seafile-db mysqladmin ping -u root --silent 2>/dev/null; then
            _db_ready=true; break
          fi
          sleep 3
        done
        [[ "$_db_ready" != "true" ]] && warn "Local database did not become ready in 90s."
      fi

      # Stage 2: Dump remote databases and import locally
      info "Stage 2: Dumping databases from remote server..."

      # Create temporary dump directory (secured, cleaned up on exit)
      _LOCAL_DUMP_DIR=$(mktemp -d /tmp/seafile-migrate-dumps.XXXXXX)
      chmod 700 "$_LOCAL_DUMP_DIR"
      trap 'rm -rf "$_LOCAL_DUMP_DIR" 2>/dev/null' EXIT

      for _rdb in \
          "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
          "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
          "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

        info "  Dumping ${_rdb}..."

        case "$_REMOTE_DB_TYPE" in
          docker)
            # Source is Docker — mysqldump via docker exec on remote
            $_SSH_CMD "docker exec -e MYSQL_PWD='${_REMOTE_DB_PASS}' seafile-db mysqldump \
              -u '${_REMOTE_DB_USER}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz"
            ;;
          local)
            # Source is manual install — mysqldump directly on remote
            $_SSH_CMD "MYSQL_PWD='${_REMOTE_DB_PASS}' mysqldump \
              -u '${_REMOTE_DB_USER}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz"
            ;;
          external)
            # Source uses an external DB — mysqldump with -h flag on remote
            $_SSH_CMD "MYSQL_PWD='${_REMOTE_DB_PASS}' mysqldump \
              -h '${_REMOTE_DB_HOST}' \
              -u '${_REMOTE_DB_USER}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz"
            ;;
        esac

        # Verify dump is not empty
        local _dump_size=$(stat -c%s "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz" 2>/dev/null || echo "0")
        if [[ "$_dump_size" -gt 100 ]]; then
          info "  ✓ ${_rdb} dumped ($(du -h "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz" | cut -f1))"
        else
          warn "  ✗ ${_rdb} dump appears empty or failed — check remote DB access."
        fi
      done

      info "Importing database dumps into local database..."
      _import_db_dumps "${_LOCAL_DUMP_DIR}" "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" "internal"
      rm -rf "${_LOCAL_DUMP_DIR}"

      # Stage 3: Rsync file data from remote
      info "Stage 3: Copying file data from remote server (this may take a while)..."
      mkdir -p "${_SF_VOL}/seafile-data"

      # Determine remote seafile-data path
      local _remote_data_path="${_REMOTE_DATA}/seafile-data/"
      if $_SSH_CMD "test -d '${_remote_data_path}'" 2>/dev/null; then
        rsync -avz --info=progress2 \
          -e "ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${MIGRATE_SSH_PORT:-22}" \
          "${MIGRATE_SSH_USER:-root}@${MIGRATE_SSH_HOST}:${_remote_data_path}" \
          "${_SF_VOL}/seafile-data/"
        info "File data transfer complete."
      else
        warn "Remote seafile-data directory not found at ${_remote_data_path}."
        warn "File storage will be empty."
      fi

      # Stage 4: Copy avatars from remote
      info "Stage 4: Copying avatars..."
      local _remote_avatar_path=""
      for _try_avatar in \
          "${_REMOTE_DATA}/seafile/seahub-data/avatars" \
          "${_REMOTE_DATA}/seahub-data/avatars"; do
        if $_SSH_CMD "test -d '${_try_avatar}'" 2>/dev/null; then
          _remote_avatar_path="$_try_avatar"
          break
        fi
      done
      if [[ -n "$_remote_avatar_path" ]]; then
        mkdir -p "${_SF_VOL}/seafile/seahub-data/avatars"
        rsync -avz \
          -e "ssh -o ConnectTimeout=30 -o ServerAliveInterval=60 -p ${MIGRATE_SSH_PORT:-22}" \
          "${MIGRATE_SSH_USER:-root}@${MIGRATE_SSH_HOST}:${_remote_avatar_path}/" \
          "${_SF_VOL}/seafile/seahub-data/avatars/"
        info "Avatars copied."
      else
        info "No avatar directory found on remote — skipping."
      fi

      # Stage 5: Extract SECRET_KEY from remote config
      info "Stage 5: Extracting SECRET_KEY from remote configuration..."
      _EXISTING_KEY=""
      if [[ -n "$_REMOTE_CONF" ]]; then
        _EXISTING_KEY=$($_SSH_CMD "grep '^SECRET_KEY' '${_REMOTE_CONF}/seahub_settings.py' 2>/dev/null | head -1" 2>/dev/null || true)
        # Parse: SECRET_KEY = "..." or SECRET_KEY = '...'
        _EXISTING_KEY=$(echo "$_EXISTING_KEY" | sed "s/.*['\"]//;s/['\"].*//" | tr -d '[:space:]')
      fi
      if [[ -n "$_EXISTING_KEY" ]]; then
        mkdir -p "${_SF_VOL}/seafile/conf"
        echo "SECRET_KEY = \"${_EXISTING_KEY}\"" > "${_SF_VOL}/seafile/conf/seahub_settings.py"
        info "SECRET_KEY preserved from remote configuration."
      else
        warn "Could not extract SECRET_KEY — a new key will be generated."
        warn "Existing user sessions will be invalidated."
      fi

      # Stage 6: Start Seafile (sees imported data, skips setup-seafile-mysql.py)
      info "Stage 6: Starting Seafile..."
      COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d seafile 2>&1
      sleep 10

      # Stage 7: Start remaining containers
      info "Stage 7: Starting remaining containers..."
      COMPOSE_PROFILES="$COMPOSE_PROFILES" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d 2>&1
      sleep 10

      info "SSH migration complete."
      ;;
  esac

  fi  # end install/migrate branch

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
        # Lock down clone directory — .git/config contains the auth token
        if [ -d "$GITOPS_CLONE/.git" ]; then
          chmod 700 "$GITOPS_CLONE"
        fi
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
    _host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    _git_port="${CONFIG_GIT_PORT:-9418}"
    _cui_pw=""
    _cui_pw=$(grep "^CONFIG_UI_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)

    echo ""
    echo -e "  ${GREEN}${BOLD}  ✓ Machine ready for Portainer deployment!${NC}"
    echo ""
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Connect Portainer to this machine${NC}"
    echo ""
    echo -e "    In Portainer: ${DIM}Environments → Add Environment → Agent${NC}"
    echo -e "    Agent URL:    ${BOLD}${_host_ip}:9001${NC}"
    echo ""
    echo -e "  ${BOLD}Step 2: Create the Seafile stack${NC}"
    echo ""
    echo -e "    In Portainer: ${DIM}Stacks → Add Stack${NC}"
    echo -e "    Name:           ${BOLD}seafile${NC}"
    echo -e "    Build method:   ${BOLD}Repository${NC}"
    echo -e "    Repository URL: ${BOLD}http://${_host_ip}:${_git_port}/${NC}"
    echo -e "    Compose path:   ${BOLD}docker-compose.yml${NC}"
    echo ""
    echo -e "    ${DIM}Enable GitOps updates, enable Webhook, then${NC}"
    echo -e "    ${DIM}copy the webhook URL before clicking Deploy.${NC}"
    echo ""
    echo -e "  ${BOLD}Step 3: Set the webhook URL${NC}"
    echo ""
    echo -e "    Open the web configuration panel and paste"
    echo -e "    the Portainer webhook URL into Settings."
    echo ""
    echo -e "    ${BOLD}Web panel:${NC}  ${BOLD}http://${_host_ip}:9443${NC}"
    if [[ -n "$_cui_pw" ]]; then
      echo -e "    ${DIM}Password:   ${_cui_pw}${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}After you deploy the stack in Portainer, this machine${NC}"
    echo -e "  ${DIM}will automatically detect the running containers and${NC}"
    echo -e "  ${DIM}apply your .env configuration. Follow progress with:${NC}"
    echo -e "    ${BOLD}journalctl -u seafile-recovery-finalize -f${NC}"
    echo ""
    echo -e "  ${DIM}Once that completes, all management is browser-based:${NC}"
    echo -e "    ${DIM}Config + operations → Web panel (http://${_host_ip}:9443)${NC}"
    echo -e "    ${DIM}Containers + logs   → Portainer${NC}"
    echo ""
  else
    echo ""
    echo -e "  ${GREEN}${BOLD}Deployment complete!${NC}"
    echo ""

    # Show proxy setup instructions for external proxy types
    _proxy="${PROXY_TYPE:-nginx}"
    if [[ "$_proxy" != "caddy-bundled" ]]; then
      _host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      _caddy_port="${CADDY_PORT:-7080}"
      _proto="${SEAFILE_SERVER_PROTOCOL:-https}"
      _domain="${SEAFILE_SERVER_HOSTNAME:-your-domain}"

      echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo -e "  ${BOLD}Next step: Configure your reverse proxy${NC}"
      echo ""

      case "$_proxy" in
        nginx)
          echo -e "  In Nginx Proxy Manager, add a Proxy Host:"
          echo ""
          echo -e "  ${DIM}Details tab:${NC}"
          echo -e "    Domain:       ${BOLD}${_domain}${NC}"
          echo -e "    Scheme:       http"
          echo -e "    Forward IP:   ${BOLD}${_host_ip}${NC}"
          echo -e "    Forward Port: ${BOLD}${_caddy_port}${NC}"
          echo -e "    Websockets:   ${BOLD}enabled${NC}"
          echo ""
          echo -e "  ${DIM}SSL tab:${NC}"
          echo -e "    Request a Let's Encrypt certificate, enable Force SSL"
          echo ""
          echo -e "  ${DIM}Advanced tab — paste this:${NC}"
          echo ""
          cat << NPMCONF

location / {
    proxy_pass http://${_host_ip}:${_caddy_port};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto ${_proto};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 1200s;
    proxy_buffering off;
    client_max_body_size 0;
}

NPMCONF
          echo -e "  ${DIM}You can also get this config any time by running:${NC}"
          echo -e "    ${BOLD}seafile proxy-config${NC}"
          ;;
        traefik)
          echo -e "  Traefik labels are already configured in docker-compose.yml."
          echo -e "  Ensure ${BOLD}TRAEFIK_ENABLED=true${NC} is set in .env and the"
          echo -e "  seafile-caddy container is on a network Traefik can reach."
          ;;
        caddy-external|haproxy)
          echo -e "  Forward traffic to: ${BOLD}http://${_host_ip}:${_caddy_port}${NC}"
          echo -e "  Required: WebSocket upgrade, no upload size limit, 1200s timeout"
          echo -e "  Run ${BOLD}seafile proxy-config${NC} for full details."
          ;;
      esac

      echo ""
      echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
    else
      echo -e "  SSL certificates are obtained automatically from Let's Encrypt."
      echo -e "  If the page doesn't load over HTTPS right away, wait a moment"
      echo -e "  for the certificate to be issued (requires ports 80 + 443 open)."
      echo ""
    fi

    echo -e "  Open your browser:  ${BOLD}${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}${NC}"
    echo ""
    echo -e "  Login:     ${BOLD}${INIT_SEAFILE_ADMIN_EMAIL}${NC}"
    echo -e "  Password:  ${BOLD}${INIT_SEAFILE_ADMIN_PASSWORD:-changeme}${NC}"
    echo ""
    echo -e "  ${DIM}Change this password after your first login.${NC}"
    echo -e "  ${DIM}Go to Profile (top right) → Password.${NC}"
    echo ""

    # Show config panel info
    _cui_pw=""
    _cui_pw=$(grep "^CONFIG_UI_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
    if [[ -n "$_cui_pw" ]]; then
      _host_for_panel=""
      _host_for_panel=$(hostname -I 2>/dev/null | awk '{print $1}')
      echo -e "  ${BOLD}Web configuration panel:${NC}"
      echo -e "    ${BOLD}http://${_host_for_panel}:9443${NC}"
      echo -e "    ${DIM}Password: ${_cui_pw}  (also in: seafile secrets --show)${NC}"
      echo ""
    fi

    echo -e "  ${DIM}Configure via browser or CLI:${NC} ${BOLD}seafile config${NC}"
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
