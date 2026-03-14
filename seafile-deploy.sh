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

  # Test connection
  echo ""
  echo -e "  ${DIM}Testing SSH connection...${NC}"
  if ssh -o ConnectTimeout=10 -o BatchMode=yes -p "$MIGRATE_SSH_PORT" \
      "${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}" "echo ok" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Connected to ${MIGRATE_SSH_USER}@${MIGRATE_SSH_HOST}"
  else
    echo -e "  ${RED}✗${NC} Cannot connect. Ensure SSH key auth is configured:"
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

    # Get database info
    local _db_host=$($_ssh "docker exec seafile grep -oP 'host\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null" || true)
    if [[ "$_db_host" == "seafile-db" || "$_db_host" == "127.0.0.1" || -z "$_db_host" ]]; then
      export MIGRATE_REMOTE_DB="docker"
      echo -e "  ${GREEN}✓${NC} Internal database (Docker container)"
    else
      export MIGRATE_REMOTE_DB="external"
      export MIGRATE_REMOTE_DB_HOST="$_db_host"
      echo -e "  ${GREEN}✓${NC} External database at ${_db_host}"
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
    _remote_db_user=$($_ssh "docker exec seafile grep -oP 'user\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
    _remote_db_pass=$($_ssh "docker exec seafile grep -oP 'password\s*=\s*\K.*' /opt/seafile/conf/seafile.conf 2>/dev/null | head -1" || true)
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
  echo ""
}

# ===========================================================================
# Shared Library (embedded from src/shared-lib.sh)
# ===========================================================================
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
DEPLOY_VERSION="v4.5-alpha"

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

# ===========================================================================
# Guided Setup Wizard (embedded from src/guided-setup.sh)
# ===========================================================================
# =============================================================================
# Guided Setup Wizard
# =============================================================================
# Interactive configuration wizard for first-time deployments.
# Called when .env does not exist at /opt/seafile/.env
# =============================================================================

# ---------------------------------------------------------------------------
# Wizard state variables (populated during the flow)
# ---------------------------------------------------------------------------
WIZ_DEPLOYMENT_MODE=""      # native (always)
WIZ_STORAGE_TYPE=""         # nfs | smb | glusterfs | iscsi | local
WIZ_DB_INTERNAL=""          # true | false
WIZ_PROXY_TYPE=""           # nginx | traefik | caddy-external | caddy-bundled | haproxy
WIZ_OFFICE_SUITE=""         # collabora | onlyoffice

# Optional features (true/false)
WIZ_SMTP_ENABLED=""
WIZ_GC_ENABLED=""
WIZ_CLAMAV_ENABLED=""
WIZ_SEAFDAV_ENABLED=""
WIZ_LDAP_ENABLED=""
WIZ_BACKUP_ENABLED=""
WIZ_GUEST_ENABLED=""
WIZ_FORCE_2FA=""
WIZ_ENABLE_SIGNUP=""
WIZ_SHARE_LINK_PW=""
WIZ_LOGIN_LIMIT=""
WIZ_GITOPS_ENABLED=""

# Storage-specific values
WIZ_NFS_SERVER=""
WIZ_NFS_EXPORT=""
WIZ_SMB_SERVER=""
WIZ_SMB_SHARE=""
WIZ_SMB_USERNAME=""
WIZ_SMB_PASSWORD=""
WIZ_SMB_DOMAIN=""
WIZ_GLUSTER_SERVER=""
WIZ_GLUSTER_VOLUME=""
WIZ_ISCSI_PORTAL=""
WIZ_ISCSI_TARGET_IQN=""
WIZ_ISCSI_CHAP_USERNAME=""
WIZ_ISCSI_CHAP_PASSWORD=""
WIZ_STORAGE_MOUNT=""

# Core values
WIZ_SEAFILE_HOSTNAME=""
WIZ_ADMIN_EMAIL=""

# External DB values
WIZ_DB_HOST=""
WIZ_DB_USER=""
WIZ_DB_PASSWORD=""

# Feature-specific values (populated if feature enabled)
WIZ_SMTP_HOST=""
WIZ_SMTP_PORT=""
WIZ_SMTP_USER=""
WIZ_SMTP_PASSWORD=""
WIZ_SMTP_FROM=""
WIZ_SMTP_TLS=""

WIZ_LDAP_URL=""
WIZ_LDAP_BASE_DN=""
WIZ_LDAP_ADMIN_DN=""
WIZ_LDAP_ADMIN_PASSWORD=""
WIZ_LDAP_LOGIN_ATTR=""

WIZ_BACKUP_STORAGE_TYPE=""
WIZ_BACKUP_NFS_SERVER=""
WIZ_BACKUP_NFS_EXPORT=""
WIZ_BACKUP_SMB_SERVER=""
WIZ_BACKUP_SMB_SHARE=""
WIZ_BACKUP_SMB_USERNAME=""
WIZ_BACKUP_SMB_PASSWORD=""
WIZ_BACKUP_SMB_DOMAIN=""
WIZ_BACKUP_MOUNT=""

WIZ_GITOPS_REPO=""
WIZ_GITOPS_BRANCH=""
WIZ_GITOPS_TOKEN=""

# Multi-backend storage
WIZ_MULTI_BACKEND=""        # true | false
WIZ_MAPPING_POLICY=""       # USER_SELECT | ROLE_BASED | REPO_ID_MAPPING
WIZ_BACKEND_COUNT=""        # number of backends defined
WIZ_BACKEND_IDS=""          # comma-separated list of backend IDs
WIZ_BACKEND_NAMES=""        # comma-separated list of backend names
WIZ_BACKEND_DEFAULT=""      # which backend ID is default

# Advanced mode flag
WIZ_ADVANCED_MODE=""        # true | false

# ---------------------------------------------------------------------------
# Utility: show section header
# ---------------------------------------------------------------------------
_wiz_header() {
  local title="$1"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}${title}${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# Utility: show info text
# ---------------------------------------------------------------------------
_wiz_info() {
  echo -e "  ${DIM}$1${NC}"
}

# ---------------------------------------------------------------------------
# Utility: prompt for single selection
# Usage: _wiz_select VAR "prompt" "default" "opt1|desc1" "opt2|desc2" ...
# ---------------------------------------------------------------------------
_wiz_select() {
  local varname="$1"
  local prompt="$2"
  local default="$3"
  shift 3

  local -a options=("$@")
  local count=${#options[@]}
  local -a _OPT_COLORS=("$GREEN" "$CYAN" "$YELLOW" "$PURPLE" "$BOLD")

  echo -e "  ${prompt}"
  echo ""

  local i=1
  local default_num=""
  for opt in "${options[@]}"; do
    local val="${opt%%|*}"
    local desc="${opt#*|}"
    local marker=""
    if [[ "$val" == "$default" ]]; then
      marker=" ${DIM}(default)${NC}"
      default_num="$i"
    fi
    local _c="${_OPT_COLORS[$(( (i-1) % ${#_OPT_COLORS[@]} ))]}"
    echo -e "  ${_c}${BOLD}  ${i}  ${NC}${desc}${marker}"
    ((i++))
  done

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local choice
  while true; do
    if [[ -n "$default_num" ]]; then
      echo -ne "  ${BOLD}Select [1-${count}] (default: ${default_num}):${NC} "
    else
      echo -ne "  ${BOLD}Select [1-${count}]:${NC} "
    fi
    read -r choice
    choice="${choice:-$default_num}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      local selected="${options[$((choice-1))]}"
      local selected_val="${selected%%|*}"
      eval "$varname=\"$selected_val\""
      echo ""
      return 0
    else
      echo -e "  ${DIM}Enter a number from 1 to ${count}.${NC}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Utility: prompt for yes/no
# Usage: _wiz_yesno VAR "prompt" "default"
# ---------------------------------------------------------------------------
_wiz_yesno() {
  local varname="$1"
  local prompt="$2"
  local default="${3:-y}"

  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"

  while true; do
    echo -ne "  ${BOLD}${prompt} ${hint}:${NC} "
    read -r answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) eval "$varname=true"; echo ""; return 0 ;;
      n|no)  eval "$varname=false"; echo ""; return 0 ;;
      *) echo -e "  ${DIM}Enter y or n.${NC}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Utility: prompt for text input
# Usage: _wiz_input VAR "label" "hint" "default" "required"
# ---------------------------------------------------------------------------
_wiz_input() {
  local varname="$1"
  local label="$2"
  local hint="${3:-}"
  local default="${4:-}"
  local required="${5:-false}"

  local prompt_text="  ${BOLD}${label}${NC}"
  [[ -n "$hint" ]] && prompt_text+="  ${DIM}(${hint})${NC}"
  [[ -n "$default" ]] && prompt_text+="  [${default}]"
  prompt_text+=": "

  while true; do
    echo -ne "$prompt_text"
    read -r value
    value="${value:-$default}"

    if [[ -z "$value" && "$required" == "true" ]]; then
      echo -e "  ${RED}Required.${NC}"
    else
      eval "$varname=\"\$value\""
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# Utility: prompt for password (hidden input)
# ---------------------------------------------------------------------------
_wiz_password() {
  local varname="$1"
  local label="$2"
  local required="${3:-false}"

  while true; do
    echo -ne "  ${BOLD}${label}${NC}: "
    read -rs value
    echo ""

    if [[ -z "$value" && "$required" == "true" ]]; then
      echo -e "  ${RED}Required.${NC}"
    else
      eval "$varname=\"\$value\""
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# Utility: multi-select checklist
# Usage: _wiz_checklist "title" "var1|label1|default1" "var2|label2|default2" ...
# ---------------------------------------------------------------------------
_wiz_checklist() {
  local title="$1"
  shift

  local -a items=("$@")
  local -a states=()
  local -a varnames=()
  local -a labels=()

  # Parse items
  for item in "${items[@]}"; do
    local var="${item%%|*}"
    local rest="${item#*|}"
    local label="${rest%%|*}"
    local default="${rest##*|}"
    varnames+=("$var")
    labels+=("$label")
    states+=("$default")
  done

  local count=${#items[@]}

  # Display function
  _display_checklist() {
    echo ""
    echo -e "  ${BOLD}${title}${NC}"
    echo -e "  ${DIM}Enter numbers to toggle (e.g. 1 3 5), Enter to continue${NC}"
    echo ""

    local -a _OPT_COLORS=("$GREEN" "$CYAN" "$YELLOW" "$PURPLE" "$BOLD")
    for ((i=0; i<count; i++)); do
      local mark="[ ]"
      [[ "${states[$i]}" == "true" ]] && mark="[${GREEN}x${NC}]"
      local _c="${_OPT_COLORS[$(( i % ${#_OPT_COLORS[@]} ))]}"
      echo -e "  ${_c}${BOLD}  $((i+1))  ${NC}${mark} ${labels[$i]}"
    done

    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
  }

  _display_checklist

  while true; do
    echo -ne "  ${BOLD}Toggle [1-${count}] or Enter to continue:${NC} "
    read -r choice

    if [[ -z "$choice" ]]; then
      # Show final review
      echo ""
      echo -e "  ${BOLD}Selected features:${NC}"
      local _any=false
      for ((i=0; i<count; i++)); do
        if [[ "${states[$i]}" == "true" ]]; then
          echo -e "    ${GREEN}✓${NC} ${labels[$i]}"
          _any=true
        fi
      done
      if [[ "$_any" == "false" ]]; then
        echo -e "    ${DIM}(none)${NC}"
      fi
      echo ""

      # Apply selections to variables
      for ((i=0; i<count; i++)); do
        eval "${varnames[$i]}=\"${states[$i]}\""
      done
      return 0
    fi

    # Parse multiple space-separated numbers
    local _toggled=false
    for num in $choice; do
      if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
        local idx=$((num-1))
        if [[ "${states[$idx]}" == "true" ]]; then
          states[$idx]="false"
        else
          states[$idx]="true"
        fi
        _toggled=true
      fi
    done

    if [[ "$_toggled" == "true" ]]; then
      # Redraw the full list with updated states
      _display_checklist
    else
      echo -e "  ${DIM}Enter numbers from 1 to ${count} separated by spaces, or press Enter.${NC}"
    fi
  done
}


# ===========================================================================
# WIZARD STEP 1: Deployment Mode
# ===========================================================================
wizard_step_deployment_mode() {
  # Always pre-set by the deployment mode menu — skip silently
  [[ -n "${WIZ_DEPLOYMENT_MODE:-}" ]] && return
  # Fallback: default to native
  WIZ_DEPLOYMENT_MODE="native"
}

# ===========================================================================
# WIZARD STEP 2: Storage Type
# ===========================================================================
wizard_step_storage_type() {
  _wiz_header "Step 2 of 6: Storage Type"

  _wiz_info "Where will Seafile store file data?"
  _wiz_info "Network storage enables full disaster recovery."
  echo ""

  _wiz_select WIZ_STORAGE_TYPE "Select storage type:" "nfs" \
    "nfs|NFS (recommended) - Linux/Unix network shares" \
    "smb|SMB/CIFS - Windows shares, Synology, QNAP" \
    "glusterfs|GlusterFS - Distributed/replicated storage" \
    "iscsi|iSCSI - Block storage, SAN targets" \
    "local|Local disk - Testing only, no disaster recovery"

  if [[ "$WIZ_STORAGE_TYPE" == "local" ]]; then
    echo -e "  ${YELLOW}[WARNING]${NC}  Local storage means NO disaster recovery."
    echo -e "  ${DIM}If this VM is destroyed, all Seafile data is permanently lost.${NC}"
    echo -e "  ${DIM}Only use this for testing or development.${NC}"
    echo ""

    local confirm=""
    _wiz_yesno confirm "Continue with local storage?" "n"
    if [[ "$confirm" != "true" ]]; then
      wizard_step_storage_type  # Recurse to re-select
      return
    fi
  else
    # Check prerequisite
    echo -e "  ${DIM}Before continuing, you need to configure your storage backend.${NC}"
    echo ""

    local prereq_done=""
    case "$WIZ_STORAGE_TYPE" in
      nfs)
        echo -e "  Have you configured your NFS export on your NAS/server?"
        echo -e "  ${DIM}The export must allow this VM's IP with read/write access.${NC}"
        ;;
      smb)
        echo -e "  Have you created the SMB share and user account?"
        echo -e "  ${DIM}You will need: server address, share name, username, password.${NC}"
        ;;
      glusterfs)
        echo -e "  Is your GlusterFS volume mounted and accessible?"
        echo -e "  ${DIM}You will need: server address and volume name.${NC}"
        ;;
      iscsi)
        echo -e "  Have you configured the iSCSI target on your NAS/SAN?"
        echo -e "  ${DIM}You will need: portal address, target IQN, and optionally CHAP credentials.${NC}"
        ;;
    esac

    echo ""
    _wiz_yesno prereq_done "Prerequisites ready?" "y"

    if [[ "$prereq_done" != "true" ]]; then
      echo ""
      echo -e "  ${DIM}Please configure your storage backend first.${NC}"
      echo -e "  ${DIM}See README.md → Plan Your Deployment → Storage type${NC}"
      echo ""
      echo -e "  ${BOLD}Options:${NC}"
      echo -e "  ${GREEN}${BOLD}  1  ${NC}I've done it now, continue"
      echo -e "  ${CYAN}${BOLD}  2  ${NC}Go back and choose different storage"
      echo -e "  ${DIM}  3  Quit and read the documentation${NC}"
      echo ""

      local action=""
      while true; do
        echo -ne "  ${BOLD}Select [1-3]:${NC} "
        read -r action
        case "$action" in
          1) break ;;
          2) wizard_step_storage_type; return ;;
          3) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
          *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;;
        esac
      done
    fi
  fi
}

# ===========================================================================
# WIZARD STEP 2b: Storage Classes (Multi-Backend)
# ===========================================================================
wizard_step_storage_classes() {
  # Only offer for non-local storage
  if [[ "$WIZ_STORAGE_TYPE" == "local" ]]; then
    WIZ_MULTI_BACKEND="false"
    return
  fi

  echo ""
  echo -e "  ${BOLD}Storage classes${NC}"
  echo ""
  echo -e "  ${DIM}Storage classes let you organize libraries into categories.${NC}"
  echo -e "  ${DIM}For example, you could have \"Active Projects\" and \"Archive\"${NC}"
  echo -e "  ${DIM}as separate classes. Users (or a policy) choose which class${NC}"
  echo -e "  ${DIM}a library belongs to when they create it.${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}Single storage ${DIM}(default)${NC}"
  echo -e "     ${DIM}All libraries use one storage class${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  2  ${NC}Multiple storage classes"
  echo -e "     ${DIM}Define named classes (e.g. Active, Archive)${NC}"
  echo ""

  local _choice=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
    read -r _choice
    _choice="${_choice:-1}"
    case "$_choice" in 1|2) break ;; *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;; esac
  done

  if [[ "$_choice" == "1" ]]; then
    WIZ_MULTI_BACKEND="false"
    return
  fi

  WIZ_MULTI_BACKEND="true"
  echo ""

  # --- How many classes? ---
  local _count=""
  while true; do
    echo -ne "  ${BOLD}How many storage classes?${NC} ${DIM}(2-8, default: 2):${NC} "
    read -r _count
    _count="${_count:-2}"
    if [[ "$_count" =~ ^[2-8]$ ]]; then break; fi
    echo -e "  ${DIM}Enter a number between 2 and 8.${NC}"
  done
  WIZ_BACKEND_COUNT="$_count"

  # --- Define each class ---
  local _ids="" _names="" _default_id=""
  for (( i=1; i<=_count; i++ )); do
    echo ""
    echo -e "  ${BOLD}Class ${i}:${NC}"

    local _id=""
    while true; do
      echo -ne "    ${BOLD}ID${NC} ${DIM}(internal, no spaces, e.g. active):${NC} "
      read -r _id
      _id=$(echo "$_id" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
      [[ -n "$_id" ]] && break
      echo -e "    ${RED}Required.${NC}"
    done

    local _name=""
    while true; do
      echo -ne "    ${BOLD}Name${NC} ${DIM}(visible to users, e.g. Active Projects):${NC} "
      read -r _name
      [[ -n "$_name" ]] && break
      echo -e "    ${RED}Required.${NC}"
    done

    if [[ $i -eq 1 ]]; then
      _default_id="$_id"
      echo -e "    ${DIM}(This is the default class)${NC}"
    fi

    [[ -n "$_ids" ]] && _ids="${_ids},"
    _ids="${_ids}${_id}"
    [[ -n "$_names" ]] && _names="${_names},"
    _names="${_names}${_name}"
  done

  WIZ_BACKEND_IDS="$_ids"
  WIZ_BACKEND_NAMES="$_names"
  WIZ_BACKEND_DEFAULT="$_default_id"

  # --- Mapping policy ---
  echo ""
  echo -e "  ${BOLD}Library assignment policy:${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}User chooses ${DIM}(default)${NC}"
  echo -e "     ${DIM}Users select a storage class when creating a library${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  2  ${NC}Role-based"
  echo -e "     ${DIM}Admins assign storage classes to user roles${NC}"
  echo ""
  echo -e "  ${YELLOW}${BOLD}  3  ${NC}Automatic"
  echo -e "     ${DIM}Libraries distributed automatically by ID${NC}"
  echo ""

  local _policy=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2/3] (default: 1):${NC} "
    read -r _policy
    _policy="${_policy:-1}"
    case "$_policy" in 1|2|3) break ;; *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;; esac
  done

  case "$_policy" in
    1) WIZ_MAPPING_POLICY="USER_SELECT" ;;
    2) WIZ_MAPPING_POLICY="ROLE_BASED" ;;
    3) WIZ_MAPPING_POLICY="REPO_ID_MAPPING" ;;
  esac
}

