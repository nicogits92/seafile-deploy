#!/bin/bash
# =============================================================================
# GENERATED FILE — do not edit directly.
# Edit the source files and run ./build.sh to regenerate.
#
# Sources:
#   src/deploy-header.sh          — preamble, splash, mode selection
#   src/deploy-middle.sh          — transition between embedded scripts
#   src/deploy-footer.sh          — secret generation, main entry loop
#   scripts/install-dependencies.sh — embedded as extract_install()
#   scripts/recover.sh             — embedded as extract_recover()
# =============================================================================
# =============================================================================
# seafile-deploy.sh  —  nicogits92 / seafile-deploy
# =============================================================================
# The single entry point for this Seafile deployment.
# Run this on a freshly provisioned Debian VM after placing .env at
# /opt/seafile/.env — it handles both fresh installs and disaster recovery.
#
# Usage:
#   sudo bash seafile-deploy.sh
#
# What it does:
#   1  Fresh Install   — runs install-dependencies.sh
#   2  Recovery Mode   — runs recover.sh
#   3  Migrate / Adopt — runs migrate flow
#   4  Have Fun        — Snake
#   0  Quit
# =============================================================================

set -euo pipefail

DEPLOY_VERSION="v4.7-alpha"

# ---------------------------------------------------------------------------
# Colours (shared-lib provides these too, but header runs before it's loaded)
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
# Source .env for version display (optional — graceful if not yet placed)
# ---------------------------------------------------------------------------
ENV_FILE="/opt/seafile/.env"
SEAFILE_VERSION="13"
if [[ -f "$ENV_FILE" ]]; then
  SEAFILE_IMAGE=$(grep "^SEAFILE_IMAGE=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)
  if [[ -n "$SEAFILE_IMAGE" ]]; then
    _ver=$(echo "$SEAFILE_IMAGE" | grep -oP '\d+(\.\d+)+' | head -1 || true)
    [[ -n "$_ver" ]] && SEAFILE_VERSION="$_ver"
  fi
fi

# ---------------------------------------------------------------------------
# Splash screen
# ---------------------------------------------------------------------------
show_splash() {
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
  echo -e "  ${BOLD}nicogits92 / seafile-deploy${NC}   ${DIM}Seafile ${SEAFILE_VERSION} CE  ·  ${DEPLOY_VERSION}${NC}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${DIM}Community deployment · not affiliated with Seafile Ltd.${NC}"
  echo ""
  echo ""
  echo -e "  What would you like to do?"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Fresh Install${NC}"
  echo -e "     ${DIM}Set up a new Seafile VM from scratch${NC}"
  echo ""
  echo -e "  ${YELLOW}${BOLD}  2  ${NC}${BOLD}Recovery Mode${NC}"
  echo -e "     ${DIM}Restore a lost VM from an existing NFS share${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  3  ${NC}${BOLD}Migrate / Adopt Existing Seafile${NC}"
  echo -e "     ${DIM}Import data from another server or adopt an existing instance${NC}"
  echo ""
  echo -e "  ${PURPLE}${BOLD}  4  ${NC}${BOLD}Have Fun${NC}"
  echo -e "     ${DIM}Take a break · while you still can${NC}"
  echo ""
  echo -e "  ${DIM}  0  Quit${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -ne "  ${BOLD}Select [0-4]:${NC} "
}

# ---------------------------------------------------------------------------
# Snake game
# ---------------------------------------------------------------------------
play_snake() {
  # Requires: tput, stty  (standard on all Debian systems)
  local W=40 H=20  # inner board dimensions
  local BX=2 BY=3  # board top-left corner (screen coords)

  # Snake state — arrays of x,y coords; index 0 = head
  local -a SX SY
  local DX=1 DY=0   # current direction
  local NX=1 NY=0   # next direction (buffered)
  local FX FY       # food position
  local SCORE=0
  local BEST=0
  local BEST_FILE="/tmp/seafile-snake-best"
  [[ -f "$BEST_FILE" ]] && BEST=$(cat "$BEST_FILE" 2>/dev/null || echo 0)

  # Symbols
  local SYM_BODY="●"
  local SYM_FOOD="◆"
  local SYM_DEAD="✖"

  # Place snake in middle, length 3, facing right
  SX=($(( W/2 )) $(( W/2 - 1 )) $(( W/2 - 2 )))
  SY=($(( H/2 )) $(( H/2   )) $(( H/2   )))

  # Random food placement (not on snake)
  place_food() {
    while true; do
      FX=$(( RANDOM % W + 1 ))
      FY=$(( RANDOM % H + 1 ))
      local ok=true
      for i in "${!SX[@]}"; do
        [[ "${SX[$i]}" -eq "$FX" && "${SY[$i]}" -eq "$FY" ]] && ok=false && break
      done
      $ok && break
    done
  }
  place_food

  # Draw border
  draw_board() {
    tput clear
    # Header
    tput cup 0 0
    echo -e "  ${CYAN}${BOLD}SNAKE${NC}  ${DIM}Score: ${BOLD}${SCORE}${NC}  ${DIM}Best: ${BEST}${NC}  ${DIM}[arrow keys] [q quit]${NC}"
    tput cup 1 0
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Top border
    tput cup $(( BY - 1 )) $(( BX - 1 ))
    printf "${DIM}┌"
    printf '─%.0s' $(seq 1 $W)
    printf "┐${NC}"

    # Side borders
    for (( y=0; y<H; y++ )); do
      tput cup $(( BY + y )) $(( BX - 1 ))
      printf "${DIM}│${NC}"
      tput cup $(( BY + y )) $(( BX + W ))
      printf "${DIM}│${NC}"
    done

    # Bottom border
    tput cup $(( BY + H )) $(( BX - 1 ))
    printf "${DIM}└"
    printf '─%.0s' $(seq 1 $W)
    printf "┘${NC}"
  }

  # Draw a cell
  draw_cell() {
    local cx=$1 cy=$2 sym=$3 col=$4
    tput cup $(( BY + cy - 1 )) $(( BX + cx - 1 ))
    echo -ne "${col}${sym}${NC}"
  }

  # Erase a cell
  erase_cell() {
    tput cup $(( BY + $2 - 1 )) $(( BX + $1 - 1 ))
    echo -ne " "
  }

  # Initial draw
  draw_board
  for i in "${!SX[@]}"; do
    draw_cell "${SX[$i]}" "${SY[$i]}" "$SYM_BODY" "${GREEN}"
  done
  draw_cell "$FX" "$FY" "$SYM_FOOD" "${YELLOW}"

  # Update score header
  update_header() {
    tput cup 0 0
    echo -e "  ${CYAN}${BOLD}SNAKE${NC}  ${DIM}Score: ${BOLD}${SCORE}${NC}  ${DIM}Best: ${BEST}${NC}  ${DIM}[arrow keys] [q quit]${NC}      "
  }

  # Non-blocking input — save/restore terminal settings
  local old_stty
  old_stty=$(stty -g)
  stty -echo -icanon min 0 time 0

  local ALIVE=true
  local TICK=0.12  # seconds per frame

  while $ALIVE; do
    # Read input (non-blocking)
    local key=""
    IFS= read -r -s -t 0.001 -n 1 key 2>/dev/null || true
    if [[ "$key" == $'\033' ]]; then
      local seq=""
      IFS= read -r -s -t 0.05 -n 2 seq 2>/dev/null || true
      case "$seq" in
        '[A') [[ $DY -ne 1  ]] && NX=0  && NY=-1 ;;  # up
        '[B') [[ $DY -ne -1 ]] && NX=0  && NY=1  ;;  # down
        '[C') [[ $DX -ne -1 ]] && NX=1  && NY=0  ;;  # right
        '[D') [[ $DX -ne 1  ]] && NX=-1 && NY=0  ;;  # left
      esac
    elif [[ "$key" == "q" || "$key" == "Q" ]]; then
      ALIVE=false; break
    fi

    # Apply buffered direction
    DX=$NX; DY=$NY

    # Compute new head
    local HX=$(( SX[0] + DX ))
    local HY=$(( SY[0] + DY ))

    # Wall collision
    if (( HX < 1 || HX > W || HY < 1 || HY > H )); then
      ALIVE=false; break
    fi

    # Self collision
    for i in "${!SX[@]}"; do
      if [[ "${SX[$i]}" -eq "$HX" && "${SY[$i]}" -eq "$HY" ]]; then
        ALIVE=false; break 2
      fi
    done

    # Ate food?
    local ate=false
    [[ "$HX" -eq "$FX" && "$HY" -eq "$FY" ]] && ate=true

    # Erase tail (unless eating)
    if ! $ate; then
      local TX="${SX[-1]}" TY="${SY[-1]}"
      unset 'SX[-1]'; unset 'SY[-1]'
      erase_cell "$TX" "$TY"
    fi

    # Prepend new head
    SX=("$HX" "${SX[@]}")
    SY=("$HY" "${SY[@]}")

    # Draw new head, recolour old head as body
    if [[ "${#SX[@]}" -gt 1 ]]; then
      draw_cell "${SX[1]}" "${SY[1]}" "$SYM_BODY" "${GREEN}"
    fi
    draw_cell "$HX" "$HY" "$SYM_BODY" "${BOLD}${GREEN}"

    if $ate; then
      SCORE=$(( SCORE + 10 ))
      (( SCORE > BEST )) && BEST=$SCORE && echo "$BEST" > "$BEST_FILE"
      update_header
      place_food
      draw_cell "$FX" "$FY" "$SYM_FOOD" "${YELLOW}"
      # Speed up slightly every 50 points
      if (( SCORE % 50 == 0 )) && (( $(echo "$TICK > 0.05" | bc -l) )); then
        TICK=$(echo "$TICK - 0.01" | bc -l 2>/dev/null || echo "0.05")
      fi
    fi

    sleep "$TICK"
  done

  # Restore terminal
  stty "$old_stty"

  # Draw death marker
  draw_cell "${SX[0]}" "${SY[0]}" "$SYM_DEAD" "${RED}"

  # Game over screen
  tput cup $(( BY + H + 2 )) 0
  echo ""
  echo -e "  ${RED}${BOLD}  GAME OVER  ${NC}"
  echo ""
  echo -e "  Score: ${BOLD}${SCORE}${NC}    Best: ${BOLD}${BEST}${NC}"
  echo ""
  echo -ne "  ${DIM}Press any key to return to menu...${NC}"
  old_stty=$(stty -g)
  stty -echo -icanon min 1 time 0
  read -r -s -n 1
  stty "$old_stty"
}


