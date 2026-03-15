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
DEPLOY_VERSION="v4.6-alpha"

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
# =============================================================================
# Seafile 13 — Environment Configuration
# =============================================================================
# Fill in every blank value in the REQUIRED sections before deploying.
# Everything else has sensible defaults — change only what your setup needs.
#
# SINGLE SOURCE OF TRUTH: this file drives everything.
# To change any setting, edit this file and run: seafile update
# No manual config file editing is ever needed.
# =============================================================================


# =============================================================================
# REQUIRED — Network Storage
# =============================================================================
# All file data, .env backups, and config scripts live on this share.
# NFS is the default and recommended option — it is the foundation of the
# disaster recovery model. For STORAGE_TYPE=local, data is tied to the VM
# and cannot be recovered if the VM is lost. Suitable for testing only.
#
# Set STORAGE_TYPE to one of: nfs | smb | glusterfs | iscsi | local
# Fill in only the section that matches your STORAGE_TYPE.
# =============================================================================

STORAGE_TYPE=nfs

# --- NFS (default, recommended) ---
NFS_SERVER=
NFS_EXPORT=

# --- SMB / CIFS ---
SMB_SERVER=
SMB_SHARE=
SMB_USERNAME=
SMB_PASSWORD=
SMB_DOMAIN=

# --- GlusterFS ---
GLUSTER_SERVER=
GLUSTER_VOLUME=

# --- iSCSI ---
ISCSI_PORTAL=
ISCSI_TARGET_IQN=
ISCSI_FILESYSTEM=ext4
# CHAP authentication (optional — leave blank to disable)
# If set, configure the same credentials on your iSCSI target before deploying.
# Leave ISCSI_CHAP_PASSWORD blank to have seafile-deploy.sh generate one.
ISCSI_CHAP_USERNAME=
ISCSI_CHAP_PASSWORD=


# =============================================================================
# REQUIRED — Server
# =============================================================================

# Your public domain name — the URL users access Seafile at.
SEAFILE_SERVER_HOSTNAME=

# Leave as https for all standard deployments.
SEAFILE_SERVER_PROTOCOL=https


# =============================================================================
# DATABASE
# =============================================================================
# DB_INTERNAL=true  (default) — MariaDB runs as a container in this stack.
#   No setup needed. Credentials are auto-generated by seafile-deploy.sh.
#   See README → Plan Your Deployment → Database for DR implications.
#
# DB_INTERNAL=false — Connect to an existing MySQL/MariaDB server.
#   Complete README → Step 3 before deploying. Fill in the external DB section
#   below and leave the internal DB section at its defaults.
# =============================================================================

DB_INTERNAL=true

# --- Internal DB (DB_INTERNAL=true) ---
# Data volume for the MariaDB container.
# Default: local disk (/opt/seafile-db). Fine for getting started.
# For full disaster recovery, set this to a subdirectory of SEAFILE_VOLUME
# so the database lives on your network share alongside Seafile's file data.
# Example: DB_INTERNAL_VOLUME=/mnt/seafile_nfs/db
DB_INTERNAL_VOLUME=/opt/seafile-db

# MariaDB image. Leave as-is unless you need a different patch version.
DB_INTERNAL_IMAGE=mariadb:10.11

# --- External DB (DB_INTERNAL=false) ---
# IP or hostname of your MySQL/MariaDB server.
SEAFILE_MYSQL_DB_HOST=

# Password for the seafile database user (created in Step 3).
# Leave blank — seafile-deploy.sh auto-generates this when DB_INTERNAL=true.
SEAFILE_MYSQL_DB_PASSWORD=

# Root password — used only on first startup to create databases. Cleared
# automatically after first successful deploy.
# Leave blank — auto-generated when DB_INTERNAL=true.
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=

# Database username — change only if you used a different name in Step 3.
SEAFILE_MYSQL_DB_USER=seafile

# Database port — change only if your server uses a non-standard port.
SEAFILE_MYSQL_DB_PORT=3306


# =============================================================================
# REQUIRED — Auth
# =============================================================================

# Secret key for signing authentication tokens between internal services.
# Leave blank — seafile-deploy.sh will generate one automatically.
JWT_PRIVATE_KEY=


# =============================================================================
# REQUIRED — Initial Admin Account
# =============================================================================

INIT_SEAFILE_ADMIN_EMAIL=
INIT_SEAFILE_ADMIN_PASSWORD=


# =============================================================================
# OPTIONAL — Office Suite
# =============================================================================
# Choose your collaborative document editor. Default: collabora
#
#   collabora   — Lightweight, stays inside Docker network, better ODF support.
#                 Good for personal and small-team use. Included by default.
#
#   onlyoffice  — Better Microsoft Office fidelity, Track Changes, co-editing.
#                 Requires 4–8 GB RAM minimum. Exposes port ONLYOFFICE_PORT
#                 on the host — configure your reverse proxy accordingly.
#
# seafile update switches between them automatically when you change this value.
# =============================================================================