# ===========================================================================
# WIZARD STEP 3: Database
# ===========================================================================
wizard_step_database() {
  _wiz_header "Step 3 of 6: Database"

  _wiz_info "Seafile requires a MySQL/MariaDB database."
  echo ""

  _wiz_select WIZ_DB_INTERNAL "Select database option:" "true" \
    "true|Bundled (recommended) - MariaDB runs as a container" \
    "false|External - Use your own MySQL/MariaDB server"

  if [[ "$WIZ_DB_INTERNAL" == "false" ]]; then
    echo -e "  ${DIM}You need to create the database and user before continuing.${NC}"
    echo -e "  ${DIM}See README.md → Step 3: Set Up the Database${NC}"
    echo ""

    local db_ready=""
    _wiz_yesno db_ready "Have you created the database and user?" "y"

    if [[ "$db_ready" != "true" ]]; then
      echo ""
      echo -e "  ${BOLD}Options:${NC}"
      echo -e "  ${GREEN}${BOLD}  1  ${NC}I've done it now, continue"
      echo -e "  ${CYAN}${BOLD}  2  ${NC}Go back and use bundled database"
      echo -e "  ${DIM}  3  Quit and set up the database${NC}"
      echo ""

      local action=""
      while true; do
        echo -ne "  ${BOLD}Select [1-3]:${NC} "
        read -r action
        case "$action" in
          1) break ;;
          2) WIZ_DB_INTERNAL="true"; return ;;
          3) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
          *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;;
        esac
      done
    fi
  fi
}

# ===========================================================================
# WIZARD STEP 4: Reverse Proxy
# ===========================================================================
wizard_step_proxy() {
  _wiz_header "Step 4 of 6: Reverse Proxy"

  _wiz_info "How will SSL termination be handled?"
  echo ""

  _wiz_select WIZ_PROXY_TYPE "Select reverse proxy:" "nginx" \
    "nginx|Nginx Proxy Manager (recommended) - External proxy host" \
    "caddy-bundled|Bundled Caddy - Self-contained with auto-SSL" \
    "caddy-external|External Caddy - Your own Caddy instance" \
    "traefik|Traefik - Docker labels for routing" \
    "haproxy|HAProxy - External HAProxy server"

  if [[ "$WIZ_PROXY_TYPE" == "caddy-bundled" ]]; then
    echo -e "  ${DIM}Bundled Caddy will handle Let's Encrypt certificates automatically.${NC}"
    echo -e "  ${DIM}Ports 80 and 443 must be reachable from the internet.${NC}"
    echo ""
  fi
}

# ===========================================================================
# WIZARD STEP 5: Office Suite
# ===========================================================================
wizard_step_office() {
  _wiz_header "Step 5 of 6: Office Suite"

  _wiz_info "Choose your document editing solution."
  echo ""

  _wiz_select WIZ_OFFICE_SUITE "Select office suite:" "collabora" \
    "collabora|Collabora Online (recommended) - 4GB RAM minimum" \
    "onlyoffice|OnlyOffice - Better MS Office fidelity, 8GB RAM minimum" \
    "none|No office suite - File sync and sharing only"

  if [[ "$WIZ_OFFICE_SUITE" == "onlyoffice" ]]; then
    echo -e "  ${YELLOW}Note:${NC} OnlyOffice requires at least 8GB RAM."
    echo -e "  ${DIM}It provides better Microsoft Office format support and Track Changes.${NC}"
    echo ""
  fi
}

# ===========================================================================
# WIZARD STEP 6: Optional Features
# ===========================================================================
wizard_step_features() {
  _wiz_header "Step 6 of 6: Optional Features"

  _wiz_info "Enable additional features for your deployment."
  _wiz_info "You can change any of these later by editing .env and running 'seafile update'."
  echo ""

  # Build the checklist dynamically based on earlier choices
  local -a feature_items=()

  # Always available
  feature_items+=("WIZ_SMTP_ENABLED|Email notifications (SMTP)|false")
  feature_items+=("WIZ_GC_ENABLED|Garbage collection (weekly cleanup)|true")
  feature_items+=("WIZ_BACKUP_ENABLED|Automated backup (database + files)|false")

  # Always available
  feature_items+=("WIZ_CLAMAV_ENABLED|Antivirus scanning (ClamAV, +1GB RAM)|false")
  feature_items+=("WIZ_SEAFDAV_ENABLED|WebDAV access|false")
  feature_items+=("WIZ_LDAP_ENABLED|LDAP/Active Directory authentication|false")
  feature_items+=("WIZ_GUEST_ENABLED|Guest accounts (external sharing)|false")
  feature_items+=("WIZ_FORCE_2FA|Force two-factor authentication|false")
  feature_items+=("WIZ_ENABLE_SIGNUP|Allow public registration|false")
  feature_items+=("WIZ_SHARE_LINK_PW|Require passwords on share links|false")
  feature_items+=("WIZ_LOGIN_LIMIT|Lock account after 5 failed logins|true")

  _wiz_checklist "Optional features (space toggles, Enter confirms):" "${feature_items[@]}"
}

# ===========================================================================
# WIZARD STEP 7: Configuration Management (GitOps)
# ===========================================================================
wizard_step_config_management() {
  # If pre-set by deployment menu (option 3), collect git credentials
  if [[ "${WIZ_GITOPS_ENABLED:-}" == "true" ]]; then
    _wiz_header "Step 7 of 7: Git Repository Setup"

    echo -e "  ${DIM}Your .env will be stored in a git repository. When you${NC}"
    echo -e "  ${DIM}push changes, they are automatically applied to this server.${NC}"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} ${DIM}Your .env contains passwords and secrets. Only use a${NC}"
    echo -e "  ${DIM}private repository that you control.${NC}"
    echo ""

    _wiz_input WIZ_GITOPS_REPO "Repository URL (HTTPS)" "e.g. https://gitea.example.com/user/seafile-config.git" "" "true"
    _wiz_password WIZ_GITOPS_TOKEN "Access token (for push/pull)" "true"
    _wiz_input WIZ_GITOPS_BRANCH "Branch" "" "main" "false"
    WIZ_GITOPS_BRANCH="${WIZ_GITOPS_BRANCH:-main}"

    echo ""
    echo -e "  ${DIM}After setup, you will need to add a webhook in your git provider:${NC}"
    echo -e "  ${DIM}  URL:     http://YOUR_SERVER_IP:9002/${NC}"
    echo -e "  ${DIM}  Secret:  (auto-generated, shown after install)${NC}"
    echo -e "  ${DIM}  Events:  Push events only${NC}"
    echo ""
    return
  fi

  # Standard deployment — gitops already set to false by menu
  # Nothing to ask — local config management is the default
  WIZ_GITOPS_ENABLED="false"
}

# ===========================================================================
# WIZARD: Configuration Mode (Standard vs Advanced)
# ===========================================================================
wizard_step_config_mode() {
  _wiz_header "Configuration Mode"

  echo -e "  You've made your deployment choices. How detailed should the"
  echo -e "  remaining configuration be?"
  echo ""

  _wiz_select WIZ_ADVANCED_MODE "Select configuration mode:" "false" \
    "false|Standard (recommended) - Sensible defaults for paths and ports" \
    "true|Advanced - Configure volumes, ports, image tags, and more"
}

# ===========================================================================
# WIZARD: Collect Core Values
# ===========================================================================
wizard_collect_core() {
  _wiz_header "Core Configuration"

  _wiz_input WIZ_SEAFILE_HOSTNAME "Seafile hostname" "e.g. seafile.example.com" "" "true"
  _wiz_input WIZ_ADMIN_EMAIL "Admin email address" "for initial admin account" "" "true"
}

# ===========================================================================
# WIZARD: Collect Storage Values
# ===========================================================================
wizard_collect_storage() {
  _wiz_header "Storage Configuration"

  case "$WIZ_STORAGE_TYPE" in
    nfs)
      _wiz_input WIZ_NFS_SERVER "NFS server IP" "e.g. 192.168.1.100" "" "true"
      _wiz_input WIZ_NFS_EXPORT "NFS export path" "e.g. /volume1/seafile" "" "true"
      _wiz_input WIZ_STORAGE_MOUNT "Mount point" "" "/mnt/seafile_nfs" "false"
      WIZ_STORAGE_MOUNT="${WIZ_STORAGE_MOUNT:-/mnt/seafile_nfs}"
      ;;
    smb)
      _wiz_input WIZ_SMB_SERVER "SMB server" "IP or hostname" "" "true"
      _wiz_input WIZ_SMB_SHARE "Share name" "e.g. seafile" "" "true"
      _wiz_input WIZ_SMB_USERNAME "Username" "" "" "true"
      _wiz_password WIZ_SMB_PASSWORD "Password" "true"
      _wiz_input WIZ_SMB_DOMAIN "Domain" "blank for workgroup" "" "false"
      _wiz_input WIZ_STORAGE_MOUNT "Mount point" "" "/mnt/seafile_smb" "false"
      WIZ_STORAGE_MOUNT="${WIZ_STORAGE_MOUNT:-/mnt/seafile_smb}"
      ;;
    glusterfs)
      _wiz_input WIZ_GLUSTER_SERVER "GlusterFS server IP" "e.g. 192.168.1.100" "" "true"
      _wiz_input WIZ_GLUSTER_VOLUME "Volume name" "e.g. gv0" "" "true"
      _wiz_input WIZ_STORAGE_MOUNT "Mount point" "" "/mnt/seafile_gluster" "false"
      WIZ_STORAGE_MOUNT="${WIZ_STORAGE_MOUNT:-/mnt/seafile_gluster}"
      ;;
    iscsi)
      _wiz_input WIZ_ISCSI_PORTAL "iSCSI portal" "IP:port, e.g. 192.168.1.100:3260" "" "true"
      _wiz_input WIZ_ISCSI_TARGET_IQN "Target IQN" "e.g. iqn.2024-01.com.example:storage" "" "true"
      echo ""
      _wiz_info "CHAP authentication is optional but recommended."
      _wiz_input WIZ_ISCSI_CHAP_USERNAME "CHAP username" "blank to disable" "" "false"
      if [[ -n "$WIZ_ISCSI_CHAP_USERNAME" ]]; then
        _wiz_password WIZ_ISCSI_CHAP_PASSWORD "CHAP password" "true"
      fi
      _wiz_input WIZ_STORAGE_MOUNT "Mount point" "" "/mnt/seafile_iscsi" "false"
      WIZ_STORAGE_MOUNT="${WIZ_STORAGE_MOUNT:-/mnt/seafile_iscsi}"
      ;;
    local)
      _wiz_input WIZ_STORAGE_MOUNT "Data directory" "" "/opt/seafile-data" "false"
      WIZ_STORAGE_MOUNT="${WIZ_STORAGE_MOUNT:-/opt/seafile-data}"
      ;;
  esac
}

# ===========================================================================
# WIZARD: Collect External DB Values
# ===========================================================================
wizard_collect_external_db() {
  if [[ "$WIZ_DB_INTERNAL" == "false" ]]; then
    _wiz_header "External Database Configuration"

    _wiz_input WIZ_DB_HOST "Database host" "IP or hostname" "" "true"
    _wiz_input WIZ_DB_USER "Database user" "" "seafile" "false"
    WIZ_DB_USER="${WIZ_DB_USER:-seafile}"
    _wiz_password WIZ_DB_PASSWORD "Database password" "true"
  fi
}

# ===========================================================================
# WIZARD: Collect Feature-Specific Values
# ===========================================================================
wizard_collect_feature_values() {
  # SMTP
  if [[ "$WIZ_SMTP_ENABLED" == "true" ]]; then
    _wiz_header "Email / SMTP Configuration"

    _wiz_input WIZ_SMTP_HOST "SMTP server" "e.g. smtp.gmail.com" "" "true"
    _wiz_input WIZ_SMTP_PORT "SMTP port" "587 for TLS, 465 for SSL" "587" "false"
    WIZ_SMTP_PORT="${WIZ_SMTP_PORT:-587}"
    _wiz_input WIZ_SMTP_USER "SMTP username" "" "" "true"
    _wiz_password WIZ_SMTP_PASSWORD "SMTP password" "true"
    _wiz_input WIZ_SMTP_FROM "From address" "e.g. noreply@example.com" "" "true"

    _wiz_select WIZ_SMTP_TLS "SMTP encryption:" "starttls" \
      "starttls|STARTTLS (port 587)" \
      "ssl|SSL/TLS (port 465)" \
      "none|None (not recommended)"
  fi

  # LDAP
  if [[ "$WIZ_LDAP_ENABLED" == "true" ]]; then
    _wiz_header "LDAP / Active Directory Configuration"

    _wiz_input WIZ_LDAP_URL "LDAP URL" "e.g. ldap://dc.example.com" "" "true"
    _wiz_input WIZ_LDAP_BASE_DN "Base DN" "e.g. dc=example,dc=com" "" "true"
    _wiz_input WIZ_LDAP_ADMIN_DN "Admin DN" "e.g. cn=admin,dc=example,dc=com" "" "true"
    _wiz_password WIZ_LDAP_ADMIN_PASSWORD "Admin password" "true"
    _wiz_input WIZ_LDAP_LOGIN_ATTR "Login attribute" "sAMAccountName for AD, uid for OpenLDAP" "sAMAccountName" "false"
    WIZ_LDAP_LOGIN_ATTR="${WIZ_LDAP_LOGIN_ATTR:-sAMAccountName}"
  fi

  # Backup
  if [[ "$WIZ_BACKUP_ENABLED" == "true" ]]; then
    _wiz_header "Backup Destination"

    echo -e "  ${DIM}Backups include a full database dump and an rsync of all Seafile${NC}"
    echo -e "  ${DIM}data. The destination must be a different location from your${NC}"
    echo -e "  ${DIM}main Seafile storage.${NC}"
    echo ""

    _wiz_select WIZ_BACKUP_STORAGE_TYPE "Where should backups be stored?" "nfs" \
      "nfs|NFS share" \
      "smb|SMB/CIFS share" \
      "local|Local path (second disk, USB, or existing mount)"

    case "$WIZ_BACKUP_STORAGE_TYPE" in
      nfs)
        _wiz_input WIZ_BACKUP_NFS_SERVER "NFS server" "IP or hostname" "" "true"
        _wiz_input WIZ_BACKUP_NFS_EXPORT "NFS export path" "e.g. /volume1/seafile-backup" "" "true"
        echo -ne "  ${BOLD}Mount point${NC} [/mnt/seafile_backup]: "
        read -r WIZ_BACKUP_MOUNT
        WIZ_BACKUP_MOUNT="${WIZ_BACKUP_MOUNT:-/mnt/seafile_backup}"
        ;;
      smb)
        _wiz_input WIZ_BACKUP_SMB_SERVER "SMB server" "IP or hostname" "" "true"
        _wiz_input WIZ_BACKUP_SMB_SHARE "Share name" "e.g. seafile-backup" "" "true"
        _wiz_input WIZ_BACKUP_SMB_USERNAME "Username" "" "" "true"
        _wiz_password WIZ_BACKUP_SMB_PASSWORD "Password" "true"
        echo -ne "  ${BOLD}Domain${NC} (leave blank for standalone/workgroup): "
        read -r WIZ_BACKUP_SMB_DOMAIN
        echo -ne "  ${BOLD}Mount point${NC} [/mnt/seafile_backup]: "
        read -r WIZ_BACKUP_MOUNT
        WIZ_BACKUP_MOUNT="${WIZ_BACKUP_MOUNT:-/mnt/seafile_backup}"
        ;;
      local)
        echo ""
        echo -e "  ${DIM}Enter the path to your backup destination. This should be a${NC}"
        echo -e "  ${DIM}second disk, USB drive, or other mount — not the same disk${NC}"
        echo -e "  ${DIM}as your OS or Seafile data.${NC}"
        echo ""
        while true; do
          echo -ne "  ${BOLD}Backup path${NC}: "
          read -r WIZ_BACKUP_MOUNT
          if [[ -z "$WIZ_BACKUP_MOUNT" ]]; then
            echo -e "  ${DIM}Required.${NC}"
          elif [[ "$WIZ_BACKUP_MOUNT" == "${WIZ_STORAGE_MOUNT:-/mnt/seafile_nfs}" ]]; then
            echo -e "  ${RED}This is the same as your Seafile storage mount.${NC}"
            echo -e "  ${DIM}Backups must go to a different location.${NC}"
          else
            break
          fi
        done
        ;;
    esac
  fi
}