# ---------------------------------------------------------------------------
# NFS config prompt — used by Recovery Mode to collect the three values
# needed before recover.sh can run. Exports them so the subprocess inherits.
# ---------------------------------------------------------------------------
prompt_storage_config() {
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Storage configuration${NC}"
  echo ""
  echo -e "  Select your storage type:"
  echo ""
  echo -e "  ${BOLD}  1  ${NC}NFS ${DIM}(recommended)${NC}"
  echo -e "     ${DIM}Network File System — supported by most NAS devices and Linux servers${NC}"
  echo ""
  echo -e "  ${BOLD}  2  ${NC}SMB / CIFS"
  echo -e "     ${DIM}Windows shares, Samba, and most NAS web UIs${NC}"
  echo ""
  echo -e "  ${BOLD}  3  ${NC}GlusterFS"
  echo -e "     ${DIM}Distributed filesystem for self-hosted multi-node setups${NC}"
  echo ""
  echo -e "  ${BOLD}  4  ${NC}iSCSI"
  echo -e "     ${DIM}Block-level storage — SAN targets and enterprise NAS${NC}"
  echo ""
  echo -e "  ${DIM}  Local disk is not available in Recovery Mode —${NC}"
  echo -e "  ${DIM}  data cannot be recovered without network storage.${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local _stype_choice
  while true; do
    echo -ne "  ${BOLD}Select [1-4] (default: 1 — NFS):${NC} "
    read -r _stype_choice
    _stype_choice="${_stype_choice:-1}"
    case "$_stype_choice" in
      1|2|3|4) break ;;
      *) echo -e "  ${DIM}Enter a number from 1 to 4.${NC}" ;;
    esac
  done

  echo ""

  case "$_stype_choice" in

    1)  # NFS
      export STORAGE_TYPE="nfs"
      while true; do
        echo -ne "  ${BOLD}NFS server IP${NC}  (e.g. 10.0.0.5): "
        read -r NFS_SERVER; NFS_SERVER="${NFS_SERVER// /}"
        [[ -n "$NFS_SERVER" ]] && break
        echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}NFS export path${NC}  (e.g. /volume1/seafile): "
        read -r NFS_EXPORT; NFS_EXPORT="${NFS_EXPORT// /}"
        [[ -n "$NFS_EXPORT" ]] && break
        echo -e "  ${RED}Required.${NC}"
      done
      echo -ne "  ${BOLD}Mount point${NC}  [/mnt/seafile_nfs]: "
      read -r STORAGE_MOUNT
      STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/seafile_nfs}"
      export NFS_SERVER NFS_EXPORT STORAGE_MOUNT
      ;;

    2)  # SMB
      export STORAGE_TYPE="smb"
      while true; do
        echo -ne "  ${BOLD}SMB server IP or hostname${NC}  (e.g. 10.0.0.5): "
        read -r SMB_SERVER; SMB_SERVER="${SMB_SERVER// /}"
        [[ -n "$SMB_SERVER" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}Share name${NC}  (e.g. seafile): "
        read -r SMB_SHARE; SMB_SHARE="${SMB_SHARE// /}"
        [[ -n "$SMB_SHARE" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}Username${NC}: "
        read -r SMB_USERNAME; SMB_USERNAME="${SMB_USERNAME// /}"
        [[ -n "$SMB_USERNAME" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}Password${NC}: "
        read -rs SMB_PASSWORD; echo ""
        [[ -n "$SMB_PASSWORD" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      echo -ne "  ${BOLD}Domain${NC}  (leave blank for standalone/workgroup): "
      read -r SMB_DOMAIN
      echo -ne "  ${BOLD}Mount point${NC}  [/mnt/seafile_smb]: "
      read -r STORAGE_MOUNT; STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/seafile_smb}"
      export SMB_SERVER SMB_SHARE SMB_USERNAME SMB_PASSWORD SMB_DOMAIN STORAGE_MOUNT
      ;;

    3)  # GlusterFS
      export STORAGE_TYPE="glusterfs"
      while true; do
        echo -ne "  ${BOLD}GlusterFS server IP${NC}  (e.g. 10.0.0.5): "
        read -r GLUSTER_SERVER; GLUSTER_SERVER="${GLUSTER_SERVER// /}"
        [[ -n "$GLUSTER_SERVER" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}Volume name${NC}  (e.g. gv0): "
        read -r GLUSTER_VOLUME; GLUSTER_VOLUME="${GLUSTER_VOLUME// /}"
        [[ -n "$GLUSTER_VOLUME" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      echo -ne "  ${BOLD}Mount point${NC}  [/mnt/seafile_gluster]: "
      read -r STORAGE_MOUNT; STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/seafile_gluster}"
      export GLUSTER_SERVER GLUSTER_VOLUME STORAGE_MOUNT
      ;;

    4)  # iSCSI
      export STORAGE_TYPE="iscsi"
      while true; do
        echo -ne "  ${BOLD}iSCSI portal${NC}  (IP:port, e.g. 10.0.0.5:3260): "
        read -r ISCSI_PORTAL; ISCSI_PORTAL="${ISCSI_PORTAL// /}"
        [[ -n "$ISCSI_PORTAL" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      while true; do
        echo -ne "  ${BOLD}Target IQN${NC}  (e.g. iqn.2024-01.com.example:storage): "
        read -r ISCSI_TARGET_IQN; ISCSI_TARGET_IQN="${ISCSI_TARGET_IQN// /}"
        [[ -n "$ISCSI_TARGET_IQN" ]] && break; echo -e "  ${RED}Required.${NC}"
      done
      echo ""
      echo -e "  ${DIM}CHAP authentication is optional but recommended.${NC}"
      echo -e "  ${DIM}If set, the password must also be configured on your iSCSI target.${NC}"
      echo -ne "  ${BOLD}CHAP username${NC}  (leave blank to disable CHAP): "
      read -r ISCSI_CHAP_USERNAME
      if [[ -n "$ISCSI_CHAP_USERNAME" ]]; then
        echo -e "  ${DIM}Enter the CHAP password that was used in the original deployment.${NC}"
      echo -ne "  ${BOLD}CHAP password${NC}: "
        read -rs ISCSI_CHAP_PASSWORD; echo ""
      fi
      echo -ne "  ${BOLD}Mount point${NC}  [/mnt/seafile_iscsi]: "
      read -r STORAGE_MOUNT; STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/seafile_iscsi}"
      export ISCSI_PORTAL ISCSI_TARGET_IQN ISCSI_CHAP_USERNAME ISCSI_CHAP_PASSWORD STORAGE_MOUNT
      ;;


  esac

  # Show summary
  echo ""
  echo -e "  ${DIM}  Storage type:  ${NC}${STORAGE_TYPE}"
  case "$STORAGE_TYPE" in
    nfs)       echo -e "  ${DIM}  Server:        ${NC}${NFS_SERVER}"; echo -e "  ${DIM}  Export:        ${NC}${NFS_EXPORT}" ;;
    smb)       echo -e "  ${DIM}  Server:        ${NC}//${SMB_SERVER}/${SMB_SHARE}" ;;
    glusterfs) echo -e "  ${DIM}  Server:        ${NC}${GLUSTER_SERVER}:/${GLUSTER_VOLUME}" ;;
    iscsi)     echo -e "  ${DIM}  Portal:        ${NC}${ISCSI_PORTAL}"; echo -e "  ${DIM}  IQN:           ${NC}${ISCSI_TARGET_IQN}" ;;
  esac
  echo -e "  ${DIM}  Mount point:   ${NC}${STORAGE_MOUNT}"
  echo ""

  while true; do
    echo -ne "  ${BOLD}Continue with these settings? [Y/n]:${NC} "
    read -r _confirm
    _confirm="${_confirm:-y}"
    case "${_confirm,,}" in
      y|yes) break ;;
      n|no)
        echo ""
        echo -e "  ${DIM}Re-enter your storage details.${NC}"
        echo ""
        prompt_storage_config
        return
        ;;
      *) echo -e "  ${DIM}Enter y or n.${NC}" ;;
    esac
  done

  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}