# Office suite: collabora (default), onlyoffice, or none (no document editing)
OFFICE_SUITE=collabora

# --- Office Suite Credentials (AUTO-GENERATED) ---
# These are auto-generated on first boot if left blank. You never need to fill
# these in manually — the installer handles it. Both Collabora and OnlyOffice
# credentials are generated regardless of which suite you choose, so switching
# later "just works" without needing to generate new secrets.
#
# Collabora: admin console at /browser/dist/admin/admin.html
# OnlyOffice: JWT secret for API authentication
#
# To use custom values, set them before running the installer.
COLLABORA_ADMIN_USER=
COLLABORA_ADMIN_PASSWORD=
COLLABORA_ALIAS_GROUP=
ONLYOFFICE_JWT_SECRET=

# Port OnlyOffice exposes on the Docker host. Your reverse proxy should
# forward HTTPS traffic for this port to OnlyOffice. Port 6233 is standard.
ONLYOFFICE_PORT=6233

# Local path for OnlyOffice persistent data.
ONLYOFFICE_VOLUME=/opt/onlyoffice

# OnlyOffice image tag. Only used when OFFICE_SUITE=onlyoffice.
ONLYOFFICE_IMAGE=onlyoffice/documentserver:8.1.0.1


# =============================================================================
# OPTIONAL — Antivirus (ClamAV)
# =============================================================================
# Scans uploaded files for viruses. Disabled by default — ClamAV requires
# ~1 GB RAM for its signature database plus additional RAM per scan worker.
# First startup takes 5–15 minutes while ClamAV downloads virus definitions.
#
# When enabled, a seafile-clamav container is added to the stack automatically.
# =============================================================================

CLAMAV_ENABLED=false
CLAMAV_IMAGE=clamav/clamav:stable


# =============================================================================
# OPTIONAL — Email / SMTP
# =============================================================================
# Required for password reset, share notifications, and user registration emails.
# Without this, users cannot reset their passwords via email.
# =============================================================================

SMTP_ENABLED=false
SMTP_HOST=
# Common ports: 465 (SSL), 587 (STARTTLS), 25 (plain — not recommended)
# Set SMTP_ENABLED=false if you do not need outbound email — Seafile will work
# without it, but users will not receive password reset or share notification emails.
SMTP_PORT=465
SMTP_USE_TLS=true
SMTP_USER=
SMTP_PASSWORD=
# The From address shown to email recipients
SMTP_FROM=noreply@yourdomain.com


# =============================================================================
# OPTIONAL — User & Library Settings
# =============================================================================
# All of these are applied automatically by seafile-config-fixes.sh.
# Change a value and run: seafile update
# =============================================================================

# Default storage quota per user in GB. 0 = unlimited.
DEFAULT_USER_QUOTA_GB=0

# Maximum upload size in MB. 0 = unlimited.
# Also adjusts the gunicorn request timeout proportionally.
MAX_UPLOAD_SIZE_MB=0

# Number of days before items in user trash are permanently deleted. 0 = never.
TRASH_CLEAN_AFTER_DAYS=30

# Force all users to enable two-factor authentication on next login.
FORCE_2FA=false

# Allow users to be created as guests (read-only external sharing accounts).
ENABLE_GUEST=false

# Allow public registration (strangers can create accounts). Most private
# deployments should leave this false.
ENABLE_SIGNUP=false

# Lock user account after this many consecutive failed login attempts.
# 0 = no limit. Locked users can be unlocked by the admin.
LOGIN_ATTEMPT_LIMIT=5

# Require a password on every share link. Prevents accidental public exposure.
SHARE_LINK_FORCE_USE_PASSWORD=false

# Default and maximum expiration for share links (days). 0 = no limit.
SHARE_LINK_EXPIRE_DAYS_DEFAULT=0
SHARE_LINK_EXPIRE_DAYS_MAX=0

# Session timeout in seconds. 0 = browser session (closes on quit).
# 86400 = 1 day, 604800 = 1 week (Seafile default).
SESSION_COOKIE_AGE=0

# Number of days to keep file history. 0 = keep forever (default).
FILE_HISTORY_KEEP_DAYS=0

# Enable audit logging (tracks file access, downloads, shares).
AUDIT_ENABLED=true

# =============================================================================
# OPTIONAL — Branding
# =============================================================================
# Customise the Seafile web interface appearance.
# Changes take effect after running: seafile update
# =============================================================================

# Site name shown in browser tab and emails.
SITE_NAME=Seafile
# Site title shown on the login page.
SITE_TITLE=Seafile


# =============================================================================
# OPTIONAL — WebDAV
# =============================================================================
# Allows mounting Seafile as a network drive (macOS Finder, Windows, DAVx5).
# Access via: https://yourdomain.com/seafdav
#
# Note: LDAP users cannot use their LDAP password for WebDAV (Seafile 12+).
# They must generate a WebDAV token from their Seafile profile page.
# =============================================================================

SEAFDAV_ENABLED=false