# ===========================================================================
# WIZARD: Show Summary
# ===========================================================================
wizard_show_summary() {
  _wiz_header "Configuration Summary"

  echo -e "  ${BOLD}Deployment${NC}"
  echo -e "    Storage:        ${WIZ_STORAGE_TYPE}"
  echo -e "    Database:       $([ "$WIZ_DB_INTERNAL" == "true" ] && echo "Bundled" || echo "External")"
  echo -e "    Reverse proxy:  ${WIZ_PROXY_TYPE}"
  echo -e "    Office suite:   ${WIZ_OFFICE_SUITE}"
  if [[ "${WIZ_MULTI_BACKEND:-false}" == "true" ]]; then
    echo -e "    Storage classes: ${WIZ_BACKEND_COUNT} (${WIZ_MAPPING_POLICY})"
  fi
  echo -e "    Config mgmt:    $([ "${WIZ_GITOPS_ENABLED:-false}" == "true" ] && echo "Git-managed (${WIZ_GITOPS_REPO})" || echo "Local")"
  echo ""

  echo -e "  ${BOLD}Core Settings${NC}"
  echo -e "    Hostname:       ${WIZ_SEAFILE_HOSTNAME}"
  echo -e "    Admin email:    ${WIZ_ADMIN_EMAIL}"
  echo ""

  echo -e "  ${BOLD}Optional Features${NC}"
  local features=""
  [[ "$WIZ_SMTP_ENABLED" == "true" ]] && features+="SMTP, "
  [[ "$WIZ_GC_ENABLED" == "true" ]] && features+="GC, "
  [[ "$WIZ_CLAMAV_ENABLED" == "true" ]] && features+="ClamAV, "
  [[ "$WIZ_SEAFDAV_ENABLED" == "true" ]] && features+="WebDAV, "
  [[ "$WIZ_LDAP_ENABLED" == "true" ]] && features+="LDAP, "
  [[ "$WIZ_BACKUP_ENABLED" == "true" ]] && features+="Backup, "
  [[ "$WIZ_GUEST_ENABLED" == "true" ]] && features+="Guests, "
  [[ "$WIZ_FORCE_2FA" == "true" ]] && features+="2FA, "
  [[ "$WIZ_ENABLE_SIGNUP" == "true" ]] && features+="Registration, "
  [[ "$WIZ_SHARE_LINK_PW" == "true" ]] && features+="Share link passwords, "
  [[ "$WIZ_LOGIN_LIMIT" == "true" ]] && features+="Login limits, "
  features="${features%, }"  # Remove trailing comma
  [[ -z "$features" ]] && features="None"
  echo -e "    Enabled:        ${features}"
  echo ""

  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  echo -e "  ${GREEN}${BOLD}  1  ${NC}Continue with these settings"
  echo -e "  ${CYAN}${BOLD}  2  ${NC}Start over"
  echo -e "  ${YELLOW}${BOLD}  3  ${NC}Edit .env manually before continuing"
  echo -e "  ${DIM}  4  Quit${NC}"
  echo ""

  local choice=""
  while true; do
    echo -ne "  ${BOLD}Select [1-4]:${NC} "
    read -r choice
    case "$choice" in
      1) return 0 ;;
      2) return 1 ;;  # Signal to restart wizard
      3) return 2 ;;  # Signal to open editor
      4) echo -e "\n  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
      *) echo -e "  ${DIM}Enter 1, 2, 3, or 4.${NC}" ;;
    esac
  done
}

# ===========================================================================
# WIZARD: Write .env file
# ===========================================================================
wizard_write_env() {
  local env_file="$1"
  local template_content

  # Read template
  template_content=$(cat << 'ENVTEMPLATE'
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
ENVTEMPLATE
)

  # Function to set a value in the env content
  _set_val() {
    local key="$1" val="$2"
    template_content=$(echo "$template_content" | sed "s|^${key}=.*|${key}=${val}|")
  }

  # Core settings
  _set_val "SEAFILE_SERVER_HOSTNAME" "$WIZ_SEAFILE_HOSTNAME"
  _set_val "INIT_SEAFILE_ADMIN_EMAIL" "$WIZ_ADMIN_EMAIL"

  # Storage
  _set_val "STORAGE_TYPE" "$WIZ_STORAGE_TYPE"
  case "$WIZ_STORAGE_TYPE" in
    nfs)
      _set_val "NFS_SERVER" "$WIZ_NFS_SERVER"
      _set_val "NFS_EXPORT" "$WIZ_NFS_EXPORT"
      ;;
    smb)
      _set_val "SMB_SERVER" "$WIZ_SMB_SERVER"
      _set_val "SMB_SHARE" "$WIZ_SMB_SHARE"
      _set_val "SMB_USERNAME" "$WIZ_SMB_USERNAME"
      _set_val "SMB_PASSWORD" "$WIZ_SMB_PASSWORD"
      [[ -n "$WIZ_SMB_DOMAIN" ]] && _set_val "SMB_DOMAIN" "$WIZ_SMB_DOMAIN"
      ;;
    glusterfs)
      _set_val "GLUSTER_SERVER" "$WIZ_GLUSTER_SERVER"
      _set_val "GLUSTER_VOLUME" "$WIZ_GLUSTER_VOLUME"
      ;;
    iscsi)
      _set_val "ISCSI_PORTAL" "$WIZ_ISCSI_PORTAL"
      _set_val "ISCSI_TARGET_IQN" "$WIZ_ISCSI_TARGET_IQN"
      [[ -n "$WIZ_ISCSI_CHAP_USERNAME" ]] && _set_val "ISCSI_CHAP_USERNAME" "$WIZ_ISCSI_CHAP_USERNAME"
      [[ -n "$WIZ_ISCSI_CHAP_PASSWORD" ]] && _set_val "ISCSI_CHAP_PASSWORD" "$WIZ_ISCSI_CHAP_PASSWORD"
      ;;
  esac
  _set_val "SEAFILE_VOLUME" "$WIZ_STORAGE_MOUNT"

  # Database
  _set_val "DB_INTERNAL" "$WIZ_DB_INTERNAL"
  if [[ "$WIZ_DB_INTERNAL" == "false" ]]; then
    _set_val "SEAFILE_MYSQL_DB_HOST" "$WIZ_DB_HOST"
    _set_val "SEAFILE_MYSQL_DB_USER" "$WIZ_DB_USER"
    _set_val "SEAFILE_MYSQL_DB_PASSWORD" "$WIZ_DB_PASSWORD"
  fi

  # Proxy
  _set_val "PROXY_TYPE" "$WIZ_PROXY_TYPE"
  if [[ "$WIZ_PROXY_TYPE" == "caddy-bundled" ]]; then
    _set_val "CADDY_PORT" "80"
    _set_val "CADDY_HTTPS_PORT" "443"
    _set_val "SEAFILE_SERVER_PROTOCOL" "https"
  fi

  # Office
  _set_val "OFFICE_SUITE" "$WIZ_OFFICE_SUITE"

  # Optional features
  _set_val "SMTP_ENABLED" "$WIZ_SMTP_ENABLED"
  _set_val "GC_ENABLED" "$WIZ_GC_ENABLED"
  _set_val "CLAMAV_ENABLED" "$WIZ_CLAMAV_ENABLED"
  _set_val "SEAFDAV_ENABLED" "$WIZ_SEAFDAV_ENABLED"
  _set_val "LDAP_ENABLED" "$WIZ_LDAP_ENABLED"
  _set_val "BACKUP_ENABLED" "${WIZ_BACKUP_ENABLED:-false}"
  _set_val "ENABLE_GUEST" "$WIZ_GUEST_ENABLED"
  _set_val "FORCE_2FA" "$WIZ_FORCE_2FA"
  _set_val "ENABLE_SIGNUP" "${WIZ_ENABLE_SIGNUP:-false}"
  _set_val "SHARE_LINK_FORCE_USE_PASSWORD" "${WIZ_SHARE_LINK_PW:-false}"
  _set_val "LOGIN_ATTEMPT_LIMIT" "$([ "${WIZ_LOGIN_LIMIT:-true}" == "true" ] && echo "5" || echo "0")"
  _set_val "GITOPS_INTEGRATION" "$WIZ_GITOPS_ENABLED"

  # Multi-backend storage classes
  if [[ "${WIZ_MULTI_BACKEND:-false}" == "true" ]]; then
    _set_val "MULTI_BACKEND_ENABLED" "true"
    _set_val "STORAGE_CLASS_MAPPING_POLICY" "$WIZ_MAPPING_POLICY"

    # Write BACKEND_N_* variables from comma-separated lists
    IFS=',' read -ra _ids <<< "$WIZ_BACKEND_IDS"
    IFS=',' read -ra _names <<< "$WIZ_BACKEND_NAMES"
    for (( i=0; i<${#_ids[@]}; i++ )); do
      local n=$(( i + 1 ))
      local _is_default="false"
      [[ "${_ids[$i]}" == "$WIZ_BACKEND_DEFAULT" ]] && _is_default="true"
      _set_val "BACKEND_${n}_ID" "${_ids[$i]}"
      _set_val "BACKEND_${n}_NAME" "${_names[$i]}"
      _set_val "BACKEND_${n}_DEFAULT" "$_is_default"
    done
  fi

  # Feature-specific values
  if [[ "$WIZ_SMTP_ENABLED" == "true" ]]; then
    _set_val "SMTP_HOST" "$WIZ_SMTP_HOST"
    _set_val "SMTP_PORT" "$WIZ_SMTP_PORT"
    _set_val "SMTP_USER" "$WIZ_SMTP_USER"
    _set_val "SMTP_PASSWORD" "$WIZ_SMTP_PASSWORD"
    _set_val "SMTP_FROM" "$WIZ_SMTP_FROM"
    case "$WIZ_SMTP_TLS" in
      starttls) _set_val "SMTP_USE_TLS" "true"; _set_val "SMTP_USE_SSL" "false" ;;
      ssl)      _set_val "SMTP_USE_TLS" "false"; _set_val "SMTP_USE_SSL" "true" ;;
      none)     _set_val "SMTP_USE_TLS" "false"; _set_val "SMTP_USE_SSL" "false" ;;
    esac
  fi

  if [[ "$WIZ_LDAP_ENABLED" == "true" ]]; then
    _set_val "LDAP_URL" "$WIZ_LDAP_URL"
    _set_val "LDAP_BASE_DN" "$WIZ_LDAP_BASE_DN"
    _set_val "LDAP_ADMIN_DN" "$WIZ_LDAP_ADMIN_DN"
    _set_val "LDAP_ADMIN_PASSWORD" "$WIZ_LDAP_ADMIN_PASSWORD"
    _set_val "LDAP_LOGIN_ATTR" "$WIZ_LDAP_LOGIN_ATTR"
  fi

  if [[ "$WIZ_BACKUP_ENABLED" == "true" ]]; then
    _set_val "BACKUP_STORAGE_TYPE" "${WIZ_BACKUP_STORAGE_TYPE:-nfs}"
    _set_val "BACKUP_MOUNT" "${WIZ_BACKUP_MOUNT:-/mnt/seafile_backup}"
    case "${WIZ_BACKUP_STORAGE_TYPE}" in
      nfs)
        _set_val "BACKUP_NFS_SERVER" "$WIZ_BACKUP_NFS_SERVER"
        _set_val "BACKUP_NFS_EXPORT" "$WIZ_BACKUP_NFS_EXPORT"
        ;;
      smb)
        _set_val "BACKUP_SMB_SERVER" "$WIZ_BACKUP_SMB_SERVER"
        _set_val "BACKUP_SMB_SHARE" "$WIZ_BACKUP_SMB_SHARE"
        _set_val "BACKUP_SMB_USERNAME" "$WIZ_BACKUP_SMB_USERNAME"
        _set_val "BACKUP_SMB_PASSWORD" "$WIZ_BACKUP_SMB_PASSWORD"
        _set_val "BACKUP_SMB_DOMAIN" "${WIZ_BACKUP_SMB_DOMAIN:-}"
        ;;
    esac
  fi

  if [[ "$WIZ_GITOPS_ENABLED" == "true" ]]; then
    _set_val "GITOPS_REPO_URL" "$WIZ_GITOPS_REPO"
    _set_val "GITOPS_BRANCH" "$WIZ_GITOPS_BRANCH"
    _set_val "GITOPS_TOKEN" "$WIZ_GITOPS_TOKEN"
  fi

  # Write file
  echo "$template_content" > "$env_file"
  chmod 600 "$env_file"
}

# ===========================================================================
# MAIN WIZARD ENTRY POINT
# ===========================================================================
run_guided_setup() {
  local env_file="${1:-/opt/seafile/.env}"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Guided Setup${NC}"
  echo ""
  echo -e "  ${DIM}This wizard will walk you through configuring your Seafile deployment.${NC}"
  echo -e "  ${DIM}For detailed explanations of each option, see the README:${NC}"
  echo -e "  ${DIM}  → Plan Your Deployment section${NC}"
  echo ""

  # Run wizard steps
  while true; do
    wizard_step_deployment_mode
    wizard_step_storage_type
    wizard_step_storage_classes
    wizard_step_database
    wizard_step_proxy
    wizard_step_office
    wizard_step_features
    wizard_step_config_management
    wizard_step_config_mode

    # Collect values
    wizard_collect_core
    wizard_collect_storage
    wizard_collect_external_db
    wizard_collect_feature_values

    # Show summary
    wizard_show_summary
    local summary_result=$?

    case $summary_result in
      0) break ;;           # Continue
      1) continue ;;        # Start over
      2)                    # Edit manually
        wizard_write_env "$env_file"
        nano "$env_file"
        break
        ;;
    esac
  done

  # Write the .env file
  wizard_write_env "$env_file"

  echo ""
  echo -e "  ${GREEN}✓${NC}  Configuration saved to ${env_file}"
  echo ""

  # Return to main flow (secret generation happens next)
}

# ===========================================================================
# MANUAL SETUP: Open nano with template
# ===========================================================================
run_manual_setup() {
  local env_file="${1:-/opt/seafile/.env}"

  # Create directory if needed
  mkdir -p "$(dirname "$env_file")"

  # Write template with instructions header
  cat > "$env_file" << 'MANUAL_HEADER'
# =============================================================================
# SEAFILE DEPLOYMENT CONFIGURATION
# =============================================================================
#
# Paste your completed .env configuration below, or fill in the values manually.
# See README.md → Environment Variable Reference for detailed documentation.
#
# Required sections to complete:
#   1. Storage configuration (STORAGE_TYPE and related vars)
#   2. Core settings (SEAFILE_SERVER_HOSTNAME, admin email)
#   3. Optional features (SMTP, LDAP, etc.) as needed
#
# After saving, the installer will validate your configuration and continue.
#
# =============================================================================

MANUAL_HEADER

  # Append the template
  cat << 'ENVTEMPLATE' >> "$env_file"
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
ENVTEMPLATE

  chmod 600 "$env_file"

  echo ""
  echo -e "  ${DIM}Opening configuration file in nano...${NC}"
  echo -e "  ${DIM}Fill in the required values, then save (Ctrl+O) and exit (Ctrl+X).${NC}"
  echo ""

  sleep 2
  nano "$env_file"

  echo ""
  echo -e "  ${GREEN}✓${NC}  Configuration saved."
  echo ""
}