# ---------------------------------------------------------------------------
# Migration sub-menu — called when user selects option 3 from splash screen
# Sets MIGRATE_TYPE to: adopt | prepared | ssh
# For SSH: also collects MIGRATE_SSH_HOST, MIGRATE_SSH_USER, MIGRATE_SSH_PORT
# For Prepared: collects MIGRATE_DUMP_DIR, MIGRATE_DATA_DIR, MIGRATE_CONF_DIR
# ---------------------------------------------------------------------------
prompt_migration_type() {
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}What describes your situation?${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Adopt in place${NC}"
  echo -e "     ${DIM}Seafile is already running with its storage and/or database.${NC}"
  echo -e "     ${DIM}Install seafile-deploy as the management layer on top.${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  2  ${NC}${BOLD}Migrate from prepared backup${NC}"
  echo -e "     ${DIM}I have database dumps (.sql.gz) and a data directory${NC}"
  echo -e "     ${DIM}ready on this machine or on a mount.${NC}"
  echo ""
  echo -e "  ${YELLOW}${BOLD}  3  ${NC}${BOLD}Migrate from another server (SSH)${NC}"
  echo -e "     ${DIM}Copy databases and files from a remote Seafile instance.${NC}"
  echo -e "     ${DIM}Requires SSH access to the source server.${NC}"
  echo ""
  echo -e "  ${DIM}  0  Back${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local _mig_choice
  while true; do
    echo -ne "  ${BOLD}Select [0-3]:${NC} "
    read -r _mig_choice
    case "$_mig_choice" in 0|1|2|3) break ;; *) echo -e "  ${DIM}Enter 0, 1, 2, or 3.${NC}" ;; esac
  done

  case "$_mig_choice" in
    0) return 1 ;;  # Go back to splash
    1) export MIGRATE_TYPE="adopt" ;;
    2) _collect_prepared_source || return 1 ;;
    3) _collect_ssh_source || return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Collect prepared backup source paths