# =============================================================================
# OPTIONAL — LDAP / Active Directory
# =============================================================================
# Allows users to log in with their LDAP/AD credentials.
# Requires a working LDAP server — configuration is environment-specific.
# =============================================================================

LDAP_ENABLED=false
# Full LDAP server URL. Examples: ldap://192.168.1.10  ldaps://ad.example.com
LDAP_URL=
# Service account DN used to bind and search the directory.
LDAP_BIND_DN=
# Password for the bind DN service account.
LDAP_BIND_PASSWORD=
# Base DN to search for users.
LDAP_BASE_DN=
# Attribute users log in with. Use 'mail' for email, 'sAMAccountName' for AD.
LDAP_LOGIN_ATTR=mail
# Optional search filter to restrict which LDAP users can log in.
# Example: (memberOf=CN=seafile-users,OU=Groups,DC=example,DC=com)
LDAP_FILTER=


# =============================================================================
# OPTIONAL — Garbage Collection
# =============================================================================
# Reclaims storage from deleted files and trimmed history. Recommended on.
# GC briefly stops the Seafile service (~30–120s) while it runs — schedule
# for low-traffic hours. Online GC (no downtime) is Pro edition only.
# =============================================================================

GC_ENABLED=true
# When to run GC automatically. Uses standard cron syntax.
# Default: weekly, Sunday at 3am. For nightly: 0 3 * * *
GC_SCHEDULE="0 3 * * 0"
# Also remove blocks from fully-deleted libraries (-r flag). Recommended true.
GC_REMOVE_DELETED=true
# Dry-run mode: log what would be collected without actually removing anything.
# Set to true to audit before committing. Default: false (actually removes).
GC_DRY_RUN=false


# =============================================================================
# OPTIONAL — Backup
# =============================================================================
# Automated backup of database and Seafile data on a cron schedule.
# Dumps all databases and rsyncs SEAFILE_VOLUME to the backup destination.
# The backup destination is mounted automatically — just provide the
# connection details below, the same way you configured main storage.
# =============================================================================

BACKUP_ENABLED=false
# When to run backups. Default: daily at 2am.
BACKUP_SCHEDULE="0 2 * * *"

# Backup destination storage type: nfs, smb, or local.
# "local" means a path already available on this machine (second disk, USB, etc.)
BACKUP_STORAGE_TYPE=nfs

# Mount point for the backup destination.
BACKUP_MOUNT=/mnt/seafile_backup

# NFS backup destination (when BACKUP_STORAGE_TYPE=nfs)
BACKUP_NFS_SERVER=
BACKUP_NFS_EXPORT=

# SMB backup destination (when BACKUP_STORAGE_TYPE=smb)
BACKUP_SMB_SERVER=
BACKUP_SMB_SHARE=
BACKUP_SMB_USERNAME=
BACKUP_SMB_PASSWORD=
BACKUP_SMB_DOMAIN=


# =============================================================================
# OPTIONAL — Storage Paths
# =============================================================================

# Mount point for the network share (or local directory for STORAGE_TYPE=local).
SEAFILE_VOLUME=/mnt/seafile_nfs

# Local path for the thumbnail cache (rebuilt automatically if deleted).
THUMBNAIL_PATH=/opt/seafile-thumbnails

# Local path for the metadata index (rebuilt by re-enabling Extended Properties).
METADATA_PATH=/opt/seafile-metadata

# Local path for SeaDoc persistent data.
SEADOC_DATA_PATH=/opt/seadoc-data

# Mount options — only the options for your STORAGE_TYPE are used.
NFS_OPTIONS=auto,x-systemd.automount,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nofail
SMB_OPTIONS=auto,x-systemd.automount,_netdev,nofail,uid=0,gid=0,file_mode=0700,dir_mode=0700
GLUSTER_OPTIONS=defaults,_netdev,nofail
ISCSI_OPTIONS=_netdev,auto,nofail


# =============================================================================
# OPTIONAL — Server Settings
# =============================================================================

# Reverse proxy in front of this stack. Controls Caddyfile generation and
# Step 7 of the setup guide. Options:
#   nginx          — Nginx Proxy Manager or raw Nginx (default, most common)
#   traefik        — Traefik via Docker labels
#   caddy-external — External Caddy instance
#   caddy-bundled  — Bundled Caddy handles ACME/SSL directly (no external proxy)
#   haproxy        — HAProxy
PROXY_TYPE=nginx

# Port Caddy exposes on the Docker host (HTTP). Your reverse proxy forwards to this.
# Change if 7080 conflicts with another service on this host.
# When PROXY_TYPE=caddy-bundled, set CADDY_PORT=80 and CADDY_HTTPS_PORT=443.
CADDY_PORT=7080

# Port Caddy exposes for HTTPS. Only used when PROXY_TYPE=caddy-bundled.
# In proxy-behind mode (default), Caddy does not listen for HTTPS — this port
# is mapped but unused.
CADDY_HTTPS_PORT=7443

# Your local timezone. https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
TIME_ZONE=America/New_York

# Redis auth password. Leave blank to disable Redis authentication.
# If set, all internal services are configured to use it automatically.
REDIS_PASSWORD=