# ===========================================================================
# MINIMAL INSTALL: Quick setup with minimal user input
# ===========================================================================
run_minimal_setup() {
  local env_file="${1:-/opt/seafile/.env}"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Quick Setup${NC}"
  echo ""

  # --- Admin email ---
  local _admin_email=""
  while true; do
    echo -ne "  ${BOLD}Admin email${NC} ${DIM}(this is your login)${NC}: "
    read -r _admin_email
    if [[ -n "$_admin_email" && "$_admin_email" == *@* ]]; then
      break
    fi
    echo -e "  ${RED}Please enter a valid email address.${NC}"
  done
  echo ""

  # --- Access mode (local vs internet) ---
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}How will you access this server?${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}Local network only"
  echo -e "     ${DIM}Access from devices on your home or office network${NC}"
  echo -e "     ${DIM}No domain name or special network setup needed${NC}"
  echo ""
  echo -e "  ${CYAN}${BOLD}  2  ${NC}From anywhere over the internet"
  echo -e "     ${DIM}Access from any device, anywhere${NC}"
  echo -e "     ${DIM}Requires a registered domain name and ports 80 + 443${NC}"
  echo -e "     ${DIM}forwarded to this machine${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local _access_mode=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
    read -r _access_mode
    _access_mode="${_access_mode:-1}"
    case "$_access_mode" in 1|2) break ;; *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;; esac
  done
  echo ""

  local _hostname _protocol _proxy_type _caddy_port
  if [[ "$_access_mode" == "2" ]]; then
    # Internet access — ask for domain, Caddy handles SSL automatically
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Internet access setup${NC}"
    echo ""
    echo -e "  ${DIM}Seafile will handle SSL certificates automatically using${NC}"
    echo -e "  ${DIM}Let's Encrypt. For this to work you need:${NC}"
    echo ""
    echo -e "  ${DIM}  ✓ A registered domain name pointed at this server's${NC}"
    echo -e "  ${DIM}    public IP address (an A record in your DNS)${NC}"
    echo -e "  ${DIM}  ✓ Ports 80 and 443 open and forwarded to this machine${NC}"
    echo ""
    echo -e "  ${DIM}If you need help setting up DNS or port forwarding,${NC}"
    echo -e "  ${DIM}see the README → Step 3 — Prepare External Infrastructure${NC}"
    echo ""
    while true; do
      echo -ne "  ${BOLD}Domain name${NC} ${DIM}(e.g. cloud.yourdomain.com)${NC}: "
      read -r _hostname
      if [[ -n "$_hostname" && "$_hostname" == *.* ]]; then
        break
      fi
      echo -e "  ${RED}Please enter a valid domain name.${NC}"
    done
    _protocol="https"
    _proxy_type="caddy-bundled"
    _caddy_port="80"
    _caddy_https_port="443"
    echo ""
  else
    # Local network — auto-detect IP, use port 80 so URLs work without :port
    _hostname=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$_hostname" ]]; then
      _hostname=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    fi
    [[ -z "$_hostname" ]] && _hostname="localhost"
    _protocol="http"
    _proxy_type="nginx"
    _caddy_port="80"
    _caddy_https_port="7443"
  fi

  # --- Office suite ---
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Would you like document editing?${NC}"
  echo ""
  echo -e "  ${DIM}This lets you create and edit Office documents (Word, Excel,${NC}"
  echo -e "  ${DIM}PowerPoint) directly in your browser — like Google Docs, but${NC}"
  echo -e "  ${DIM}hosted on your own server.${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}Yes — add Collabora Online"
  echo -e "  ${CYAN}${BOLD}  2  ${NC}No — just file sync for now"
  echo ""
  echo -e "  ${DIM}You can always add this later with: seafile config${NC}"
  echo ""

  local _office_choice=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2] (default: 2):${NC} "
    read -r _office_choice
    _office_choice="${_office_choice:-2}"
    case "$_office_choice" in 1|2) break ;; *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;; esac
  done

  local _office_suite="none"
  local _office_label="None — file sync only"
  if [[ "$_office_choice" == "1" ]]; then
    _office_suite="collabora"
    _office_label="Collabora Online"
  fi
  echo ""

  # --- Build access URL for display ---
  local _access_url="${_protocol}://${_hostname}"
  # Only add port if non-standard
  if [[ "$_protocol" == "http" && "$_caddy_port" != "80" ]]; then
    _access_url="${_access_url}:${_caddy_port}"
  fi

  # --- Confirmation ---
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Ready to install:${NC}"
  echo ""
  printf "  %-20s %s\n" "Access URL:" "$_access_url"
  printf "  %-20s %s\n" "Admin login:" "$_admin_email"
  printf "  %-20s %s\n" "Admin password:" "changeme"
  printf "  %-20s %s\n" "Office editing:" "$_office_label"
  printf "  %-20s %s\n" "Storage:" "Local disk"
  printf "  %-20s %s\n" "Database:" "Bundled"
  echo ""
  echo -e "  ${DIM}Note: Your files are stored on this machine's disk.${NC}"
  echo -e "  ${DIM}If this VM is lost, your data cannot be recovered.${NC}"
  echo -e "  ${DIM}To add network storage and disaster recovery later,${NC}"
  echo -e "  ${DIM}run: seafile config${NC}"
  if [[ "$_access_mode" == "2" ]]; then
    echo ""
    echo -e "  ${DIM}SSL certificates will be obtained automatically from${NC}"
    echo -e "  ${DIM}Let's Encrypt once ports 80 and 443 are reachable.${NC}"
  fi
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Install${NC}"
  echo -e "  ${DIM}  2  Go back${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local _confirm=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2]:${NC} "
    read -r _confirm
    case "$_confirm" in
      1) break ;;
      2) check_env_and_configure; return $? ;;
      *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;;
    esac
  done

  # --- Generate .env file ---
  mkdir -p "$(dirname "$env_file")"

  local template_content
  template_content=$(cat << 'ENVTEMPLATE'
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
ENVTEMPLATE
)

  _mini_set() {
    local key="$1" val="$2"
    template_content=$(echo "$template_content" | sed "s|^${key}=.*|${key}=${val}|")
  }

  _mini_set "SEAFILE_SERVER_HOSTNAME" "$_hostname"
  _mini_set "SEAFILE_SERVER_PROTOCOL" "$_protocol"
  _mini_set "INIT_SEAFILE_ADMIN_EMAIL" "$_admin_email"
  _mini_set "INIT_SEAFILE_ADMIN_PASSWORD" "changeme"
  _mini_set "STORAGE_TYPE" "local"
  _mini_set "SEAFILE_VOLUME" "/opt/seafile-data"
  _mini_set "DB_INTERNAL" "true"
  _mini_set "PROXY_TYPE" "$_proxy_type"
  _mini_set "CADDY_PORT" "$_caddy_port"
  _mini_set "CADDY_HTTPS_PORT" "$_caddy_https_port"
  _mini_set "OFFICE_SUITE" "$_office_suite"
  _mini_set "PORTAINER_MANAGED" "false"
  _mini_set "SMTP_ENABLED" "false"
  _mini_set "CLAMAV_ENABLED" "false"
  _mini_set "GITOPS_INTEGRATION" "false"
  _mini_set "SEAFDAV_ENABLED" "false"
  _mini_set "LDAP_ENABLED" "false"
  _mini_set "BACKUP_ENABLED" "false"

  # Generate all infrastructure secrets
  _mini_set "JWT_PRIVATE_KEY" "$(openssl rand -base64 32)"
  _mini_set "REDIS_PASSWORD" "$(openssl rand -hex 24)"
  _mini_set "GITOPS_WEBHOOK_SECRET" "$(openssl rand -hex 20)"
  _mini_set "COLLABORA_ADMIN_USER" "admin"
  _mini_set "COLLABORA_ADMIN_PASSWORD" "$(openssl rand -hex 24)"
  local _escaped_host
  _escaped_host=$(echo "$_hostname" | sed 's/\./\\./g')
  if [[ "$_protocol" == "https" ]]; then
    _mini_set "COLLABORA_ALIAS_GROUP" "https://${_escaped_host}:443"
  else
    _mini_set "COLLABORA_ALIAS_GROUP" "http://${_escaped_host}"
  fi
  _mini_set "ONLYOFFICE_JWT_SECRET" "$(openssl rand -hex 16)"
  _mini_set "SEAFILE_MYSQL_DB_HOST" "seafile-db"
  _mini_set "SEAFILE_MYSQL_DB_PASSWORD" "$(openssl rand -hex 24)"
  _mini_set "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$(openssl rand -hex 24)"

  echo "$template_content" > "$env_file"
  chmod 600 "$env_file"

  echo ""
  echo -e "  ${GREEN}✓${NC}  Configuration saved to ${env_file}"
  echo ""

  # Signal to deploy-footer that this is a minimal install
  export MINIMAL_INSTALL=true
  export MINIMAL_ACCESS_URL="$_access_url"
  export MINIMAL_ADMIN_EMAIL="$_admin_email"
  export SEAFILE_SERVER_PROTOCOL="$_protocol"
}

# ===========================================================================
# CHECK FOR .ENV AND OFFER OPTIONS
# ===========================================================================
check_env_and_configure() {
  local env_file="/opt/seafile/.env"
  local env_dir="/opt/seafile"

  # Create directory if needed
  mkdir -p "$env_dir"

  # ── State 1: No .env (or empty) — show deployment mode choice ───────────
  if [[ ! -f "$env_file" ]] || [[ ! -s "$env_file" ]]; then
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}How would you like to deploy Seafile?${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Just give me Seafile${NC}"
    echo -e "     ${DIM}Quick setup · get started in minutes${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}  2  ${NC}${BOLD}Standard deployment${NC}"
    echo -e "     ${DIM}Network storage · disaster recovery · all options${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}  3  ${NC}${BOLD}Git-managed deployment${NC}"
    echo -e "     ${DIM}Same as standard, plus manage .env through a git${NC}"
    echo -e "     ${DIM}repository — config changes without SSH${NC}"
    echo ""
    echo -e "  ${DIM}  4  Quit${NC}"
    echo ""
    echo -e "  ${DIM}All modes include the Portainer Agent for web-based${NC}"
    echo -e "  ${DIM}container monitoring. To use Portainer for stack${NC}"
    echo -e "  ${DIM}management, set PORTAINER_MANAGED=true after setup.${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local choice=""
    while true; do
      echo -ne "  ${BOLD}Select [1/2/3/4]:${NC} "
      read -r choice
      case "$choice" in
        1)
          run_minimal_setup "$env_file"
          return 0
          ;;
        2)
          export WIZ_DEPLOYMENT_MODE="native"
          export WIZ_GITOPS_ENABLED="false"
          run_guided_setup "$env_file"
          return 0
          ;;
        3)
          export WIZ_DEPLOYMENT_MODE="native"
          export WIZ_GITOPS_ENABLED="true"
          run_guided_setup "$env_file"
          return 0
          ;;
        4)
          echo ""
          echo -e "  ${DIM}To configure manually:${NC}"
          echo -e "  ${DIM}  1. Place your .env at ${env_file}${NC}"
          echo -e "  ${DIM}  2. Run this script again${NC}"
          echo ""
          exit 0
          ;;
        *)
          echo -e "  ${DIM}Enter 1, 2, 3, or 4.${NC}"
          ;;
      esac
    done
    return 0
  fi

  # ── .env exists and is non-empty — check completeness ───────────────────
  # Quick check: source it to see which critical fields are missing.
  local _chk_missing=()
  (
    set -a
    source "$env_file" 2>/dev/null
    set +a
    [[ -z "${SEAFILE_SERVER_HOSTNAME:-}" ]] && echo "SEAFILE_SERVER_HOSTNAME"
    [[ -z "${INIT_SEAFILE_ADMIN_EMAIL:-}" ]] && echo "INIT_SEAFILE_ADMIN_EMAIL"
    case "${STORAGE_TYPE:-nfs}" in
      nfs)
        [[ -z "${NFS_SERVER:-}" ]] && echo "NFS_SERVER"
        [[ -z "${NFS_EXPORT:-}" ]] && echo "NFS_EXPORT"
        ;;
      smb)
        [[ -z "${SMB_SERVER:-}" ]] && echo "SMB_SERVER"
        [[ -z "${SMB_SHARE:-}" ]] && echo "SMB_SHARE"
        ;;
      glusterfs)
        [[ -z "${GLUSTER_SERVER:-}" ]] && echo "GLUSTER_SERVER"
        [[ -z "${GLUSTER_VOLUME:-}" ]] && echo "GLUSTER_VOLUME"
        ;;
      iscsi)
        [[ -z "${ISCSI_PORTAL:-}" ]] && echo "ISCSI_PORTAL"
        [[ -z "${ISCSI_TARGET_IQN:-}" ]] && echo "ISCSI_TARGET_IQN"
        ;;
    esac
  ) | while IFS= read -r v; do _chk_missing+=("$v"); done

  # Re-run the check in the current shell to populate the array
  _load_env "$env_file"
  _chk_missing=()
  [[ -z "${SEAFILE_SERVER_HOSTNAME:-}" ]] && _chk_missing+=(SEAFILE_SERVER_HOSTNAME)
  [[ -z "${INIT_SEAFILE_ADMIN_EMAIL:-}" ]] && _chk_missing+=(INIT_SEAFILE_ADMIN_EMAIL)
  case "${STORAGE_TYPE:-nfs}" in
    nfs)
      [[ -z "${NFS_SERVER:-}" ]] && _chk_missing+=(NFS_SERVER)
      [[ -z "${NFS_EXPORT:-}" ]] && _chk_missing+=(NFS_EXPORT)
      ;;
    smb)
      [[ -z "${SMB_SERVER:-}" ]] && _chk_missing+=(SMB_SERVER)
      [[ -z "${SMB_SHARE:-}" ]] && _chk_missing+=(SMB_SHARE)
      ;;
    glusterfs)
      [[ -z "${GLUSTER_SERVER:-}" ]] && _chk_missing+=(GLUSTER_SERVER)
      [[ -z "${GLUSTER_VOLUME:-}" ]] && _chk_missing+=(GLUSTER_VOLUME)
      ;;
    iscsi)
      [[ -z "${ISCSI_PORTAL:-}" ]] && _chk_missing+=(ISCSI_PORTAL)
      [[ -z "${ISCSI_TARGET_IQN:-}" ]] && _chk_missing+=(ISCSI_TARGET_IQN)
      ;;
  esac

  # ── State 2: Incomplete .env — alert and offer options ──────────────────
  if [[ ${#_chk_missing[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Existing configuration found — but it is incomplete${NC}"
    echo ""
    echo -e "  ${DIM}An .env file exists at ${env_file} but the following${NC}"
    echo -e "  ${DIM}required fields are blank or missing:${NC}"
    echo ""
    for v in "${_chk_missing[@]}"; do
      echo -e "    ${RED}✗${NC}  ${BOLD}${v}${NC}"
    done
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Start fresh${NC} ${DIM}(recommended)${NC}"
    echo -e "     ${DIM}Back up the existing file and run the guided wizard${NC}"
    echo ""
    echo -e "  ${BOLD}  2  ${NC}${BOLD}Edit the existing file${NC}"
    echo -e "     ${DIM}Open it in a text editor to fill in the missing values${NC}"
    echo ""
    echo -e "  ${BOLD}  3  ${NC}${BOLD}Continue anyway${NC}"
    echo -e "     ${DIM}Proceed with the current file (preflight will catch errors)${NC}"
    echo ""
    echo -e "  ${DIM}  4  Quit${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local choice=""
    while true; do
      echo -ne "  ${BOLD}Select [1/2/3/4]:${NC} "
      read -r choice
      case "$choice" in
        1)
          cp "$env_file" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
          echo -e "  ${DIM}Existing .env backed up.${NC}"
          run_guided_setup "$env_file"
          return 0
          ;;
        2)
          ${VISUAL:-${EDITOR:-nano}} "$env_file"
          # Re-check after edit — recurse
          check_env_and_configure
          return $?
          ;;
        3)
          echo -e "  ${DIM}Continuing with existing configuration.${NC}"
          return 0
          ;;
        4)
          echo -e "\n  ${DIM}Goodbye.${NC}\n"
          exit 0
          ;;
        *)
          echo -e "  ${DIM}Enter 1, 2, 3, or 4.${NC}"
          ;;
      esac
    done
    return 0
  fi

  # ── State 3: Complete .env — show summary and offer use / start fresh ───
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${GREEN}${BOLD}Existing configuration found${NC}"
  echo ""
  echo -e "  ${DIM}A complete .env file exists at ${env_file}${NC}"
  echo ""
  printf "  ${BOLD}%-22s${NC} %s\n" "Hostname:" "${SEAFILE_SERVER_HOSTNAME:-[not set]}"
  printf "  ${BOLD}%-22s${NC} %s\n" "Storage:" "${STORAGE_TYPE:-nfs}"
  printf "  ${BOLD}%-22s${NC} %s\n" "Admin email:" "${INIT_SEAFILE_ADMIN_EMAIL:-[not set]}"
  printf "  ${BOLD}%-22s${NC} %s\n" "Database:" "$(if [[ "${DB_INTERNAL:-true}" == "true" ]]; then echo "Bundled"; else echo "External → ${SEAFILE_MYSQL_DB_HOST:-?}"; fi)"
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Use this configuration${NC}"
  echo -e "     ${DIM}Continue with the existing .env${NC}"
  echo ""
  echo -e "  ${BOLD}  2  ${NC}${BOLD}Start fresh${NC}"
  echo -e "     ${DIM}Back up the existing file and run the guided wizard${NC}"
  echo ""
  echo -e "  ${BOLD}  3  ${NC}${BOLD}Edit before continuing${NC}"
  echo -e "     ${DIM}Open the file in a text editor${NC}"
  echo ""
  echo -e "  ${BOLD}  4  ${NC}${BOLD}Quit${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local choice=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2/3/4] (default: 1):${NC} "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1)
        echo -e "  ${DIM}Using existing configuration.${NC}"
        return 0
        ;;
      2)
        cp "$env_file" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
        echo -e "  ${DIM}Existing .env backed up.${NC}"
        run_guided_setup "$env_file"
        return 0
        ;;
      3)
        ${VISUAL:-${EDITOR:-nano}} "$env_file"
        check_env_and_configure
        return $?
        ;;
      4)
        echo -e "\n  ${DIM}Goodbye.${NC}\n"
        exit 0
        ;;
      *)
        echo -e "  ${DIM}Enter 1, 2, 3, or 4.${NC}"
        ;;
    esac
  done
}