# ---------------------------------------------------------------------------
_collect_prepared_source() {
  export MIGRATE_TYPE="prepared"
  echo ""
  echo -e "  ${BOLD}Prepared Backup — Source Paths${NC}"
  echo ""
  echo -e "  ${DIM}Point to the directory containing your database dumps and${NC}"
  echo -e "  ${DIM}Seafile data. The dumps can be .sql.gz or .sql files named${NC}"
  echo -e "  ${DIM}with the database name (e.g. ccnet_db.sql.gz, seahub_db.sql.gz).${NC}"
  echo ""

  # Database dumps directory
  while true; do
    echo -ne "  ${BOLD}Database dumps directory${NC}: "
    read -r MIGRATE_DUMP_DIR
    MIGRATE_DUMP_DIR="${MIGRATE_DUMP_DIR%/}"
    if [[ -z "$MIGRATE_DUMP_DIR" ]]; then
      echo -e "  ${DIM}Required — path to directory containing .sql.gz or .sql files.${NC}"
    elif [[ ! -d "$MIGRATE_DUMP_DIR" ]]; then
      echo -e "  ${RED}Directory not found: ${MIGRATE_DUMP_DIR}${NC}"
    else
      local _dump_count=$(ls "$MIGRATE_DUMP_DIR"/*.sql* 2>/dev/null | wc -l)
      if [[ "$_dump_count" -eq 0 ]]; then
        echo -e "  ${YELLOW}No .sql or .sql.gz files found in ${MIGRATE_DUMP_DIR}${NC}"
        echo -ne "  ${DIM}Continue anyway? [y/N]:${NC} "
        read -r _cont
        [[ "${_cont,,}" == "y" ]] && break
      else
        echo -e "  ${DIM}Found ${_dump_count} dump file(s).${NC}"
        break
      fi
    fi
  done
  export MIGRATE_DUMP_DIR

  # Seafile data directory
  echo ""
  echo -e "  ${DIM}This is the directory containing seafile-data/ (block storage),${NC}"
  echo -e "  ${DIM}the conf/ directory (with seahub_settings.py), and seahub-data/.${NC}"
  echo -e "  ${DIM}For Docker installs this is the volume mapped to /shared.${NC}"
  echo -e "  ${DIM}For manual installs it is usually /opt/seafile.${NC}"
  echo ""
  while true; do
    echo -ne "  ${BOLD}Seafile data directory${NC}: "
    read -r MIGRATE_DATA_DIR
    MIGRATE_DATA_DIR="${MIGRATE_DATA_DIR%/}"
    if [[ -z "$MIGRATE_DATA_DIR" ]]; then
      echo -e "  ${DIM}Required.${NC}"
    elif [[ ! -d "$MIGRATE_DATA_DIR" ]]; then
      echo -e "  ${RED}Directory not found: ${MIGRATE_DATA_DIR}${NC}"
    else
      # Auto-detect layout
      if [[ -d "${MIGRATE_DATA_DIR}/seafile-data" ]]; then
        echo -e "  ${GREEN}✓${NC} Found seafile-data/"
      elif [[ -d "${MIGRATE_DATA_DIR}/storage" ]]; then
        echo -e "  ${YELLOW}Found storage/ directly — this looks like the seafile-data dir itself.${NC}"
        echo -e "  ${DIM}Point to the parent directory instead.${NC}"
        continue
      else
        echo -e "  ${YELLOW}No seafile-data/ found — files may be in a different layout.${NC}"
      fi
      # Look for config
      if [[ -f "${MIGRATE_DATA_DIR}/seafile/conf/seahub_settings.py" ]]; then
        echo -e "  ${GREEN}✓${NC} Found config at seafile/conf/ (Docker layout)"
        export MIGRATE_CONF_DIR="${MIGRATE_DATA_DIR}/seafile/conf"
      elif [[ -f "${MIGRATE_DATA_DIR}/conf/seahub_settings.py" ]]; then
        echo -e "  ${GREEN}✓${NC} Found config at conf/ (manual layout)"
        export MIGRATE_CONF_DIR="${MIGRATE_DATA_DIR}/conf"
      else
        echo -e "  ${DIM}No config directory detected — SECRET_KEY will be generated fresh.${NC}"
        export MIGRATE_CONF_DIR=""
      fi
      # Look for avatars
      if [[ -d "${MIGRATE_DATA_DIR}/seafile/seahub-data/avatars" ]]; then
        echo -e "  ${GREEN}✓${NC} Found avatars"
      elif [[ -d "${MIGRATE_DATA_DIR}/seahub-data/avatars" ]]; then
        echo -e "  ${GREEN}✓${NC} Found avatars (manual layout)"
      fi
      break
    fi
  done
  export MIGRATE_DATA_DIR
  return 0
}

# ---------------------------------------------------------------------------
# Collect SSH source details
# ---------------------------------------------------------------------------
_collect_ssh_source() {
  export MIGRATE_TYPE="ssh"
  echo ""
  echo -e "  ${BOLD}SSH Migration — Source Server${NC}"
  echo ""

  while true; do
    echo -ne "  ${BOLD}SSH host${NC} (IP or hostname): "
    read -r MIGRATE_SSH_HOST
    [[ -n "$MIGRATE_SSH_HOST" ]] && break
    echo -e "  ${DIM}Required.${NC}"
  done
  echo -ne "  ${BOLD}SSH user${NC} [root]: "
  read -r MIGRATE_SSH_USER
  MIGRATE_SSH_USER="${MIGRATE_SSH_USER:-root}"
  echo -ne "  ${BOLD}SSH port${NC} [22]: "
  read -r MIGRATE_SSH_PORT
  MIGRATE_SSH_PORT="${MIGRATE_SSH_PORT:-22}"

  export MIGRATE_SSH_HOST MIGRATE_SSH_USER MIGRATE_SSH_PORT

  # Ensure an SSH key exists
  if [[ ! -f ~/.ssh/id_ed25519 && ! -f ~/.ssh/id_rsa ]]; then
    echo ""
    echo -e "  ${DIM}No SSH key found — generating one...${NC}"
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
    echo -e "  ${GREEN}✓${NC} SSH key generated"
  fi

  # Test connection
  echo ""
  echo -e "  ${DIM}Testing SSH connection...${NC}"
  if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -p "$MIGRATE_SSH_PORT" "${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}" "echo ok" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Connected to ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}"
  else
    echo ""
    echo -e "  ${DIM}SSH key auth not set up yet. This will copy your public key${NC}"
    echo -e "  ${DIM}to the remote server. You will be asked for the remote${NC}"
    echo -e "  ${DIM}password once — after that, key auth will be used.${NC}"
    echo ""
    echo -ne "  ${BOLD}Copy SSH key to ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}? [Y/n]:${NC} "
    read -r _do_copy
    if [[ "${_do_copy,,}" != "n" ]]; then
      ssh-copy-id -o StrictHostKeyChecking=accept-new \
        -p "$MIGRATE_SSH_PORT" "${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}"
      echo ""
      # Retry connection
      echo -e "  ${DIM}Verifying connection...${NC}"
      if ssh -o ConnectTimeout=10 -o BatchMode=yes \
          -p "$MIGRATE_SSH_PORT" "${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}" "echo ok" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Connected to ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}"
      else
        echo -e "  ${RED}✗${NC} Still cannot connect. Check that:"
        echo -e "    ${DIM}• The password was correct${NC}"
        echo -e "    ${DIM}• PermitRootLogin is set to 'yes' in /etc/ssh/sshd_config on the remote${NC}"
        echo -e "    ${DIM}• SSH is running on the remote (systemctl status ssh)${NC}"
        echo ""
        echo -ne "  ${DIM}Try again? [Y/n]:${NC} "
        read -r _retry
        if [[ "${_retry,,}" != "n" ]]; then
          _collect_ssh_source
          return $?
        fi
        return 1
      fi
    else
      echo -e "  ${DIM}Set up SSH key auth manually and try again:${NC}"
      echo -e "    ${DIM}ssh-copy-id -p ${MIGRATE_SSH_PORT} ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}${NC}"
      echo ""
      echo -ne "  ${DIM}Try again? [Y/n]:${NC} "
      read -r _retry
      if [[ "${_retry,,}" != "n" ]]; then
        _collect_ssh_source
        return $?
      fi
      return 1
    fi
  fi

  # Auto-detect source Seafile
  echo -e "  ${DIM}Detecting Seafile installation...${NC}"
  _detect_remote_seafile
  return 0
}

# ---------------------------------------------------------------------------
# Auto-detect Seafile on a remote server via SSH
# ---------------------------------------------------------------------------
_detect_remote_seafile() {
  local _ssh="ssh -o ConnectTimeout=10 -p ${MIGRATE_SSH_PORT} ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}"

  # Try Docker first
  local _docker_volume=""
  _docker_volume=$($_ssh "docker inspect seafile --format '{{range .Mounts}}{{if eq .Destination \"/shared\"}}{{.Source}}{{end}}{{end}}'" 2>/dev/null || true)

  if [[ -n "$_docker_volume" ]]; then
    echo -e "  ${GREEN}✓${NC} Docker deployment detected"
    echo -e "    ${DIM}Data volume: ${_docker_volume}${NC}"
    export MIGRATE_SOURCE_TYPE="docker"
    export MIGRATE_REMOTE_DATA_DIR="$_docker_volume"
    export MIGRATE_REMOTE_CONF_DIR="${_docker_volume}/seafile/conf"

    # Get database info — try docker exec first, fall back to reading config on disk
    # (docker exec fails when containers are stopped)
    local _db_host=""
    _db_host=$($_ssh "docker exec seafile grep -oP 'host\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null" || true)
    if [[ -z "$_db_host" ]]; then
      # Containers may be stopped — read from the mounted volume on disk
      _db_host=$($_ssh "grep -oP 'host\s*=\s*\K.*' '${_docker_volume}/seafile/conf/seafile.conf' 2>/dev/null | head -1" || true)
      [[ -n "$_db_host" ]] && echo -e "  ${DIM}(read config from filesystem — containers may be stopped)${NC}"
    fi
    if [[ "$_db_host" == "seafile-db" || "$_db_host" == "127.0.0.1" ]]; then
      export MIGRATE_REMOTE_DB="docker"
      echo -e "  ${GREEN}✓${NC} Internal database (Docker container)"
    elif [[ -n "$_db_host" ]]; then
      export MIGRATE_REMOTE_DB="external"
      export MIGRATE_REMOTE_DB_HOST="$_db_host"
      echo -e "  ${GREEN}✓${NC} External database at ${_db_host}"
    else
      # Can't determine — ask the user
      echo -e "  ${YELLOW}!${NC} Could not detect database configuration."
      echo -ne "  ${BOLD}Is the source database a Docker container or external? [docker/external]:${NC} "
      read -r _db_type_answer
      if [[ "${_db_type_answer,,}" == "external" ]]; then
        echo -ne "  ${BOLD}External database host${NC} (IP or hostname): "
        read -r _db_host_answer
        export MIGRATE_REMOTE_DB="external"
        export MIGRATE_REMOTE_DB_HOST="$_db_host_answer"
      else
        export MIGRATE_REMOTE_DB="docker"
      fi
    fi
  else
    # Try manual install paths
    local _conf_path=""
    for _try_path in "/opt/seafile/conf" "/opt/seafile/seafile/conf"; do
      if $_ssh "test -f ${_try_path}/seahub_settings.py" 2>/dev/null; then
        _conf_path="$_try_path"
        break
      fi
    done

    if [[ -n "$_conf_path" ]]; then
      echo -e "  ${GREEN}✓${NC} Manual/package installation detected"
      echo -e "    ${DIM}Config: ${_conf_path}${NC}"
      export MIGRATE_SOURCE_TYPE="manual"
      export MIGRATE_REMOTE_CONF_DIR="$_conf_path"

      # Derive data dir from seafile.conf
      local _data_dir=$($_ssh "grep -oP 'dir\s*=\s*\K.*' ${_conf_path}/seafile.conf 2>/dev/null | head -1" || true)
      _data_dir="${_data_dir:-/opt/seafile/seafile-data}"
      export MIGRATE_REMOTE_DATA_DIR=$(dirname "$_data_dir")
      echo -e "    ${DIM}Data: ${MIGRATE_REMOTE_DATA_DIR}${NC}"
      export MIGRATE_REMOTE_DB="local"
    else
      echo -e "  ${YELLOW}Could not auto-detect Seafile installation.${NC}"
      echo -e "  ${DIM}You may need to use 'Migrate from prepared backup' instead.${NC}"
      return 1
    fi
  fi

  # Get quick stats
  local _version=$($_ssh "ls -d ${MIGRATE_REMOTE_DATA_DIR}/seafile/seafile-server-* 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'" 2>/dev/null || true)
  local _data_size=$($_ssh "du -sh ${MIGRATE_REMOTE_DATA_DIR}/seafile-data 2>/dev/null | cut -f1" 2>/dev/null || true)

  # Extract remote DB credentials for dump
  local _remote_db_user="" _remote_db_pass=""
  if [[ "$MIGRATE_SOURCE_TYPE" == "docker" ]]; then
    # Try docker exec first, fall back to filesystem if containers are stopped
    _remote_db_user=$($_ssh "docker exec seafile grep -oP 'user\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
    _remote_db_pass=$($_ssh "docker exec seafile grep -oP 'password\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
    if [[ -z "$_remote_db_pass" && -n "${MIGRATE_REMOTE_CONF_DIR:-}" ]]; then
      _remote_db_user=$($_ssh "grep -oP 'user\s*=\s*\K.*' '${MIGRATE_REMOTE_CONF_DIR}/seafile.conf' 2>/dev/null | head -1" || true)
      _remote_db_pass=$($_ssh "grep -oP 'password\s*=\s*\K.*' '${MIGRATE_REMOTE_CONF_DIR}/seafile.conf' 2>/dev/null | head -1" || true)
    fi
  else
    _remote_db_user=$($_ssh "grep -oP 'user\s*=\s*\K.*' ${MIGRATE_REMOTE_CONF_DIR}/seafile.conf 2>/dev/null | head -1" || true)
    _remote_db_pass=$($_ssh "grep -oP 'password\s*=\s*\K.*' ${MIGRATE_REMOTE_CONF_DIR}/seafile.conf 2>/dev/null | head -1" || true)
  fi
  _remote_db_user="${_remote_db_user:-seafile}"

  if [[ -n "$_remote_db_pass" ]]; then
    echo -e "  ${GREEN}✓${NC} Database credentials extracted"
    export MIGRATE_REMOTE_DB_USER="$_remote_db_user"
    export MIGRATE_REMOTE_DB_PASS="$_remote_db_pass"
  else
    echo -e "  ${YELLOW}Could not extract DB password from remote config.${NC}"
    echo -ne "  ${BOLD}Remote database password${NC}: "
    read -rs _remote_db_pass
    echo ""
    export MIGRATE_REMOTE_DB_USER="$_remote_db_user"
    export MIGRATE_REMOTE_DB_PASS="$_remote_db_pass"
  fi

  echo ""
  echo -e "  ${BOLD}Source summary:${NC}"
  [[ -n "$_version" ]] && echo -e "    Seafile version:  ${BOLD}${_version}${NC}"
  [[ -n "$_data_size" ]] && echo -e "    Data size:        ${BOLD}${_data_size}${NC}"
  echo -e "    Source type:      ${BOLD}${MIGRATE_SOURCE_TYPE:-unknown}${NC}"
  echo -e "    Data directory:   ${BOLD}${MIGRATE_REMOTE_DATA_DIR:-not detected}${NC}"
  echo -e "    Config directory: ${BOLD}${MIGRATE_REMOTE_CONF_DIR:-not detected}${NC}"
  echo -e "    Database type:    ${BOLD}${MIGRATE_REMOTE_DB:-unknown}${NC}"
  [[ "${MIGRATE_REMOTE_DB:-}" == "external" ]] && \
    echo -e "    Database host:    ${BOLD}${MIGRATE_REMOTE_DB_HOST:-unknown}${NC}"
  echo ""

  # Let user verify and correct paths
  echo -ne "  ${DIM}Do these paths look correct? [Y/n]:${NC} "
  read -r _paths_ok
  if [[ "${_paths_ok,,}" == "n" ]]; then
    echo ""
    echo -ne "  ${BOLD}Remote data directory${NC} [${MIGRATE_REMOTE_DATA_DIR:-}]: "
    read -r _corrected_data
    [[ -n "$_corrected_data" ]] && export MIGRATE_REMOTE_DATA_DIR="$_corrected_data"

    echo -ne "  ${BOLD}Remote config directory${NC} [${MIGRATE_REMOTE_CONF_DIR:-}]: "
    read -r _corrected_conf
    [[ -n "$_corrected_conf" ]] && export MIGRATE_REMOTE_CONF_DIR="$_corrected_conf"

    echo ""
    echo -e "  ${GREEN}✓${NC} Paths updated"
    echo -e "    Data directory:   ${BOLD}${MIGRATE_REMOTE_DATA_DIR}${NC}"
    echo -e "    Config directory: ${BOLD}${MIGRATE_REMOTE_CONF_DIR}${NC}"
    echo ""
  fi
}