# Set to false to write logs to files on the storage share instead of stdout.
SEAFILE_LOG_TO_STDOUT=true

# Maximum files per library the metadata server will index.
MD_FILE_COUNT_LIMIT=100000

# Notification server log verbosity: debug | info | warn | error
NOTIFICATION_SERVER_LOG_LEVEL=info



# =============================================================================
# OPTIONAL — Deployment Mode
# =============================================================================

# Set to true if Portainer manages the stack lifecycle (start/stop/redeploy).
# Set to false (default) for native Docker Compose management.
# See "Plan Your Deployment" in the README for the full explanation.
PORTAINER_MANAGED=false

# Portainer stack webhook URL — used to trigger Portainer redeploys when .env
# changes. Only relevant when PORTAINER_MANAGED=true.
# Portainer → Stacks → your stack → Webhooks → copy the URL
PORTAINER_STACK_WEBHOOK=

# Port for the local config git server. Portainer pulls docker-compose.yml and
# .env from this server. Only active when PORTAINER_MANAGED=true.
CONFIG_GIT_PORT=9418

# =============================================================================
# CONFIG HISTORY
# =============================================================================
# Local git versioning of .env and deployment scripts. Tracks every change
# with timestamps. Use `seafile config history` to browse changes and
# `seafile config rollback` to revert.
CONFIG_HISTORY_ENABLED=true

# Number of entries shown by `seafile config history` (default display limit).
# Full history is always available via `seafile config history --all`.
CONFIG_HISTORY_RETAIN=50


# =============================================================================
# IMAGE TAGS
# =============================================================================
# Pinned to stable versions verified against Seafile 13 docs (March 2026).
# See "Image Version Management" in the README before changing any of these.

SEAFILE_IMAGE=seafileltd/seafile-mc:13.0.18
SEADOC_IMAGE=seafileltd/sdoc-server:2.0-latest
NOTIFICATION_SERVER_IMAGE=seafileltd/notification-server:13.0.10
THUMBNAIL_SERVER_IMAGE=seafileltd/thumbnail-server:13.0-latest
MD_IMAGE=seafileltd/seafile-md-server:13.0-latest
CADDY_IMAGE=caddy:2.11.1-alpine
COLLABORA_IMAGE=collabora/code:25.04.8.1.1
SEAFILE_REDIS_IMAGE=redis:7-alpine


# =============================================================================
# OPTIONAL — Traefik (disabled by default)
# =============================================================================
# Set TRAEFIK_ENABLED=true to activate Traefik labels on seafile-caddy.
# Leave false if using Nginx Proxy Manager or any non-label-based proxy.

TRAEFIK_ENABLED=false
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERTRESOLVER=letsencrypt


# =============================================================================
# OPTIONAL — GitOps (disabled by default)
# =============================================================================
# See "GitOps Integration" in the README for the full setup walkthrough.

GITOPS_INTEGRATION=false
GITOPS_REPO_URL=
GITOPS_TOKEN=
GITOPS_BRANCH=main
GITOPS_WEBHOOK_SECRET=
GITOPS_WEBHOOK_PORT=9002
GITOPS_CLONE_PATH=/opt/seafile-gitops


# =============================================================================
# Multi-Backend Storage (disabled by default)
# =============================================================================
# When MULTI_BACKEND_ENABLED=true, Seafile uses multiple storage classes to
# organize libraries across different logical backends. Each library belongs
# to one storage class, chosen at creation time by a mapping policy.
#
# Use cases:
#   • Hot/cold storage tiering (active projects vs archive)
#   • Departmental separation (Engineering vs Finance)
#   • User-selectable storage classes
#
# To define backends: fill in BACKEND_N blocks below (at least two).
# One backend MUST have BACKEND_N_DEFAULT=true.
#
# See: https://manual.seafile.com/latest/setup/setup_with_multiple_storage_backends/
# =============================================================================

MULTI_BACKEND_ENABLED=false

# Library mapping policy — how Seafile assigns libraries to storage classes:
#   USER_SELECT   — Users choose when creating a library (default)
#   ROLE_BASED    — Admins assign storage classes to user roles
#   REPO_ID_MAPPING — Automatic distribution by library ID
STORAGE_CLASS_MAPPING_POLICY=USER_SELECT

# Backend 1 ───────────────────────────────────────────────────────────────────
# Uncomment and fill in to define your first backend.
#BACKEND_1_ID=primary
#BACKEND_1_NAME=Primary Storage
#BACKEND_1_DEFAULT=true
#BACKEND_1_TYPE=nfs
#BACKEND_1_MOUNT=/mnt/seafile_primary
#BACKEND_1_NFS_SERVER=
#BACKEND_1_NFS_EXPORT=