# ===========================================================================
# Embedded setup.sh (unified install + recover)
# ===========================================================================
extract_setup() {
cat << 'SETUP_EMBED_EOF'
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
DEPLOY_VERSION="v4.5-alpha"

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
        local _bk_opts="auto,x-systemd.automount,_netdev,nfsvers=4,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,nofail"
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
        local _bk_opts="auto,x-systemd.automount,_netdev,nofail,uid=0,gid=0,file_mode=0700,dir_mode=0700"
        local _bk_creds="/etc/seafile-backup-smb-credentials"
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
LOCAL_SECRETS="/opt/seafile/.secrets"
STORAGE_SECRETS="${STORAGE_DIR}/.secrets"

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
  # Sync secrets reference file if it exists
  if [[ -f "$LOCAL_SECRETS" ]]; then
    cp "$LOCAL_SECRETS" "$STORAGE_SECRETS"
    chmod 600 "$STORAGE_SECRETS"
  fi
fi

# Initial history commit on startup
_commit_history

# --- Watch for changes ---
log "Watching $LOCAL_ENV for changes..."
while true; do
  inotifywait -e close_write,moved_to,create "$LOCAL_ENV" 2>/dev/null
  if [ -f "$LOCAL_ENV" ]; then
    # 1. Backup to storage share (DR)
    cp "$LOCAL_ENV" "$STORAGE_ENV"
    chmod 600 "$STORAGE_ENV"
    log "Change detected — synced $LOCAL_ENV → $STORAGE_ENV"
    # Also sync secrets reference file
    if [[ -f "$LOCAL_SECRETS" ]]; then
      cp "$LOCAL_SECRETS" "$STORAGE_SECRETS"
      chmod 600 "$STORAGE_SECRETS"
    fi

    # 2. Commit to config history (versioning)
    _commit_history

    # 3. Notify Portainer (if managed)
    _notify_portainer
  fi
done
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
#!/bin/bash
# =============================================================================
# seafile-storage-sync.sh
# =============================================================================
# Background rsync service for storage migrations.
# Started by the CLI during storage migration, stopped at cutover.
#
# Reads:  /opt/seafile/.storage-migration.conf
# Writes: Updates progress in .storage-migration.conf
# Logs:   /var/log/seafile-storage-migrate.log
#
# This script runs as a systemd service and continuously syncs data from
# the source storage backend to the target. It exits cleanly when it
# detects a cutover request file.
# =============================================================================

set -euo pipefail

# --- Configuration ---
MIGRATION_CONF="/opt/seafile/.storage-migration.conf"
CUTOVER_FLAG="/opt/seafile/.storage-migration-cutover"
LOG_FILE="/var/log/seafile-storage-migrate.log"
SYNC_INTERVAL=60  # seconds between sync cycles

# --- Logging ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# --- Update migration conf with progress ---
update_progress() {
    local key="$1"
    local value="$2"
    
    if grep -q "^${key}=" "$MIGRATION_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$MIGRATION_CONF"
    else
        echo "${key}=${value}" >> "$MIGRATION_CONF"
    fi
}

# --- Calculate directory size ---
get_size_bytes() {
    local path="$1"
    du -sb "$path" 2>/dev/null | cut -f1 || echo "0"
}

# --- Main sync function ---
run_sync() {
    local source_mount="$1"
    local target_mount="$2"
    
    log "Starting sync: $source_mount → $target_mount"
    
    # Ensure paths end with /
    [[ "${source_mount}" != */ ]] && source_mount="${source_mount}/"
    [[ "${target_mount}" != */ ]] && target_mount="${target_mount}/"
    
    # Run rsync with progress
    rsync -aH --delete \
        --info=progress2 \
        --exclude='.storage-migration.conf' \
        --exclude='.storage-migration-cutover' \
        "$source_mount" "$target_mount" 2>&1 | while read -r line; do
            # Log progress lines
            echo "$line" >> "$LOG_FILE"
            
            # Parse progress percentage if available
            if [[ "$line" =~ ([0-9]+)% ]]; then
                update_progress "SYNC_PERCENT" "${BASH_REMATCH[1]}"
            fi
        done
    
    local rsync_exit=${PIPESTATUS[0]}
    
    if [[ $rsync_exit -eq 0 ]]; then
        log "Sync cycle completed successfully"
        return 0
    elif [[ $rsync_exit -eq 24 ]]; then
        # Exit code 24 = "some files vanished" - normal during active use
        log "Sync cycle completed (some files changed during sync, normal)"
        return 0
    else
        log_error "Sync failed with exit code $rsync_exit"
        return 1
    fi
}

# --- Main ---
main() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Seafile Storage Sync Service Starting"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check migration config exists
    if [[ ! -f "$MIGRATION_CONF" ]]; then
        log_error "Migration config not found: $MIGRATION_CONF"
        log_error "This service should only run during an active migration."
        exit 1
    fi
    
    # Source the migration config
    source "$MIGRATION_CONF"
    
    # Validate required variables
    if [[ -z "${SOURCE_MOUNT:-}" ]] || [[ -z "${TARGET_MOUNT:-}" ]]; then
        log_error "SOURCE_MOUNT or TARGET_MOUNT not set in $MIGRATION_CONF"
        exit 1
    fi
    
    log "Source: $SOURCE_MOUNT"
    log "Target: $TARGET_MOUNT"
    
    # Verify mounts exist
    if [[ ! -d "$SOURCE_MOUNT" ]]; then
        log_error "Source mount not found: $SOURCE_MOUNT"
        exit 1
    fi
    
    if [[ ! -d "$TARGET_MOUNT" ]]; then
        log_error "Target mount not found: $TARGET_MOUNT"
        exit 1
    fi
    
    # Calculate initial size
    local total_bytes
    total_bytes=$(get_size_bytes "$SOURCE_MOUNT")
    update_progress "SYNC_BYTES_TOTAL" "$total_bytes"
    log "Total data to sync: $(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || echo "$total_bytes bytes")"
    
    # Record start time
    update_progress "SYNC_STARTED" "$(date -Iseconds)"
    
    # Main sync loop
    local cycle=0
    while true; do
        ((cycle++))
        log "━━━ Sync cycle $cycle ━━━"
        
        # Check for cutover request
        if [[ -f "$CUTOVER_FLAG" ]]; then
            log "Cutover requested — performing final sync"
            
            if run_sync "$SOURCE_MOUNT" "$TARGET_MOUNT"; then
                update_progress "FINAL_SYNC_COMPLETE" "$(date -Iseconds)"
                log "Final sync complete. Exiting."
                rm -f "$CUTOVER_FLAG"
                exit 0
            else
                log_error "Final sync failed!"
                exit 1
            fi
        fi
        
        # Regular sync cycle
        if run_sync "$SOURCE_MOUNT" "$TARGET_MOUNT"; then
            update_progress "SYNC_LAST_RUN" "$(date -Iseconds)"
            
            # Calculate bytes copied
            local copied_bytes
            copied_bytes=$(get_size_bytes "$TARGET_MOUNT")
            update_progress "SYNC_BYTES_COPIED" "$copied_bytes"
            
            # Calculate percentage
            if [[ "$total_bytes" -gt 0 ]]; then
                local percent=$(( (copied_bytes * 100) / total_bytes ))
                [[ "$percent" -gt 100 ]] && percent=100
                update_progress "SYNC_PERCENT" "$percent"
                log "Progress: ${percent}% ($(numfmt --to=iec-i --suffix=B "$copied_bytes" 2>/dev/null || echo "$copied_bytes") / $(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || echo "$total_bytes"))"
            fi
        fi
        
        log "Next sync in ${SYNC_INTERVAL}s (or on cutover request)"
        sleep "$SYNC_INTERVAL"
    done
}

# Run main function
main "$@"
STORAGESYNCSCRIPT
chmod +x "$STORAGE_SYNC_SCRIPT"

cat > "$STORAGE_SYNC_SERVICE" << 'STORAGESYNCSERVICE'
[Unit]
Description=Seafile Storage Migration Sync
Documentation=https://github.com/nicogits92/seafile-deploy
After=network-online.target
Wants=network-online.target

# Only start if migration is active
ConditionPathExists=/opt/seafile/.storage-migration.conf

[Service]
Type=simple
ExecStart=/opt/seafile/storage-sync.sh
Restart=on-failure
RestartSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seafile-storage-sync

# Security hardening
NoNewPrivileges=false
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
STORAGESYNCSERVICE

systemctl daemon-reload
info "Storage-sync service installed (will be enabled during storage migration)."

# --- seafile CLI ---
CLI_DEST="/usr/local/bin/seafile"
info "Installing seafile CLI to $CLI_DEST..."
cat > "$CLI_DEST" << 'CLIFILE'
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
  
  if ! mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -p"$NEW_DB_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
    err "Cannot connect to external database"
    echo -e "  ${DIM}Check host, port, and root credentials.${NC}"
    return 1
  fi
  ok "Connection successful"
  
  # Check databases exist
  echo -e "  ${DIM}Checking databases exist...${NC}"
  for db in ccnet_db seafile_db seahub_db; do
    if ! mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -p"$NEW_DB_ROOT_PASSWORD" -e "USE $db" &>/dev/null; then
      err "Database $db does not exist on external server"
      return 1
    fi
  done
  ok "All three databases found"
  
  _cfg_rule
  echo -e "  ${BOLD}Step 3: Export from Bundled Database${NC}"
  echo ""
  
  local DUMP_FILE="/tmp/seafile_db_migration_$(date +%Y%m%d_%H%M%S).sql"
  
  echo -e "  ${DIM}Stopping Seafile services...${NC}"
  docker compose -f /opt/seafile/docker-compose.yml stop seafile seadoc notification-server thumbnail-server seafile-metadata 2>/dev/null || true
  ok "Services stopped (database container still running)"
  
  echo -e "  ${DIM}Exporting databases...${NC}"
  local ROOT_PASS="${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}"
  
  if ! docker exec seafile-db mysqldump -u root -p"$ROOT_PASS" --single-transaction \
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
  
  if ! mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -p"$NEW_DB_ROOT_PASSWORD" < "$DUMP_FILE" 2>/dev/null; then
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
  orig_count=$(docker exec seafile-db mysql -u root -p"$ROOT_PASS" -N -e "SELECT COUNT(*) FROM seahub_db.auth_user" 2>/dev/null || echo "0")
  new_count=$(mysql -h "$NEW_DB_HOST" -P "$NEW_DB_PORT" -u root -p"$NEW_DB_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM seahub_db.auth_user" 2>/dev/null || echo "0")
  
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
  
  if ! mysqldump -h "$SEAFILE_MYSQL_DB_HOST" -P "${SEAFILE_MYSQL_DB_PORT:-3306}" \
       -u "${SEAFILE_MYSQL_DB_USER:-seafile}" -p"${SEAFILE_MYSQL_DB_PASSWORD}" \
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
  while ! docker exec seafile-db mysqladmin ping -u root -p"$NEW_ROOT_PASS" &>/dev/null; do
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
  if ! docker exec -i seafile-db mysql -u root -p"$NEW_ROOT_PASS" < "$DUMP_FILE" 2>/dev/null; then
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
    echo -e "    REDIS_PASSWORD:             ${REDIS_PASSWORD:-[not set]}"
    echo -e "    SMTP_PASSWORD:              ${SMTP_PASSWORD:-[not set]}"
    [[ -n "${LDAP_BIND_PASSWORD:-}" ]] && echo -e "    LDAP_BIND_PASSWORD:         ${LDAP_BIND_PASSWORD}"
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
      docker exec seafile-db mysql -u root -p"${root_pass}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    else
      mysql -h "$_db_host" -P "$_db_port" -u root -p"${root_pass}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4;" 2>/dev/null
    fi

    local _ok=false
    if [[ "$dump_file" == *.gz ]]; then
      if [[ "$db_method" == "internal" ]]; then
        gunzip -c "$dump_file" | docker exec -i seafile-db \
          mysql -u root -p"${root_pass}" "$db" 2>/dev/null && _ok=true
      else
        gunzip -c "$dump_file" | mysql -h "$_db_host" -P "$_db_port" \
          -u root -p"${root_pass}" "$db" 2>/dev/null && _ok=true
      fi
    else
      if [[ "$db_method" == "internal" ]]; then
        docker exec -i seafile-db mysql -u root -p"${root_pass}" "$db" \
          < "$dump_file" 2>/dev/null && _ok=true
      else
        mysql -h "$_db_host" -P "$_db_port" -u root -p"${root_pass}" "$db" \
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

      for _rdb in \
          "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
          "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
          "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

        echo -e "  ${DIM}  Dumping ${_rdb}...${NC}"
        case "$_remote_db_type" in
          docker)
            $_ssh_cmd "docker exec seafile-db mysqldump \
              -u '${_remote_db_user}' -p'${_remote_db_pass}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_tmp_dumps}/${_rdb}.sql.gz"
            ;;
          *)
            $_ssh_cmd "mysqldump \
              -u '${_remote_db_user}' -p'${_remote_db_pass}' \
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

  local gc_flags=""
  [[ "${GC_REMOVE_DELETED:-true}" == "true" ]] && gc_flags="-r"
  [[ "${GC_DRY_RUN:-false}"       == "true" ]] && gc_flags="${gc_flags} --dry-run"

  info "Running GC..."
  docker exec seafile /scripts/gc.sh ${gc_flags}
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
CLIFILE
chmod +x "$CLI_DEST"
info "seafile CLI installed at $CLI_DEST"

# --- config git server (Portainer-managed mode only) ---
CONFIG_SERVER_SCRIPT="/opt/seafile/seafile-config-server.sh"
CONFIG_SERVER_SERVICE="/etc/systemd/system/seafile-config-server.service"

cat > "$CONFIG_SERVER_SCRIPT" << 'CONFIGSERVEREOF'
#!/bin/bash
# =============================================================================
# seafile-config-server.sh — Local git HTTP server for Portainer integration
# =============================================================================
# Serves the config history git repo over HTTP so Portainer can use it as a
# git-based stack source. Portainer pulls docker-compose.yml and .env from
# this server automatically on each webhook trigger.
#
# Only active when PORTAINER_MANAGED=true.
# Listens on CONFIG_GIT_PORT (default 9418).
#
# Deployed to: /opt/seafile/seafile-config-server.sh
# Managed by:  seafile-config-server.service (systemd)
# =============================================================================

set -euo pipefail

REPO_DIR="/opt/seafile/.config-history"
ENV_FILE="/opt/seafile/.env"

# Read port from .env
PORT=9418
if [ -f "$ENV_FILE" ]; then
  _port=$(grep "^CONFIG_GIT_PORT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
  PORT="${_port:-9418}"
fi

# Ensure repo exists and server-info is current
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "ERROR: Config history repo not found at $REPO_DIR"
  exit 1
fi
cd "$REPO_DIR"
git update-server-info 2>/dev/null || true

echo "Starting config git server on port $PORT (serving $REPO_DIR)"

# Minimal Python HTTP server — serves the repo for dumb HTTP git clone
exec python3 -c "
import http.server, os, sys

os.chdir('$REPO_DIR')
PORT = $PORT

class GitHTTPHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Log to stdout for journalctl
        sys.stdout.write('[CONFIG-GIT] %s\n' % (fmt % args))
        sys.stdout.flush()

    def do_GET(self):
        # Only serve .git/ contents and root files (.env, docker-compose.yml)
        if self.path.startswith('/.git/') or self.path in ('/.env', '/docker-compose.yml', '/'):
            super().do_GET()
        else:
            self.send_error(404)

    def do_POST(self):
        self.send_error(405)

print(f'Config git server listening on port {PORT}', flush=True)
http.server.HTTPServer(('0.0.0.0', PORT), GitHTTPHandler).serve_forever()
"
CONFIGSERVEREOF
chmod +x "$CONFIG_SERVER_SCRIPT"

cat > "$CONFIG_SERVER_SERVICE" << 'CONFIGSERVICEOF'
[Unit]
Description=Seafile Config Git Server — serves config history for Portainer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/seafile/seafile-config-server.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=seafile-config-server

[Install]
WantedBy=multi-user.target
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
  echo -e "  ${BOLD}nicogits92 / seafile-deploy${NC}   ${DIM}Seafile ${_SEAFILE_VERSION} CE  ·  v4.5-alpha  ·  config-fixes${NC}"
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
_signup="${ENABLE_SIGNUP:-false}"
_login_limit="${LOGIN_ATTEMPT_LIMIT:-5}"
_share_pw="${SHARE_LINK_FORCE_USE_PASSWORD:-false}"
_share_expire_default="${SHARE_LINK_EXPIRE_DAYS_DEFAULT:-0}"
_share_expire_max="${SHARE_LINK_EXPIRE_DAYS_MAX:-0}"
_session_age="${SESSION_COOKIE_AGE:-0}"
_history_days="${FILE_HISTORY_KEEP_DAYS:-0}"
_site_name="${SITE_NAME:-Seafile}"
_site_title="${SITE_TITLE:-Seafile}"

cat << USERSEOF
# --- User and library settings ---
FORCE_PASSWORD_CHANGE = False
SITE_NAME = '${_site_name}'
SITE_TITLE = '${_site_title}'
$([ "$_quota" != "0" ] && echo "USER_DEFAULT_QUOTA = ${_quota} * 1024")
$([ "$_max_upload" != "0" ] && echo "MAX_UPLOAD_SIZE = ${_max_upload}")
$([ "$_trash" != "0" ] && echo "TRASH_CLEAN_AFTER_DAYS = ${_trash}")
$([ "${_2fa,,}" == "true" ] && echo "ENABLE_FORCE_2FA = True")
$([ "${_guest,,}" == "true" ] && echo "ENABLE_GUEST = True")
$([ "${_signup,,}" == "true" ] && echo "ENABLE_SIGNUP = True" || echo "ENABLE_SIGNUP = False")
$([ "$_login_limit" != "0" ] && echo "LOGIN_ATTEMPT_LIMIT = ${_login_limit}")
$([ "${_share_pw,,}" == "true" ] && echo "SHARE_LINK_FORCE_USE_PASSWORD = True")
$([ "$_share_expire_default" != "0" ] && echo "SHARE_LINK_EXPIRE_DAYS_DEFAULT = ${_share_expire_default}")
$([ "$_share_expire_max" != "0" ] && echo "SHARE_LINK_EXPIRE_DAYS_MAX = ${_share_expire_max}")
$([ "$_session_age" != "0" ] && echo "SESSION_COOKIE_AGE = ${_session_age}")
$([ "$_history_days" != "0" ] && echo "FILE_HISTORY_KEEP_DAYS = ${_history_days}")

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
cat > "${CONF_DIR}/seafevents.conf" << SEAFEVENTSEOF
[SEAHUB EMAIL]
enabled = true
interval = 30m

[STATISTICS]
enabled = true

[FILE HISTORY]
enabled = true
suffix = md,txt,doc,docx,xls,xlsx,ppt,pptx,sdoc
$([ "${FILE_HISTORY_KEEP_DAYS:-0}" != "0" ] && echo "keep_days = ${FILE_HISTORY_KEEP_DAYS}")

[AUDIT]
enabled = $([ "${AUDIT_ENABLED:-true}" == "true" ] && echo "true" || echo "false")

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
  _BK_DEST="${BACKUP_MOUNT:-/mnt/seafile_backup}"
  if [[ -z "$_BK_DEST" ]]; then
    warn "BACKUP_ENABLED=true but BACKUP_MOUNT is blank — skipping backup setup."
    warn "  Set BACKUP_MOUNT in .env and re-run: seafile fix"
  elif [[ "$_BK_DEST" == "${SEAFILE_VOLUME}" ]]; then
    warn "BACKUP_MOUNT is the same as SEAFILE_VOLUME — this would back up to itself."
    warn "  Set BACKUP_MOUNT to a different path and re-run: seafile fix"
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
    | gzip > "${BACKUP_MOUNT}/db/${db}_${TIMESTAMP}.sql.gz" \
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
    | gzip > "${BACKUP_MOUNT}/db/${db}_${TIMESTAMP}.sql.gz" \
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
BACKUP_MOUNT="${_BK_DEST}"
DB_HOST="${SEAFILE_MYSQL_DB_HOST}"
DB_PORT="${SEAFILE_MYSQL_DB_PORT:-3306}"
DB_USER="${SEAFILE_MYSQL_DB_USER:-seafile}"
DB_PASS="${SEAFILE_MYSQL_DB_PASSWORD}"
TIMESTAMP="\$(date '+%Y%m%d_%H%M%S')"

log "Starting Seafile backup — \${TIMESTAMP}"
mkdir -p "\${BACKUP_MOUNT}/db" "\${BACKUP_MOUNT}/data"

${_DB_DUMP_SNIPPET}

# Remove database dumps older than 14 days
find "\${BACKUP_MOUNT}/db" -name "*.sql.gz" -mtime +14 -delete 2>/dev/null || true

# --- Data rsync ---
# Exclude db-backup/ — it lives on the share but should not be recursively rsynced
log "Rsyncing \${SEAFILE_VOLUME} → \${BACKUP_MOUNT}/data ..."
rsync -aH --delete \
  --exclude='db-backup/' \
  "\${SEAFILE_VOLUME}/" "\${BACKUP_MOUNT}/data/" \
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
    info "Backup cron written: ${BACKUP_SCHEDULE:-0 2 * * *} → ${_BK_DEST}"
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
DEPLOY_VERSION="v4.5-alpha"

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
      if docker exec seafile-db mysqladmin ping -u root \
          -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" --silent 2>/dev/null; then
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
    _db_ready=false
    for _attempt in {1..18}; do
      if mysql -h "${SEAFILE_MYSQL_DB_HOST}" -P "${SEAFILE_MYSQL_DB_PORT:-3306}" \
          -u root -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" -e "SELECT 1" &>/dev/null; then
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
      docker exec seafile-db mysql -u root -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" "$@" 2>/dev/null
    }
  else
    _mysql_cmd() {
      mysql -h "${SEAFILE_MYSQL_DB_HOST}" -P "${SEAFILE_MYSQL_DB_PORT:-3306}" \
        -u root -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" "$@" 2>/dev/null
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
          docker exec seafile-db mysqladmin ping -u root \
            -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" --silent 2>/dev/null && break
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
          if docker exec seafile-db mysqladmin ping -u root \
              -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" --silent 2>/dev/null; then
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
          if docker exec seafile-db mysqladmin ping -u root \
              -p"${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}" --silent 2>/dev/null; then
            _db_ready=true; break
          fi
          sleep 3
        done
        [[ "$_db_ready" != "true" ]] && warn "Local database did not become ready in 90s."
      fi

      # Stage 2: Dump remote databases and import locally
      info "Stage 2: Dumping databases from remote server..."

      # Create temporary dump directory
      _LOCAL_DUMP_DIR=$(mktemp -d /tmp/seafile-migrate-dumps.XXXXXX)

      for _rdb in \
          "${SEAFILE_MYSQL_DB_CCNET_DB_NAME:-ccnet_db}" \
          "${SEAFILE_MYSQL_DB_SEAFILE_DB_NAME:-seafile_db}" \
          "${SEAFILE_MYSQL_DB_SEAHUB_DB_NAME:-seahub_db}"; do

        info "  Dumping ${_rdb}..."

        case "$_REMOTE_DB_TYPE" in
          docker)
            # Source is Docker — mysqldump via docker exec on remote
            $_SSH_CMD "docker exec seafile-db mysqldump \
              -u '${_REMOTE_DB_USER}' -p'${_REMOTE_DB_PASS}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz"
            ;;
          local)
            # Source is manual install — mysqldump directly on remote
            $_SSH_CMD "mysqldump \
              -u '${_REMOTE_DB_USER}' -p'${_REMOTE_DB_PASS}' \
              --single-transaction --quick '${_rdb}'" \
              2>/dev/null | gzip > "${_LOCAL_DUMP_DIR}/${_rdb}.sql.gz"
            ;;
          external)
            # Source uses an external DB — mysqldump with -h flag on remote
            $_SSH_CMD "mysqldump \
              -h '${_REMOTE_DB_HOST}' \
              -u '${_REMOTE_DB_USER}' -p'${_REMOTE_DB_PASS}' \
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
#!/usr/bin/env python3
# =============================================================================
# seafile-gitops-sync.py
# =============================================================================
# Webhook listener for Gitea push events.
#
# On each push:
#   1. Verifies the Gitea HMAC-SHA256 webhook signature
#   2. Runs git pull in the local clone of the gitops repo
#   3. Compares the new .env against the live one
#   4. If .env changed: copies it to /opt/seafile/.env and runs update.sh --yes
#   5. If update.sh succeeded AND PORTAINER_STACK_WEBHOOK is set:
#      POSTs to that URL so Portainer redeploys the stack with the new env vars
#
# Portainer is notified by the VM, not by Gitea directly. This guarantees that
# Portainer never redeploys until after update.sh has finished writing config
# files and restarting containers — eliminating any race between the two.
#
# Installed to: /opt/seafile/seafile-gitops-sync.py
# Managed by:   seafile-gitops-sync.service (reads /opt/seafile/.env for config)
# =============================================================================

