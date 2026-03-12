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
#   3  Have Fun        — Snake
#   q  Quit
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
  echo -e "  ${PURPLE}${BOLD}  3  ${NC}${BOLD}Have Fun${NC}"
  echo -e "     ${DIM}Take a break · while you still can${NC}"
  echo ""
  echo -e "  ${DIM}  q  Quit${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -ne "  ${BOLD}Select [1/2/3/q]:${NC} "
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