# Backend 2 ───────────────────────────────────────────────────────────────────
# Uncomment and fill in to define your second backend.
#BACKEND_2_ID=archive
#BACKEND_2_NAME=Archive Storage
#BACKEND_2_DEFAULT=false
#BACKEND_2_TYPE=smb
#BACKEND_2_MOUNT=/mnt/seafile_archive
#BACKEND_2_SMB_SERVER=
#BACKEND_2_SMB_SHARE=
#BACKEND_2_SMB_USERNAME=
#BACKEND_2_SMB_PASSWORD=
#BACKEND_2_SMB_DOMAIN=

# To add BACKEND_3, BACKEND_4, etc.: duplicate a block above and increment N.
# Supported types: nfs, smb, glusterfs, iscsi
# Each type uses the same variables as the single-backend section:
#   NFS:       BACKEND_N_NFS_SERVER, BACKEND_N_NFS_EXPORT
#   SMB:       BACKEND_N_SMB_SERVER, BACKEND_N_SMB_SHARE, BACKEND_N_SMB_USERNAME,
#              BACKEND_N_SMB_PASSWORD, BACKEND_N_SMB_DOMAIN
#   GlusterFS: BACKEND_N_GLUSTER_SERVER, BACKEND_N_GLUSTER_VOLUME
#   iSCSI:     BACKEND_N_ISCSI_PORTAL, BACKEND_N_ISCSI_TARGET_IQN,
#              BACKEND_N_ISCSI_FILESYSTEM, BACKEND_N_ISCSI_CHAP_USERNAME,
#              BACKEND_N_ISCSI_CHAP_PASSWORD


# =============================================================================
# DO NOT CHANGE — Internal wiring
# =============================================================================
# Correct for this deployment. Changing database names after first run breaks
# the deployment. Container names are referenced by the seafile CLI — renaming
# them without also updating the scripts will break management tooling.

SEAFILE_MYSQL_DB_CCNET_DB_NAME=ccnet_db
SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=seafile_db
SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=seahub_db

REDIS_PORT=6379
SITE_ROOT=/
NON_ROOT=false
CADDY_CONFIG_PATH=/opt/seafile-caddy
SEAFILE_NETWORK=seafile-net
ENABLE_GO_FILESERVER=true
ENABLE_SEADOC=true
ENABLE_NOTIFICATION_SERVER=true
ENABLE_METADATA_SERVER=true
ENABLE_THUMBNAIL_SERVER=true
ENABLE_SEAFILE_AI=false
ENABLE_FACE_RECOGNITION=false
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
# Secure MySQL authentication — uses a temp defaults file instead of passing
# passwords on the command line (which would be visible in `ps aux`).
# Usage:
#   _mysql_auth_file <user> <password>   → creates file, prints path
#   _mysql_auth_cleanup                  → removes the file
# The caller must clean up after use.
# ---------------------------------------------------------------------------
_MYSQL_AUTH_FILE=""

_mysql_auth_file() {
  local user="$1" pass="$2"
  _MYSQL_AUTH_FILE=$(mktemp /tmp/.seafile-my.cnf.XXXXXX)
  chmod 600 "$_MYSQL_AUTH_FILE"
  printf '[client]\nuser=%s\npassword=%s\n' "$user" "$pass" > "$_MYSQL_AUTH_FILE"
  echo "$_MYSQL_AUTH_FILE"
}

_mysql_auth_cleanup() {
  [[ -n "${_MYSQL_AUTH_FILE:-}" && -f "$_MYSQL_AUTH_FILE" ]] && rm -f "$_MYSQL_AUTH_FILE"
  _MYSQL_AUTH_FILE=""
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

  local _db_host="${SEAFILE_MYSQL_DB_HOST:-seafile-db}"
  local _db_port="${SEAFILE_MYSQL_DB_PORT:-3306}"

  # Create auth file for external DB access
  local _auth_file=""
  if [[ "$db_method" != "internal" ]]; then
    _auth_file=$(_mysql_auth_file "root" "$root_pass")
  fi

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
      docker exec -e MYSQL_PWD="${root_pass}" seafile-db mysql -u root \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    else
      mysql --defaults-extra-file="$_auth_file" -h "$_db_host" -P "$_db_port" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    fi

    # Import — handle both .sql.gz and .sql
    local _import_ok=false
    if [[ "$dump_file" == *.gz ]]; then
      if [[ "$db_method" == "internal" ]]; then
        gunzip -c "$dump_file" | docker exec -i -e MYSQL_PWD="${root_pass}" seafile-db \
          mysql -u root "$db" 2>/dev/null && _import_ok=true
      else
        gunzip -c "$dump_file" | mysql --defaults-extra-file="$_auth_file" \
          -h "$_db_host" -P "$_db_port" "$db" 2>/dev/null && _import_ok=true
      fi
    else
      if [[ "$db_method" == "internal" ]]; then
        docker exec -i -e MYSQL_PWD="${root_pass}" seafile-db mysql -u root "$db" \
          < "$dump_file" 2>/dev/null && _import_ok=true
      else
        mysql --defaults-extra-file="$_auth_file" -h "$_db_host" -P "$_db_port" "$db" \
          < "$dump_file" 2>/dev/null && _import_ok=true
      fi
    fi

    if [[ "$_import_ok" == "true" ]]; then
      info "  ✓ ${db} imported successfully."
    else
      warn "  ✗ Failed to import ${db} — check dump file and database access."
    fi
  done

  # Clean up auth file
  [[ -n "$_auth_file" ]] && rm -f "$_auth_file"
}

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