import fcntl
import hashlib
import hmac
import http.server
import logging
import os
import subprocess
import sys
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Config — all sourced from environment (injected by systemd EnvironmentFile)
# ---------------------------------------------------------------------------
WEBHOOK_SECRET      = os.environ.get('GITOPS_WEBHOOK_SECRET',      '')
CLONE_PATH          = os.environ.get('GITOPS_CLONE_PATH',          '/opt/seafile-gitops')
PORTAINER_WEBHOOK   = os.environ.get('PORTAINER_STACK_WEBHOOK', '')
ENV_DEST            = '/opt/seafile/.env'
UPDATE_SCRIPT       = '/opt/update.sh'
PORT                = int(os.environ.get('GITOPS_WEBHOOK_PORT', '9002'))
LOCK_FILE           = '/tmp/seafile-gitops.lock'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [GITOPS] %(levelname)s %(message)s',
    stream=sys.stdout
)
log = logging.getLogger()

# ---------------------------------------------------------------------------
# Sync logic
# ---------------------------------------------------------------------------

def file_hash(path):
    """MD5 of a file, or None if it does not exist."""
    try:
        with open(path, 'rb') as f:
            return hashlib.md5(f.read()).hexdigest()
    except FileNotFoundError:
        return None


def notify_portainer():
    """POST to the Portainer stack webhook URL to trigger a redeploy."""
    if not PORTAINER_WEBHOOK:
        return
    try:
        req = urllib.request.Request(PORTAINER_WEBHOOK, method='POST', data=b'')
        with urllib.request.urlopen(req, timeout=15) as resp:
            log.info(f'Portainer notified — HTTP {resp.status}')
    except urllib.error.URLError as e:
        log.warning(f'Portainer webhook call failed: {e}')
        log.warning('Seafile is running correctly. Update Portainer manually if env vars changed.')


def run_sync():
    """Pull repo, apply .env if changed, then notify Portainer. Lock prevents overlaps."""
    lock_fd = open(LOCK_FILE, 'w')
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.warning('Sync already in progress — skipping this webhook.')
        return

    try:
        env_in_repo = os.path.join(CLONE_PATH, '.env')
        old_hash    = file_hash(env_in_repo)

        # Pull latest from the gitops repo
        result = subprocess.run(
            ['git', 'pull'],
            cwd=CLONE_PATH,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            log.error(f'git pull failed:\n{result.stderr.strip()}')
            return
        log.info(f'git pull: {result.stdout.strip()}')

        new_hash = file_hash(env_in_repo)

        if old_hash == new_hash:
            log.info('.env is unchanged — no action needed.')
            # Still notify Portainer if a compose-only change was pushed,
            # so that image tag bumps committed without .env changes still land.
            notify_portainer()
            return

        log.info('.env has changed — applying update.')

        # Copy new .env into place
        subprocess.run(['cp', env_in_repo, ENV_DEST], check=True)
        subprocess.run(['chmod', '600', ENV_DEST],    check=True)
        log.info(f'Copied new .env to {ENV_DEST}')

        # Run update.sh non-interactively
        log.info('Running update.sh --yes ...')
        result = subprocess.run(['bash', UPDATE_SCRIPT, '--yes'], timeout=600)
        if result.returncode != 0:
            log.error(f'update.sh exited with code {result.returncode}')
            log.error('Portainer will NOT be notified — resolve the update.sh error first.')
            return

        log.info('update.sh completed successfully.')

        # Notify Portainer only after update.sh has fully finished
        notify_portainer()

    except Exception as e:
        log.error(f'Unexpected error during sync: {e}')
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class WebhookHandler(http.server.BaseHTTPRequestHandler):

    def do_POST(self):
        if self.path != '/webhook':
            self._respond(404)
            return

        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length)

        # Verify Gitea HMAC-SHA256 signature
        if WEBHOOK_SECRET:
            sig      = self.headers.get('X-Gitea-Signature', '')
            expected = hmac.new(
                WEBHOOK_SECRET.encode(), body, hashlib.sha256
            ).hexdigest()
            if not hmac.compare_digest(sig, expected):
                log.warning('Webhook signature mismatch — request rejected.')
                self._respond(403)
                return

        # Acknowledge immediately so Gitea does not time out
        self._respond(200)

        # Run sync in a child process so we do not block the HTTP server
        subprocess.Popen([sys.executable, __file__, '--run-sync'])

    def _respond(self, code):
        self.send_response(code)
        self.end_headers()

    def log_message(self, fmt, *args):
        log.info(fmt % args)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--run-sync':
        run_sync()
    else:
        log.info(f'GitOps webhook listener starting on :{PORT}')
        log.info(f'Gitops repo clone: {CLONE_PATH}')
        log.info(f'Webhook endpoint:  POST http://THIS_HOST_IP:{PORT}/webhook')
        if PORTAINER_WEBHOOK:
            log.info(f'Portainer webhook: configured — will notify after each successful update')
        else:
            log.info(f'Portainer webhook: not configured — set PORTAINER_STACK_WEBHOOK to enable')
        server = http.server.HTTPServer(('0.0.0.0', PORT), WebhookHandler)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            log.info('Listener stopped.')
GITOPSPYEOF
        chmod +x "$GITOPS_SCRIPT"

        cat > "$GITOPS_SERVICE" << 'GITOPSSERVICEOF'
[Unit]
Description=Seafile GitOps Webhook Listener — syncs .env from Gitea on push
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/seafile/.env
ExecStart=/usr/bin/python3 /opt/seafile/seafile-gitops-sync.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
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
    echo -e "  ${DIM}Want more features? Run:${NC} ${BOLD}seafile config${NC}"
    echo -e "  ${DIM}(network storage, email, LDAP, backups, and more)${NC}"
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
info "docker-compose.yml written to $COMPOSE_FILE."

fi

if [[ "${_SELECTED[9]}" == "true" ]]; then
heading "Installing recovery finalizer"

FINALIZE_SCRIPT="/opt/seafile/seafile-recovery-finalize.sh"
FINALIZE_SERVICE="/etc/systemd/system/seafile-recovery-finalize.service"

info "Writing recovery finalizer script..."
cat > "$FINALIZE_SCRIPT" << 'FINALIZEEOF'
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

SETUP_EMBED_EOF
}

# ---------------------------------------------------------------------------
# Utility: run an embedded script via heredoc extraction
# ---------------------------------------------------------------------------
run_embedded() {
  local label="$1"
  local extract_fn="$2"
  shift 2
  echo -e "\n  ${DIM}(Running embedded ${label}...)${NC}\n"
  local tmp
  tmp=$(mktemp /tmp/seafile-XXXXXX.sh)
  "$extract_fn" > "$tmp"
  chmod +x "$tmp"
  bash "$tmp" "$@"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Secret generation — called from the Fresh Install path only
# ---------------------------------------------------------------------------
#
# Infrastructure secrets: JWT_PRIVATE_KEY, REDIS_PASSWORD, GITOPS_WEBHOOK_SECRET,
#                        COLLABORA_*, ONLYOFFICE_JWT_SECRET
#   Never need to be remembered or typed. Always safe to randomise.
#
# User-facing credentials: INIT_SEAFILE_ADMIN_PASSWORD
#   The user logs in with these. Offered as an option for people who prefer
#   random credentials — they can always be changed via the UI or .env later.
#
# Database credentials: auto-generated when DB_INTERNAL=true and blank.
# When DB_INTERNAL=false they must match values on your external server — never auto-generated.
# External credentials (GITOPS_TOKEN) are NEVER touched.

prompt_secret_generation() {
  local env_file="$1"

  # Source .env to read current values
  local jwt redis_secret gitops_secret admin_pass chap_pass chap_user
  local collabora_user collabora_pass collabora_alias onlyoffice_jwt hostname
  local db_internal db_host db_pass db_root_pass storage_type
  jwt=$(grep            "^JWT_PRIVATE_KEY="                  "$env_file" | cut -d'=' -f2- || true)
  redis_secret=$(grep   "^REDIS_PASSWORD="                   "$env_file" | cut -d'=' -f2- || true)
  gitops_secret=$(grep  "^GITOPS_WEBHOOK_SECRET="            "$env_file" | cut -d'=' -f2- || true)
  admin_pass=$(grep     "^INIT_SEAFILE_ADMIN_PASSWORD="      "$env_file" | cut -d'=' -f2- || true)
  collabora_user=$(grep "^COLLABORA_ADMIN_USER="             "$env_file" | cut -d'=' -f2- || true)
  collabora_pass=$(grep "^COLLABORA_ADMIN_PASSWORD="         "$env_file" | cut -d'=' -f2- || true)
  collabora_alias=$(grep "^COLLABORA_ALIAS_GROUP="           "$env_file" | cut -d'=' -f2- || true)
  onlyoffice_jwt=$(grep "^ONLYOFFICE_JWT_SECRET="            "$env_file" | cut -d'=' -f2- || true)
  hostname=$(grep       "^SEAFILE_SERVER_HOSTNAME="          "$env_file" | cut -d'=' -f2- || true)
  chap_user=$(grep      "^ISCSI_CHAP_USERNAME="              "$env_file" | cut -d'=' -f2- || true)
  chap_pass=$(grep      "^ISCSI_CHAP_PASSWORD="              "$env_file" | cut -d'=' -f2- || true)
  db_internal=$(grep    "^DB_INTERNAL="                      "$env_file" | cut -d'=' -f2- || true)
  db_host=$(grep        "^SEAFILE_MYSQL_DB_HOST="            "$env_file" | cut -d'=' -f2- || true)
  db_pass=$(grep        "^SEAFILE_MYSQL_DB_PASSWORD="        "$env_file" | cut -d'=' -f2- || true)
  db_root_pass=$(grep   "^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=" "$env_file" | cut -d'=' -f2- || true)
  storage_type=$(grep   "^STORAGE_TYPE="                     "$env_file" | cut -d'=' -f2- || true)

  # Classify which are blank
  local infra_blank=() user_blank=()
  [[ -z "$jwt"           ]] && infra_blank+=("JWT_PRIVATE_KEY")
  [[ -z "$redis_secret"  ]] && infra_blank+=("REDIS_PASSWORD")
  [[ -z "$gitops_secret" ]] && infra_blank+=("GITOPS_WEBHOOK_SECRET")
  # Office suite credentials (auto-generated, never need to be remembered)
  [[ -z "$collabora_user"  ]] && infra_blank+=("COLLABORA_ADMIN_USER")
  [[ -z "$collabora_pass"  ]] && infra_blank+=("COLLABORA_ADMIN_PASSWORD")
  [[ -z "$collabora_alias" ]] && infra_blank+=("COLLABORA_ALIAS_GROUP")
  [[ -z "$onlyoffice_jwt"  ]] && infra_blank+=("ONLYOFFICE_JWT_SECRET")
  # DB credentials: auto-generate when DB_INTERNAL=true (bundled MariaDB container).
  # When DB_INTERNAL=false these must match an external server — never auto-generated.
  if [[ "${db_internal:-true}" == "true" ]]; then
    [[ -z "$db_host"      ]] && infra_blank+=("SEAFILE_MYSQL_DB_HOST")
    [[ -z "$db_pass"      ]] && infra_blank+=("SEAFILE_MYSQL_DB_PASSWORD")
    [[ -z "$db_root_pass" ]] && infra_blank+=("INIT_SEAFILE_MYSQL_ROOT_PASSWORD")
  fi
  # ISCSI_CHAP_PASSWORD: generate only when iSCSI is selected AND username is set
  if [[ "${storage_type:-nfs}" == "iscsi" && -n "$chap_user" && -z "$chap_pass" ]]; then
    infra_blank+=("ISCSI_CHAP_PASSWORD")
  fi
  [[ -z "$admin_pass"    ]] && user_blank+=("INIT_SEAFILE_ADMIN_PASSWORD")

  local all_blank=( "${infra_blank[@]}" "${user_blank[@]}" )

  # Nothing to offer — all already set
  if [[ ${#all_blank[@]} -eq 0 ]]; then
    echo -e "  ${DIM}All secrets are already set in .env -- skipping auto-generation.${NC}"
    echo ""
    return 0
  fi

  # Build display lists
  local infra_desc=(
    "JWT_PRIVATE_KEY            internal auth token signing"
    "REDIS_PASSWORD             cache authentication"
    "GITOPS_WEBHOOK_SECRET      webhook HMAC signing (only used if GitOps is enabled)"
    "COLLABORA_ADMIN_USER       Collabora admin console username (auto: admin)"
    "COLLABORA_ADMIN_PASSWORD   Collabora admin console password"
    "COLLABORA_ALIAS_GROUP      Collabora WOPI host (derived from hostname)"
    "ONLYOFFICE_JWT_SECRET      OnlyOffice API authentication"
    "ISCSI_CHAP_PASSWORD        iSCSI CHAP auth (must also be set on your iSCSI target)"
  )
  local user_desc=(
    "INIT_SEAFILE_ADMIN_PASSWORD  Seafile admin login password"
  )

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Secret generation${NC}"
  echo ""
  echo -e "  The following secrets are currently blank in your .env:"
  echo ""

  if [[ ${#infra_blank[@]} -gt 0 ]]; then
    echo -e "  ${DIM}Infrastructure (never need to be remembered):${NC}"
    for v in "${infra_blank[@]}"; do
      local _found=false
      for d in "${infra_desc[@]}"; do
        if [[ "$d" == "${v} "* ]]; then
          echo -e "    ${CYAN}${v}${NC}${DIM}$(echo "$d" | sed "s/^${v}//")\${NC}"
          _found=true
          break
        fi
      done
      [[ "$_found" == "false" ]] && echo -e "    ${CYAN}${v}${NC}"
    done
  fi

  if [[ ${#user_blank[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${DIM}User-facing (you log in with these):${NC}"
    for v in "${user_blank[@]}"; do
      echo -e "    ${CYAN}${v}${NC}"
    done
  fi

  echo ""
  echo -e "  All values can be changed later by editing /opt/seafile/.env."
  echo ""
  echo -e "  ${GREEN}${BOLD}  1  ${NC}Infrastructure secrets only"

  # Show which infra vars are blank, or note all already set
  if [[ ${#infra_blank[@]} -gt 0 ]]; then
    echo -e "     ${DIM}$(IFS=', '; echo "${infra_blank[*]}")${NC}"
  else
    echo -e "     ${DIM}(all already set -- nothing to generate)${NC}"
  fi
  echo ""

  if [[ ${#user_blank[@]} -gt 0 ]]; then
    echo -e "  ${CYAN}${BOLD}  2  ${NC}Infrastructure + user-facing credentials"
    echo -e "     ${DIM}$(IFS=', '; echo "${all_blank[*]}")${NC}"
  else
    echo -e "  ${DIM}  2  Infrastructure + user-facing${NC}"
    echo -e "     ${DIM}(user-facing credentials already set -- same as option 1)${NC}"
  fi
  echo ""
  echo -e "  ${DIM}  3  Skip -- I will fill them in myself${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local choice
  while true; do
    echo -ne "  ${BOLD}Select [1/2/3] (default: 1):${NC} "
    read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1|2|3) break ;;
      *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;;
    esac
  done

  echo ""

  if [[ "$choice" == "3" ]]; then
    echo -e "  ${DIM}Skipping auto-generation.${NC}"
    echo ""
    if [[ ${#infra_blank[@]} -gt 0 ]]; then
      echo -e "  ${YELLOW}Remember:${NC} ${DIM}Fill in infrastructure secrets before running the installer:${NC}"
      for v in "${infra_blank[@]}"; do
        echo -e "    ${DIM}${v}${NC}"
      done
      echo -e "  ${DIM}Edit with: nano ${env_file}${NC}"
      echo ""
    fi
  fi

  # Determine which variables to generate
  local to_generate=()
  if [[ "$choice" == "1" || "$choice" == "2" ]]; then
    to_generate=( "${infra_blank[@]}" )
    if [[ "$choice" == "2" ]]; then
      to_generate+=( "${user_blank[@]}" )
    fi
  fi

  if [[ ${#to_generate[@]} -gt 0 ]]; then

  # Helper: write a value into a blank variable in .env using Python3.
  # Python3 is always present on Debian 13. Using it here because openssl
  # base64 output contains +, /, and = which break sed replacement strings.
  _set_env_secret() {
    local key="$1"
    local value="$2"
    local file="$3"
    python3 - "$key" "$value" "$file" << 'PYEOF'
import sys, re
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
# Replace if the line currently has a blank value
new_content = re.sub(
    r'^(' + re.escape(key) + r'=)\s*$',
    r'\g<1>' + value,
    content,
    flags=re.MULTILINE
)
if new_content == content:
    # Key line was not blank — check if key exists at all
    if not re.search(r'^' + re.escape(key) + r'=', content, re.MULTILINE):
        # Key is missing entirely — append it
        new_content = content.rstrip('\n') + '\n' + key + '=' + value + '\n'
open(path, 'w').write(new_content)
PYEOF
  }

  # Generate and write each selected variable
  local generated=()
  for var in "${to_generate[@]}"; do
    local val=""
    case "$var" in
      JWT_PRIVATE_KEY)
        val=$(openssl rand -base64 32)
        ;;
      SEAFILE_MYSQL_DB_HOST)
        # For DB_INTERNAL=true, the database is the seafile-db container
        val="seafile-db"
        ;;
      REDIS_PASSWORD|COLLABORA_ADMIN_PASSWORD|INIT_SEAFILE_ADMIN_PASSWORD|SEAFILE_MYSQL_DB_PASSWORD|INIT_SEAFILE_MYSQL_ROOT_PASSWORD)
        # 24 random hex chars -- no special characters, safe in all SQL contexts
        val=$(openssl rand -hex 24)
        ;;
      GITOPS_WEBHOOK_SECRET)
        # 20 hex bytes, matching the openssl rand -hex 20 recommended in the README
        val=$(openssl rand -hex 20)
        ;;
      ISCSI_CHAP_PASSWORD|ONLYOFFICE_JWT_SECRET)
        # CHAP passwords and OnlyOffice JWT: 16 hex bytes
        val=$(openssl rand -hex 16)
        ;;
      COLLABORA_ADMIN_USER)
        # Default admin username for Collabora console
        val="admin"
        ;;
      COLLABORA_ALIAS_GROUP)
        # Derive from SEAFILE_SERVER_HOSTNAME: escape dots, wrap in https://...:443
        if [[ -n "$hostname" ]]; then
          local escaped_host
          escaped_host=$(echo "$hostname" | sed 's/\./\\./g')
          val="https://${escaped_host}:443"
        fi
        ;;
    esac
    if [[ -n "$val" ]]; then
      _set_env_secret "$var" "$val" "$env_file"
      _record_secret "$var" "$val"
      generated+=("$var")
    fi
  done

  if [[ ${#generated[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Generated and written to ${env_file}:${NC}"
    for v in "${generated[@]}"; do
      echo -e "    ${GREEN}✓${NC}  ${v}"
    done
    echo ""
    # iSCSI CHAP: generated password must also be configured on the iSCSI target
    if printf '%s
' "${generated[@]}" | grep -q "^ISCSI_CHAP_PASSWORD$"; then
      echo ""
      echo -e "  ${YELLOW}[ACTION REQUIRED]${NC}  ISCSI_CHAP_PASSWORD was generated."
      echo -e "  ${DIM}  You must configure this same password on your iSCSI target${NC}"
      echo -e "  ${DIM}  before running the installer. See README.md → Step 4 → iSCSI.${NC}"
      echo ""
    fi
    echo -e "  ${DIM}Values are not displayed here. View or edit them with:${NC}"
    echo -e "  ${DIM}  nano ${env_file}${NC}"
    echo -e "  ${DIM}  (or run 'seafile config' after setup)${NC}"
  fi

  fi  # end of to_generate block

  # ── Prompt for user-facing secrets not covered by auto-generation ──────
  # When the user chose option 1 (infra only) or option 3 (skip),
  # user-facing secrets like the admin password were not generated.
  # Prompt for them now so the installer can proceed.
  if [[ "$choice" != "2" && ${#user_blank[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}User credentials${NC}"
    echo ""
    echo -e "  ${DIM}These are the passwords you will use to log in.${NC}"
    echo ""

    for _uvar in "${user_blank[@]}"; do
      case "$_uvar" in
        INIT_SEAFILE_ADMIN_PASSWORD)
          local _admin_pw=""
          while [[ -z "$_admin_pw" ]]; do
            echo -ne "  ${BOLD}Admin password${NC} ${DIM}(for ${INIT_SEAFILE_ADMIN_EMAIL:-admin}):${NC} "
            read -rs _admin_pw
            echo ""
            if [[ -z "$_admin_pw" ]]; then
              echo -e "  ${DIM}Password cannot be blank.${NC}"
            fi
          done
          # Write to .env safely (handles special characters)
          python3 -c "
import re, sys
key, val, path = 'INIT_SEAFILE_ADMIN_PASSWORD', sys.argv[1], sys.argv[2]
content = open(path).read()
content = re.sub(r'^' + re.escape(key) + r'=.*$', key + '=' + val, content, flags=re.MULTILINE)
open(path, 'w').write(content)
" "$_admin_pw" "$env_file"
          echo -e "    ${GREEN}✓${NC}  INIT_SEAFILE_ADMIN_PASSWORD set"
          _record_secret "INIT_SEAFILE_ADMIN_PASSWORD" "$_admin_pw"
          ;;
      esac
    done
    echo ""
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# .env preflight validation — runs before the installer on Fresh Install
# ---------------------------------------------------------------------------
# Stage 1: Required fields gate — hard-blocks if any are blank.
# Stage 2: Smart configuration review — all meaningful variables.
# Stage 3: Deployment summary — high-level choices.
# ---------------------------------------------------------------------------

_print_config_review() {
  # Smart configuration review.
  # Unchanged vars → "default" (dimmed)
  # Changed vars   → value (secrets masked)
  # DNC changed    → value + ⚠ NOT RECOMMENDED inline
  _load_env "$ENV_FILE"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Configuration Review${NC}"
  echo -e "  ${DIM}Unchanged vars show ${NC}${DIM}default${NC}${DIM}. Secrets show [set] or [blank].${NC}"
  echo -e "  ${DIM}${YELLOW}⚠ NOT RECOMMENDED${NC}${DIM} = DO NOT CHANGE variable modified from expected.${NC}"
  echo ""

  # ── Required — Server ──────────────────────────────────────────────────────
  echo -e "  ${BOLD}Required — Server${NC}"
  printf "    %-42s %b\n" "SEAFILE_SERVER_HOSTNAME"  "${SEAFILE_SERVER_HOSTNAME:-[blank]}"
  printf "    %-42s %b\n" "SEAFILE_SERVER_PROTOCOL"  "$(_pfv SEAFILE_SERVER_PROTOCOL)"
  echo ""

  # ── Required — Admin Account ───────────────────────────────────────────────
  echo -e "  ${BOLD}Required — Admin Account${NC}"
  printf "    %-42s %b\n" "INIT_SEAFILE_ADMIN_EMAIL"    "${INIT_SEAFILE_ADMIN_EMAIL:-[blank]}"
  printf "    %-42s %b\n" "INIT_SEAFILE_ADMIN_PASSWORD" "$(_mask_secret "${INIT_SEAFILE_ADMIN_PASSWORD:-}")"
  echo ""

  # ── Storage ────────────────────────────────────────────────────────────────
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
      printf "    %-42s %b\n" "ISCSI_PORTAL"        "${ISCSI_PORTAL:-[blank]}"
      printf "    %-42s %b\n" "ISCSI_TARGET_IQN"     "${ISCSI_TARGET_IQN:-[blank]}"
      printf "    %-42s %b\n" "ISCSI_FILESYSTEM"     "$(_pfv ISCSI_FILESYSTEM)"
      printf "    %-42s %b\n" "ISCSI_CHAP_USERNAME"  "${ISCSI_CHAP_USERNAME:-(none)}"
      printf "    %-42s %b\n" "ISCSI_CHAP_PASSWORD"  "$(_mask_secret "${ISCSI_CHAP_PASSWORD:-}")"
      ;;
    local)
      printf "    %-42s %b\n" "(local disk)" "No network credentials needed."
      ;;
  esac
  echo ""

  # ── Database ───────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Database  (DB_INTERNAL=$(_pfv DB_INTERNAL))${NC}"
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    printf "    %-42s %b\n" "DB_INTERNAL_VOLUME"           "$(_pfv DB_INTERNAL_VOLUME)"
    printf "    %-42s %b\n" "DB_INTERNAL_IMAGE"            "$(_pfv DB_INTERNAL_IMAGE)"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PASSWORD"    "$(_mask_secret "${SEAFILE_MYSQL_DB_PASSWORD:-}")"
    printf "    %-42s %b\n" "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$(_mask_secret "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}")"
    echo -e "    ${DIM}DB passwords are auto-generated if blank${NC}"
  else
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_HOST"            "${SEAFILE_MYSQL_DB_HOST:-[blank]}"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PASSWORD"        "$(_mask_secret "${SEAFILE_MYSQL_DB_PASSWORD:-}")"
    printf "    %-42s %b\n" "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$(_mask_secret "${INIT_SEAFILE_MYSQL_ROOT_PASSWORD:-}")"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_USER"            "$(_pfv SEAFILE_MYSQL_DB_USER)"
    printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_PORT"            "$(_pfv SEAFILE_MYSQL_DB_PORT)"
  fi
  # DNC DB names — always show if changed
  printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_CCNET_DB_NAME"   "$(_pfv SEAFILE_MYSQL_DB_CCNET_DB_NAME)"
  printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_SEAFILE_DB_NAME" "$(_pfv SEAFILE_MYSQL_DB_SEAFILE_DB_NAME)"
  printf "    %-42s %b\n" "SEAFILE_MYSQL_DB_SEAHUB_DB_NAME"  "$(_pfv SEAFILE_MYSQL_DB_SEAHUB_DB_NAME)"
  echo ""

  # ── Auth ───────────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Auth${NC}"
  printf "    %-42s %b\n" "JWT_PRIVATE_KEY" "$(_mask_secret "${JWT_PRIVATE_KEY:-}")"
  printf "    %-42s %b\n" "REDIS_PASSWORD"  "$(_mask_secret "${REDIS_PASSWORD:-}")"
  printf "    %-42s %b\n" "REDIS_PORT"      "$(_pfv REDIS_PORT)"
  echo ""

  # ── Office Suite ───────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Office Suite  (OFFICE_SUITE=$(_pfv OFFICE_SUITE))${NC}"
  if [[ "${OFFICE_SUITE:-collabora}" == "onlyoffice" ]]; then
    printf "    %-42s %b\n" "ONLYOFFICE_JWT_SECRET" "$(_mask_secret "${ONLYOFFICE_JWT_SECRET:-}")"
    printf "    %-42s %b\n" "ONLYOFFICE_PORT"       "$(_pfv ONLYOFFICE_PORT)"
    printf "    %-42s %b\n" "ONLYOFFICE_VOLUME"     "$(_pfv ONLYOFFICE_VOLUME)"
  else
    printf "    %-42s %b\n" "COLLABORA_ADMIN_USER"     "${COLLABORA_ADMIN_USER:-[blank]}"
    printf "    %-42s %b\n" "COLLABORA_ADMIN_PASSWORD" "$(_mask_secret "${COLLABORA_ADMIN_PASSWORD:-}")"
    printf "    %-42s %b\n" "COLLABORA_ALIAS_GROUP"    "${COLLABORA_ALIAS_GROUP:-[blank]}"
  fi
  echo ""

  # ── Email / SMTP ───────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Email / SMTP  (SMTP_ENABLED=$(_pfv SMTP_ENABLED))${NC}"
  if [[ "${SMTP_ENABLED:-true}" == "true" ]]; then
    printf "    %-42s %b\n" "SMTP_HOST"     "${SMTP_HOST:-[blank]}"
    printf "    %-42s %b\n" "SMTP_PORT"     "$(_pfv SMTP_PORT)"
    printf "    %-42s %b\n" "SMTP_USE_TLS"  "$(_pfv SMTP_USE_TLS)"
    printf "    %-42s %b\n" "SMTP_USER"     "${SMTP_USER:-[blank]}"
    printf "    %-42s %b\n" "SMTP_PASSWORD" "$(_mask_secret "${SMTP_PASSWORD:-}")"
    printf "    %-42s %b\n" "SMTP_FROM"     "$(_pfv SMTP_FROM)"
  else
    echo -e "    ${DIM}(disabled — users will not receive password reset or share notification emails)${NC}"
  fi
  echo ""

  # ── Optional Features ──────────────────────────────────────────────────────
  echo -e "  ${BOLD}Optional Features${NC}"
  printf "    %-42s %b\n" "CLAMAV_ENABLED"          "$(_pfv CLAMAV_ENABLED)"
  printf "    %-42s %b\n" "SEAFDAV_ENABLED"         "$(_pfv SEAFDAV_ENABLED)"
  printf "    %-42s %b\n" "LDAP_ENABLED"            "$(_pfv LDAP_ENABLED)"
  printf "    %-42s %b\n" "BACKUP_ENABLED"          "$(_pfv BACKUP_ENABLED)"
  printf "    %-42s %b\n" "BACKUP_DEST"             "${BACKUP_DEST:-[blank]}"
  printf "    %-42s %b\n" "GC_ENABLED"              "$(_pfv GC_ENABLED)"
  printf "    %-42s %b\n" "GC_SCHEDULE"             "$(_pfv GC_SCHEDULE)"
  printf "    %-42s %b\n" "DEFAULT_USER_QUOTA_GB"   "$(_pfv DEFAULT_USER_QUOTA_GB)"
  printf "    %-42s %b\n" "MAX_UPLOAD_SIZE_MB"      "$(_pfv MAX_UPLOAD_SIZE_MB)"
  printf "    %-42s %b\n" "TRASH_CLEAN_AFTER_DAYS"  "$(_pfv TRASH_CLEAN_AFTER_DAYS)"
  printf "    %-42s %b\n" "FORCE_2FA"               "$(_pfv FORCE_2FA)"
  printf "    %-42s %b\n" "ENABLE_GUEST"            "$(_pfv ENABLE_GUEST)"
  printf "    %-42s %b\n" "GITOPS_INTEGRATION"      "$(_pfv GITOPS_INTEGRATION)"
  printf "    %-42s %b\n" "TRAEFIK_ENABLED"         "$(_pfv TRAEFIK_ENABLED)"
  echo ""

  # ── Deployment ─────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Deployment${NC}"
  printf "    %-42s %b\n" "PROXY_TYPE"        "$(_pfv PROXY_TYPE)"
  printf "    %-42s %b\n" "CADDY_PORT"        "$(_pfv CADDY_PORT)"
  printf "    %-42s %b\n" "PORTAINER_MANAGED" "$(_pfv PORTAINER_MANAGED)"
  printf "    %-42s %b\n" "TIME_ZONE"         "$(_pfv TIME_ZONE)"
  printf "    %-42s %b\n" "SEAFILE_LOG_TO_STDOUT" "$(_pfv SEAFILE_LOG_TO_STDOUT)"
  echo ""

  # ── Internal Wiring (DO NOT CHANGE) — only show if any differ ─────────────
  _collect_dnc_changed
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

_preflight_print_summary() {
  # Broad-strokes deployment summary — modelled on Plan Your Deployment.
  # Shows the key architectural choices at a glance.
  # DNC changes are flagged at the bottom.
  _load_env "$ENV_FILE"

  # Helper: one-line label for DB
  local _db_label
  if [[ "${DB_INTERNAL:-true}" == "true" ]]; then
    _db_label="Bundled MariaDB container"
  else
    _db_label="External server  →  ${SEAFILE_MYSQL_DB_HOST:-[host not set]}"
  fi

  # Storage label
  local _storage_label
  case "${STORAGE_TYPE:-nfs}" in
    nfs)       _storage_label="NFS  →  ${NFS_SERVER:-?}:${NFS_EXPORT:-?}  →  ${SEAFILE_VOLUME:-/mnt/seafile_nfs}" ;;
    smb)       _storage_label="SMB/CIFS  →  //${SMB_SERVER:-?}/${SMB_SHARE:-?}  →  ${SEAFILE_VOLUME:-/mnt/seafile_nfs}" ;;
    glusterfs) _storage_label="GlusterFS  →  ${GLUSTER_SERVER:-?}:${GLUSTER_VOLUME:-?}" ;;
    iscsi)     _storage_label="iSCSI  →  ${ISCSI_PORTAL:-?}  target: ${ISCSI_TARGET_IQN:-?}" ;;
    local)     _storage_label="Local disk  →  ${SEAFILE_VOLUME:-/mnt/seafile_nfs}  ${YELLOW}(no DR)${NC}" ;;
  esac

  # Office suite label
  local _office_label
  case "${OFFICE_SUITE:-collabora}" in
    collabora)  _office_label="Collabora Online" ;;
    onlyoffice) _office_label="OnlyOffice  (port ${ONLYOFFICE_PORT:-6233})" ;;
    *)          _office_label="${OFFICE_SUITE}" ;;
  esac

  # Proxy label
  local _proxy_label
  case "${PROXY_TYPE:-nginx}" in
    nginx)         _proxy_label="Nginx (Nginx Proxy Manager or raw Nginx)" ;;
    traefik)       _proxy_label="Traefik (Docker labels)" ;;
    caddy-external)_proxy_label="External Caddy instance" ;;
    caddy-bundled) _proxy_label="Bundled Caddy — handles SSL directly (no external proxy)" ;;
    haproxy)       _proxy_label="HAProxy" ;;
    *)             _proxy_label="${PROXY_TYPE}" ;;
  esac

  # Mode label
  local _mode_label
  if [[ "${PORTAINER_MANAGED:-false}" == "true" ]]; then
    _mode_label="Portainer-managed"
  else
    _mode_label="Native (docker compose)"
  fi

  # SMTP label
  local _smtp_label
  if [[ "${SMTP_ENABLED:-true}" == "true" ]]; then
    _smtp_label="Enabled  →  ${SMTP_HOST:-[host not set]}:${SMTP_PORT:-465}"
  else
    _smtp_label="Disabled  ${DIM}(no password reset or notification emails)${NC}"
  fi

  # GC label
  local _gc_label
  if [[ "${GC_ENABLED:-true}" == "true" ]]; then
    _gc_label="Enabled  →  ${GC_SCHEDULE:-0 3 * * 0}"
  else
    _gc_label="Disabled"
  fi

  # Backup label
  local _backup_label
  if [[ "${BACKUP_ENABLED:-false}" == "true" ]]; then
    _backup_label="Enabled  →  ${BACKUP_DEST:-[dest not set]}"
  else
    _backup_label="Disabled  ${DIM}(nightly DB snapshot to share still runs)${NC}"
  fi

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Deployment Summary${NC}"
  echo ""
  printf "  ${BOLD}%-20s${NC} %b\n" "Database"       "$_db_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Storage"        "$_storage_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Reverse proxy"  "$_proxy_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Office suite"   "$_office_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Mode"           "$_mode_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Email / SMTP"   "$_smtp_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Garbage collection" "$_gc_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Offsite backup" "$_backup_label"
  printf "  ${BOLD}%-20s${NC} %b\n" "Antivirus"      "${CLAMAV_ENABLED:-false}"
  printf "  ${BOLD}%-20s${NC} %b\n" "WebDAV"         "${SEAFDAV_ENABLED:-false}"
  printf "  ${BOLD}%-20s${NC} %b\n" "LDAP/AD"        "${LDAP_ENABLED:-false}"
  printf "  ${BOLD}%-20s${NC} %b\n" "GitOps"         "${GITOPS_INTEGRATION:-false}"
  echo ""

  # DNC warnings block
  _collect_dnc_changed
  if [[ ${#_DNC_CHANGED[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}⚠  Internal wiring changes detected${NC}"
    echo -e "  ${DIM}The following DO NOT CHANGE variables differ from their expected values.${NC}"
    echo -e "  ${DIM}Only continue if you are certain these changes are intentional.${NC}"
    echo ""
    for var in "${_DNC_CHANGED[@]}"; do
      local actual="${!var:-}"
      local expected
      expected=$(_get_default "$var")
      local risk
      risk=$(_dnc_risk "$var")
      printf "    ${YELLOW}%-42s${NC}  expected: ${DIM}%s${NC}  got: ${YELLOW}%s${NC}\n" \
        "$var" "$expected" "${actual:-[blank]}"
      echo -e "    ${DIM}→ $risk${NC}"
      echo ""
    done
  fi

  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

preflight_env_check() {
  local env_file="$1"

  # ── Stage 1: Required fields ───────────────────────────────────────────────
  while true; do
    _collect_missing

    if [[ ${#_MISSING[@]} -eq 0 ]]; then
      break
    fi

    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${RED}${BOLD}Required fields are blank${NC}"
    echo ""
    echo -e "  ${DIM}The following fields must be filled in before the install can proceed:${NC}"
    echo ""
    for v in "${_MISSING[@]}"; do
      echo -e "    ${RED}✗${NC}  ${BOLD}${v}${NC}"
    done
    echo ""
    echo -e "  ${DIM}Open your .env and fill in these values, then return here.${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}Open .env in editor  ${DIM}(${VISUAL:-${EDITOR:-nano}})${NC}"
    echo -e "  ${DIM}  2  Exit${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local _choice
    while true; do
      echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
      read -r _choice
      _choice="${_choice:-1}"
      case "$_choice" in 1|2) break ;; *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;; esac
    done

    case "$_choice" in
      1) ${VISUAL:-${EDITOR:-nano}} "$env_file" ;;
      2) echo -e "\n  ${DIM}Run me again once all required fields are filled in.${NC}\n"; exit 0 ;;
    esac
  done

  # ── Stage 2: Smart configuration review ───────────────────────────────────
  while true; do
    _print_config_review

    echo -e "  Unchanged vars show ${DIM}default${NC}. Review anything non-default before continuing."
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Looks good — continue${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}  2  ${NC}Open .env in editor  ${DIM}(${VISUAL:-${EDITOR:-nano}})${NC}"
    echo -e "  ${DIM}     (returns to required-fields check after saving)${NC}"
    echo ""
    echo -e "  ${DIM}  3  Exit${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local _choice
    while true; do
      echo -ne "  ${BOLD}Select [1/2/3] (default: 1):${NC} "
      read -r _choice
      _choice="${_choice:-1}"
      case "$_choice" in 1|2|3) break ;; *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;; esac
    done

    echo ""
    case "$_choice" in
      1) break ;;
      2)
        ${VISUAL:-${EDITOR:-nano}} "$env_file"
        preflight_env_check "$env_file"
        return $?
        ;;
      3) echo -e "  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
    esac
  done

  # ── Stage 3: Deployment summary ───────────────────────────────────────────
  while true; do
    _preflight_print_summary

    # Adjust default action based on whether DNC vars were changed
    _collect_dnc_changed
    local _default_action="y"
    [[ ${#_DNC_CHANGED[@]} -gt 0 ]] && _default_action="q"

    if [[ ${#_DNC_CHANGED[@]} -gt 0 ]]; then
      echo -e "  ${YELLOW}Internal wiring changes are present — review warnings above.${NC}"
    else
      echo -e "  Does this match your intended deployment?"
    fi
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Yes — start the install${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}  2  ${NC}Open .env in editor  ${DIM}(${VISUAL:-${EDITOR:-nano}})${NC}"
    echo -e "  ${DIM}     (returns to required-fields check after saving)${NC}"
    echo ""
    echo -e "  ${DIM}  3  Exit${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local _choice
    while true; do
      if [[ "$_default_action" == "q" ]]; then
        echo -ne "  ${BOLD}Select [1/2/3] (default: 3):${NC} "
      else
        echo -ne "  ${BOLD}Select [1/2/3] (default: 1):${NC} "
      fi
      read -r _choice
      _choice="${_choice:-$([[ "$_default_action" == "q" ]] && echo "3" || echo "1")}"
      case "$_choice" in 1|2|3) break ;; *) echo -e "  ${DIM}Enter 1, 2, or 3.${NC}" ;; esac
    done

    echo ""
    case "$_choice" in
      1)
        echo -e "  ${GREEN}✓  Configuration validated. Starting install...${NC}"
        echo ""
        break
        ;;
      2)
        ${VISUAL:-${EDITOR:-nano}} "$env_file"
        preflight_env_check "$env_file"
        return $?
        ;;
      3) echo -e "  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
    esac
  done
}


# ---------------------------------------------------------------------------
# Pre-flight: must run as root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo -e "\n  ${RED}This script must be run as root.${NC}  Try: sudo bash $0\n"
  exit 1
fi

# ---------------------------------------------------------------------------
# Main menu loop
# ---------------------------------------------------------------------------
while true; do
  show_splash
  read -r -n 1 choice
  echo ""
  case "$choice" in
    1)
      echo -e "\n  ${GREEN}Starting Fresh Install...${NC}\n"
      sleep 0.5
      
      # --- Check for .env and offer configuration options ---
      check_env_and_configure
      
      # --- Normalize .env — ensure all expected keys exist ---
      if [[ -f "$ENV_FILE" ]] && [[ -s "$ENV_FILE" ]]; then
        _normalize_env "$ENV_FILE"
      fi

      if [[ "${MINIMAL_INSTALL:-false}" == "true" ]]; then
        # ── Minimal install — secrets already generated, skip preflight ──
        export SETUP_MODE=install
        run_embedded "setup.sh" extract_setup --yes
        # Show streamlined success message
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${GREEN}${BOLD}  ✓ Seafile is ready!${NC}"
        echo ""
        echo -e "  Open your browser:  ${BOLD}${MINIMAL_ACCESS_URL}${NC}"
        if [[ "${SEAFILE_SERVER_PROTOCOL:-http}" == "https" ]]; then
          echo ""
          echo -e "  ${DIM}SSL certificates are obtained automatically from Let's Encrypt.${NC}"
          echo -e "  ${DIM}If the page doesn't load over HTTPS right away, wait a moment${NC}"
          echo -e "  ${DIM}for the certificate to be issued (requires ports 80 + 443 open).${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}Login:${NC}     ${MINIMAL_ADMIN_EMAIL}"
        echo -e "  ${BOLD}Password:${NC}  changeme"
        echo ""
        echo -e "  ${YELLOW}Change this password after your first login.${NC}"
        echo -e "  ${DIM}Go to Profile (top right) → Password.${NC}"
        echo ""
        echo -e "  ${DIM}Want more features? Run: ${BOLD}seafile config${NC}"
        echo -e "  ${DIM}(network storage, email, LDAP, backups, and more)${NC}"
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
      else
      # --- Standard full install flow ---

      # --- Secret generation prompt ---
      if [[ -f "$ENV_FILE" ]]; then
        echo -e "  ${DIM}Configuration loaded from ${ENV_FILE}.${NC}"
        echo ""
        prompt_secret_generation "$ENV_FILE"
        # Re-source so preflight sees any newly generated secrets
        _load_env "$ENV_FILE"
        # Three-stage .env validation
        preflight_env_check "$ENV_FILE"
      else
        echo -e "  ${YELLOW}No .env found at ${ENV_FILE}.${NC}"
        echo -e "  ${DIM}This should not happen after guided setup. Please report this bug.${NC}"
        echo ""
        continue
      fi
      export SETUP_MODE=install
      run_embedded "setup.sh" extract_setup
      # ── Post-install health check prompt ─────────────────────────────────
      echo ""
      echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo -e "  ${BOLD}  1  ${NC}Run health checks"
      echo -e "     ${DIM}seafile status · seafile ping · seafile version${NC}"
      if [[ "${GITOPS_INTEGRATION:-false}" == "true" ]]; then
        echo -e "     ${DIM}seafile gitops${NC}"
      fi
      echo ""
      echo -e "  ${DIM}  2  Exit to terminal${NC}"
      echo ""
      echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
      read -r _health_choice
      _health_choice="${_health_choice:-1}"
      echo ""
      case "$_health_choice" in
        1)
          seafile status
          seafile ping
          seafile version
          if [[ "${GITOPS_INTEGRATION:-false}" == "true" ]]; then
            seafile gitops
          fi
          ;;
        *)
          echo -e "  ${DIM}Run 'seafile status' any time to check on your deployment.${NC}"
          echo ""
          ;;
      esac

      fi  # end of minimal vs full install branch
      break
      ;;
    2)
      echo -e "\n  ${YELLOW}Starting Recovery Mode...${NC}\n"
      sleep 0.5
      prompt_storage_config
      export SETUP_MODE=recover
      run_embedded "setup.sh" extract_setup
      # ── Post-recovery prompt ──────────────────────────────────────────────
      echo ""
      echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo -e "  ${GREEN}${BOLD}  You made it.${NC}"
      echo ""
      echo -e "  ${DIM}The hard part is done. The recovery finalizer is running${NC}"
      echo -e "  ${DIM}in the background. You can close this terminal.${NC}"
      echo ""
      echo -e "  ${BOLD}  1  ${NC}Get back to work"
      echo -e "     ${DIM}Exit the script${NC}"
      echo ""
      echo -e "  ${PURPLE}${BOLD}  2  ${NC}${BOLD}Take a load off${NC}"
      echo -e "     ${DIM}You've earned it${NC}"
      echo ""
      echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
      echo ""
      echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
      read -r _recovery_choice
      _recovery_choice="${_recovery_choice:-1}"
      echo ""
      case "$_recovery_choice" in
        2)
          play_snake
          ;;
        *)
          echo -e "  ${DIM}Good luck. Run: journalctl -u seafile-recovery-finalize -f${NC}"
          echo ""
          ;;
      esac
      break
      ;;
    3)
      echo -e "\n  ${CYAN}Starting Migration...${NC}\n"
      sleep 0.5
      if prompt_migration_type; then
        # Migration type selected — run guided setup for target config
        # The wizard configures storage, proxy, features etc. for the new deployment
        check_env_and_configure

        # Normalize .env
        if [[ -f "$ENV_FILE" ]] && [[ -s "$ENV_FILE" ]]; then
          _normalize_env "$ENV_FILE"
        fi

        # Secret generation + preflight
        if [[ -f "$ENV_FILE" ]]; then
          echo -e "  ${DIM}Configuration loaded from ${ENV_FILE}.${NC}"
          echo ""
          prompt_secret_generation "$ENV_FILE"
          _load_env "$ENV_FILE"
          preflight_env_check "$ENV_FILE"
        else
          echo -e "  ${YELLOW}No .env found at ${ENV_FILE}.${NC}"
          echo -e "  ${DIM}This should not happen after guided setup. Please report this bug.${NC}"
          echo ""
          continue
        fi

        # Export migration variables for setup.sh
        export SETUP_MODE=migrate
        export MIGRATE_TYPE="${MIGRATE_TYPE}"
        export MIGRATE_DUMP_DIR="${MIGRATE_DUMP_DIR:-}"
        export MIGRATE_DATA_DIR="${MIGRATE_DATA_DIR:-}"
        export MIGRATE_CONF_DIR="${MIGRATE_CONF_DIR:-}"
        export MIGRATE_SSH_HOST="${MIGRATE_SSH_HOST:-}"
        export MIGRATE_SSH_USER="${MIGRATE_SSH_USER:-}"
        export MIGRATE_SSH_PORT="${MIGRATE_SSH_PORT:-22}"
        export MIGRATE_SOURCE_TYPE="${MIGRATE_SOURCE_TYPE:-}"
        export MIGRATE_REMOTE_DATA_DIR="${MIGRATE_REMOTE_DATA_DIR:-}"
        export MIGRATE_REMOTE_CONF_DIR="${MIGRATE_REMOTE_CONF_DIR:-}"
        export MIGRATE_REMOTE_DB="${MIGRATE_REMOTE_DB:-}"
        export MIGRATE_REMOTE_DB_USER="${MIGRATE_REMOTE_DB_USER:-}"
        export MIGRATE_REMOTE_DB_PASS="${MIGRATE_REMOTE_DB_PASS:-}"
        export MIGRATE_REMOTE_DB_HOST="${MIGRATE_REMOTE_DB_HOST:-}"

        run_embedded "setup.sh" extract_setup

        # ── Post-migration health check ──────────────────────────────────
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${GREEN}${BOLD}  ✓ Migration complete!${NC}"
        echo ""
        echo -e "  ${BOLD}  1  ${NC}Run health checks"
        echo -e "     ${DIM}seafile status · seafile ping · seafile version${NC}"
        echo ""
        echo -e "  ${DIM}  2  Exit to terminal${NC}"
        echo ""
        echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
        read -r _mig_health
        _mig_health="${_mig_health:-1}"
        echo ""
        case "$_mig_health" in
          1)
            seafile status
            seafile ping
            seafile version
            ;;
          *)
            echo -e "  ${DIM}Run 'seafile status' any time to check on your deployment.${NC}"
            echo ""
            ;;
        esac
        break
      fi
      # prompt_migration_type returned 1 (user chose Back) — loop to splash
      ;;
    4)
      play_snake
      ;;
    0)
      echo -e "\n  ${DIM}Goodbye.${NC}\n"
      exit 0
      ;;
    *)
      echo -e "  ${DIM}Invalid selection — try 0, 1, 2, 3, or 4.${NC}"
      sleep 1
      ;;
  esac
done