# Build active container list from .env (same logic as CLI and setup)
CONTAINERS=(seafile-caddy seafile-redis seafile seadoc notification-server thumbnail-server seafile-metadata)
case "${OFFICE_SUITE:-collabora}" in
  onlyoffice) CONTAINERS+=(seafile-onlyoffice) ;;
  none)       ;;  # No office suite container
  *)          CONTAINERS+=(seafile-collabora)  ;;
esac
[[ "${CLAMAV_ENABLED:-false}" == "true" ]] && CONTAINERS+=(seafile-clamav)
[[ "${DB_INTERNAL:-true}"    == "true" ]] && CONTAINERS+=(seafile-db)

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
services:

  # --- Reverse Proxy ---
  # Caddy handles internal routing between all Seafile services.
  # SSL termination is handled upstream by your external reverse proxy.
  # Caddy listens on ${CADDY_PORT:-7080}; your proxy forwards plain HTTP to this port.
  #
  # Traefik labels are controlled by TRAEFIK_ENABLED in .env.
  caddy:
    image: ${CADDY_IMAGE:-caddy:2.11.1-alpine}
    restart: always
    container_name: seafile-caddy
    ports:
      - "${CADDY_PORT:-7080}:80"
      - "${CADDY_HTTPS_PORT:-7443}:443"
    volumes:
      - ${CADDY_CONFIG_PATH:-/opt/seafile-caddy}/Caddyfile:/etc/caddy/Caddyfile
      - ${CADDY_CONFIG_PATH:-/opt/seafile-caddy}/data:/data
      - ${CADDY_CONFIG_PATH:-/opt/seafile-caddy}/config:/config
    labels:
      - "traefik.enable=${TRAEFIK_ENABLED:-false}"
      - "traefik.http.routers.seafile.rule=Host(`${SEAFILE_SERVER_HOSTNAME}`)"
      - "traefik.http.routers.seafile.entrypoints=${TRAEFIK_ENTRYPOINT:-websecure}"
      - "traefik.http.routers.seafile.tls.certresolver=${TRAEFIK_CERTRESOLVER:-letsencrypt}"
      - "traefik.http.services.seafile.loadbalancer.server.port=${CADDY_PORT:-7080}"
      - "traefik.http.middlewares.seafile-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.routers.seafile.middlewares=seafile-headers"
    networks:
      - seafile-net

  # --- Cache ---
  redis:
    image: ${SEAFILE_REDIS_IMAGE:-redis:7-alpine}
    container_name: seafile-redis
    restart: always
    command:
      - /bin/sh
      - -c
      - redis-server --requirepass "$$REDIS_PASSWORD"
    environment:
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
    networks:
      - seafile-net

  # --- Core Seafile ---
  seafile:
    image: ${SEAFILE_IMAGE:-seafileltd/seafile-mc:13.0.18}
    container_name: seafile
    restart: always
    volumes:
      - ${SEAFILE_VOLUME:-/opt/seafile-data}:/shared
    environment:
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD}
      - INIT_SEAFILE_MYSQL_ROOT_PASSWORD=${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - SEAFILE_MYSQL_DB_SEAHUB_DB_NAME=${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}
      - TIME_ZONE=${TIME_ZONE:-America/New_York}
      - SEAFILE_SERVER_HOSTNAME=${SEAFILE_SERVER_HOSTNAME}
      - SEAFILE_SERVER_PROTOCOL=${SEAFILE_SERVER_PROTOCOL:-https}
      - SEAFILE_CSRF_TRUSTED_ORIGINS=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}
      - SITE_ROOT=${SITE_ROOT:-/}
      - NON_ROOT=${NON_ROOT:-false}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-true}
      - CACHE_PROVIDER=redis
      - REDIS_HOST=seafile-redis
      - REDIS_PORT=${REDIS_PORT:-6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
      - ENABLE_GO_FILESERVER=${ENABLE_GO_FILESERVER:-true}
      - ENABLE_SEADOC=${ENABLE_SEADOC:-true}
      - SEADOC_SERVER_URL=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}/sdoc-server
      - ENABLE_NOTIFICATION_SERVER=${ENABLE_NOTIFICATION_SERVER:-true}
      - INNER_NOTIFICATION_SERVER_URL=http://notification-server:8083
      - NOTIFICATION_SERVER_URL=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}/notification
      - ENABLE_METADATA_SERVER=${ENABLE_METADATA_SERVER:-true}
      - METADATA_SERVER_URL=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}/metadata
      - MD_FILE_COUNT_LIMIT=${MD_FILE_COUNT_LIMIT:-100000}
      - ENABLE_THUMBNAIL_SERVER=${ENABLE_THUMBNAIL_SERVER:-true}
      - THUMBNAIL_SERVER_URL=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}/thumbnail-server/
      - ENABLE_SEAFILE_AI=${ENABLE_SEAFILE_AI:-false}
      - ENABLE_FACE_RECOGNITION=${ENABLE_FACE_RECOGNITION:-false}
      - INIT_SEAFILE_ADMIN_EMAIL=${INIT_SEAFILE_ADMIN_EMAIL}
      - INIT_SEAFILE_ADMIN_PASSWORD=${INIT_SEAFILE_ADMIN_PASSWORD}
    depends_on:
      - redis
    networks:
      - seafile-net

  # --- SeaDoc (collaborative .sdoc editing) ---
  seadoc:
    image: ${SEADOC_IMAGE:-seafileltd/sdoc-server:2.0-latest}
    container_name: seadoc
    restart: always
    volumes:
      - ${SEADOC_DATA_PATH:-/opt/seadoc-data}:/shared
    environment:
      - DB_HOST=${SEAFILE_MYSQL_DB_HOST}
      - DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD}
      - DB_NAME=${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}
      - TIME_ZONE=${TIME_ZONE:-America/New_York}
      - NON_ROOT=${NON_ROOT:-false}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAHUB_SERVICE_URL=${SEAFILE_SERVER_PROTOCOL:-https}://${SEAFILE_SERVER_HOSTNAME}
    networks:
      - seafile-net

  # --- Notification Server ---
  notification-server:
    image: ${NOTIFICATION_SERVER_IMAGE:-seafileltd/notification-server:13.0.10}
    container_name: notification-server
    restart: always
    volumes:
      - ${SEAFILE_VOLUME:-/opt/seafile-data}/seafile/logs:/shared/seafile/logs
    environment:
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-true}
      - NOTIFICATION_SERVER_LOG_LEVEL=${NOTIFICATION_SERVER_LOG_LEVEL:-info}
    networks:
      - seafile-net

  # --- Thumbnail Server ---
  thumbnail-server:
    image: ${THUMBNAIL_SERVER_IMAGE:-seafileltd/thumbnail-server:13.0-latest}
    container_name: thumbnail-server
    restart: always
    volumes:
      - ${SEAFILE_VOLUME:-/opt/seafile-data}:/shared/seafile-data:ro
      - ${SEAFILE_VOLUME:-/opt/seafile-data}/seafile/conf:/shared/seafile/conf:ro
      - ${SEAFILE_VOLUME:-/opt/seafile-data}/seafile/seafile-data:/shared/seafile/seafile-data:ro
      - ${THUMBNAIL_PATH:-/opt/seafile-thumbnails}:/shared/seafile/seahub-data/thumbnail
    environment:
      - TIME_ZONE=${TIME_ZONE:-America/New_York}
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD}
      - SEAFILE_MYSQL_DB_CCNET_DB_NAME=${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - NON_ROOT=${NON_ROOT:-false}
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-true}
      - SITE_ROOT=${SITE_ROOT:-/}
      - INNER_SEAHUB_SERVICE_URL=http://seafile
      - SEAFILE_CONF_DIR=/shared/seafile-data/seafile/conf
    networks:
      - seafile-net

  # --- Metadata Server ---
  metadata-server:
    image: ${MD_IMAGE:-seafileltd/seafile-md-server:13.0-latest}
    container_name: seafile-metadata
    restart: unless-stopped
    volumes:
      - ${SEAFILE_VOLUME:-/opt/seafile-data}:/shared/seafile-data:ro
      - ${SEAFILE_VOLUME:-/opt/seafile-data}/seafile/conf:/shared/seafile/conf:ro
      - ${SEAFILE_VOLUME:-/opt/seafile-data}/seafile/seafile-data:/shared/seafile/seafile-data:ro
      - ${METADATA_PATH:-/opt/seafile-metadata}:/shared/seafile-metadata
    environment:
      - JWT_PRIVATE_KEY=${JWT_PRIVATE_KEY}
      - SEAFILE_MYSQL_DB_HOST=${SEAFILE_MYSQL_DB_HOST}
      - SEAFILE_MYSQL_DB_PORT=${SEAFILE_MYSQL_DB_PORT:-3306}
      - SEAFILE_MYSQL_DB_USER=${SEAFILE_MYSQL_DB_USER:-seafile}
      - SEAFILE_MYSQL_DB_PASSWORD=${SEAFILE_MYSQL_DB_PASSWORD}
      - SEAFILE_MYSQL_DB_SEAFILE_DB_NAME=${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}
      - SEAFILE_LOG_TO_STDOUT=${SEAFILE_LOG_TO_STDOUT:-true}
      - MD_FILE_COUNT_LIMIT=${MD_FILE_COUNT_LIMIT:-100000}
      - CACHE_PROVIDER=redis
      - REDIS_HOST=seafile-redis
      - REDIS_PORT=${REDIS_PORT:-6379}
      - REDIS_PASSWORD=${REDIS_PASSWORD:-}
      - SEAFILE_CONF_DIR=/shared/seafile-data/seafile/conf
    networks:
      - seafile-net

  # --- Collabora Online ---
  # Active when OFFICE_SUITE=collabora (profile: collabora).
  # ssl.enable=false and ssl.termination=true required — SSL is handled upstream.
  # aliasgroup1 = your domain with dots escaped: seafile\.yourdomain\.com
  collabora:
    image: ${COLLABORA_IMAGE:-collabora/code:25.04.8.1.1}
    container_name: seafile-collabora
    restart: always
    profiles:
      - collabora
    cap_add:
      - MKNOD
    environment:
      - aliasgroup1=${COLLABORA_ALIAS_GROUP}
      - "extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:admin_console.enable=true"
      - server_name=${SEAFILE_SERVER_HOSTNAME}
      - username=${COLLABORA_ADMIN_USER}
      - password=${COLLABORA_ADMIN_PASSWORD}
      - DONT_GEN_SSL_CERT=true
    networks:
      - seafile-net

  # --- OnlyOffice Document Server ---
  # Active when OFFICE_SUITE=onlyoffice (profile: onlyoffice).
  # Requires 4–8 GB RAM. Exposes ONLYOFFICE_PORT on the host for your reverse proxy.
  # JWT_SECRET must match the value written to seahub_settings.py.
  onlyoffice:
    image: ${ONLYOFFICE_IMAGE:-onlyoffice/documentserver:8.1.0.1}
    container_name: seafile-onlyoffice
    restart: always
    profiles:
      - onlyoffice
    ports:
      - "${ONLYOFFICE_PORT:-6233}:80"
    volumes:
      - ${ONLYOFFICE_VOLUME:-/opt/onlyoffice}/logs:/var/log/onlyoffice
      - ${ONLYOFFICE_VOLUME:-/opt/onlyoffice}/data:/var/www/onlyoffice/Data
      - ${ONLYOFFICE_VOLUME:-/opt/onlyoffice}/lib:/var/lib/onlyoffice
      - ${ONLYOFFICE_VOLUME:-/opt/onlyoffice}/db:/var/lib/postgresql
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=${ONLYOFFICE_JWT_SECRET}
      - JWT_HEADER=AuthorizationJwt
    networks:
      - seafile-net

  # --- ClamAV Antivirus ---
  # Active when CLAMAV_ENABLED=true (profile: clamav).
  # First start takes 5–15 minutes downloading virus definitions (~300 MB).
  # Requires ~1 GB RAM for the signature database.
  clamav:
    image: ${CLAMAV_IMAGE:-clamav/clamav:stable}
    container_name: seafile-clamav
    restart: always
    profiles:
      - clamav
    networks:
      - seafile-net

  # --- MariaDB (bundled database) ---
  # Active when DB_INTERNAL=true (profile: internal-db).
  # Seafile's own init creates the three databases on first boot using
  # INIT_SEAFILE_MYSQL_ROOT_PASSWORD. No separate init script is needed.
  #
  # Data lives at DB_INTERNAL_VOLUME (default: /opt/seafile-db on local disk).
  # For full disaster recovery, set DB_INTERNAL_VOLUME to a subdirectory of
  # SEAFILE_VOLUME so the database lives on your network share.
  # Example: DB_INTERNAL_VOLUME=/mnt/seafile_nfs/db
  seafile-db:
    image: ${DB_INTERNAL_IMAGE:-mariadb:10.11}
    container_name: seafile-db
    restart: always
    profiles:
      - internal-db
    environment:
      - MYSQL_ROOT_PASSWORD=${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      - MYSQL_LOG_CONSOLE=true
      - MARIADB_AUTO_UPGRADE=1
    volumes:
      - ${DB_INTERNAL_VOLUME:-/opt/seafile-db}:/var/lib/mysql
    networks:
      - seafile-net

networks:
  seafile-net:
    name: ${SEAFILE_NETWORK:-seafile-net}
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
NFS_USAGE=$(df -h "$STORAGE_MOUNT" 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full)"}' \
  || df -h "$STORAGE_PATH" 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full")"}' \
  || echo "unavailable")
LOCAL_USAGE=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full)"}' || echo "unavailable")
THUMB_USAGE=$(du -sh "${THUMBNAIL_PATH:-/opt/seafile-thumbnails}" 2>/dev/null | cut -f1 || echo "0")
META_USAGE=$(du -sh "${METADATA_PATH:-/opt/seafile-metadata}" 2>/dev/null | cut -f1 || echo "0")

echo -e "    Storage (${STORAGE_PATH}):          ${NFS_USAGE}"
echo -e "    Local disk (/opt):                  ${LOCAL_USAGE}"
echo -e "    Thumbnail cache:                    ${THUMB_USAGE}"
echo -e "    Metadata index:                     ${META_USAGE}"

# --- Disk usage warnings ---
_NFS_PCT=$(df "$STORAGE_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
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
    echo -e "  ${DIM}  PORTAINER_MANAGED=true — Portainer notified via webhook.${NC}"
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

