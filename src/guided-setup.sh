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
      printf -v "$varname" '%s' "$selected_val"
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
      y|yes) printf -v "$varname" '%s' "true"; echo ""; return 0 ;;
      n|no)  printf -v "$varname" '%s' "false"; echo ""; return 0 ;;
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
      printf -v "$varname" '%s' "$value"
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
      printf -v "$varname" '%s' "$value"
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
        printf -v "${varnames[$i]}" '%s' "${states[$i]}"
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
{{ENV_TEMPLATE}}
ENVTEMPLATE
)

  # Function to set a value in the env content
  _set_val() {
    local key="$1" val="$2"
    template_content=$(python3 -c "
import sys, re
key, val = sys.argv[1], sys.argv[2]
content = sys.stdin.read()
print(re.sub(r'^' + re.escape(key) + r'=.*$', lambda m: key + '=' + val, content, flags=re.MULTILINE), end='')
" "$key" "$val" <<< "$template_content")
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
{{ENV_TEMPLATE}}
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

  # --- Admin password ---
  echo ""
  echo -ne "  ${BOLD}Admin password${NC} ${DIM}(leave blank for 'changeme')${NC}: "
  read -rs _admin_pass
  echo ""
  _admin_pass="${_admin_pass:-changeme}"
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
  if [[ "$_admin_pass" == "changeme" ]]; then
    printf "  %-20s %s\n" "Admin password:" "changeme (change after first login)"
  else
    printf "  %-20s %s\n" "Admin password:" "[set]"
  fi
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
{{ENV_TEMPLATE}}
ENVTEMPLATE
)

  _mini_set() {
    local key="$1" val="$2"
    template_content=$(python3 -c "
import sys, re
key, val = sys.argv[1], sys.argv[2]
content = sys.stdin.read()
print(re.sub(r'^' + re.escape(key) + r'=.*$', lambda m: key + '=' + val, content, flags=re.MULTILINE), end='')
" "$key" "$val" <<< "$template_content")
  }

  _mini_set "SEAFILE_SERVER_HOSTNAME" "$_hostname"
  _mini_set "SEAFILE_SERVER_PROTOCOL" "$_protocol"
  _mini_set "INIT_SEAFILE_ADMIN_EMAIL" "$_admin_email"
  _mini_set "INIT_SEAFILE_ADMIN_PASSWORD" "$_admin_pass"
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
# DEPLOYMENT MODE SUBMENU — shown when user chooses "Configure now"
# ===========================================================================
_show_deployment_modes() {
  local env_file="$1"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Choose your deployment style:${NC}"
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
  echo -e "  ${DIM}  0  Back${NC}"
  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  local choice=""
  while true; do
    echo -ne "  ${BOLD}Select [1/2/3/0]:${NC} "
    read -r choice
    case "$choice" in
      1) run_minimal_setup "$env_file"; return 0 ;;
      2) export WIZ_DEPLOYMENT_MODE="native"; export WIZ_GITOPS_ENABLED="false"
         run_guided_setup "$env_file"; return 0 ;;
      3) export WIZ_DEPLOYMENT_MODE="native"; export WIZ_GITOPS_ENABLED="true"
         run_guided_setup "$env_file"; return 0 ;;
      0) check_env_and_configure; return $? ;;
      *) echo -e "  ${DIM}Enter 1, 2, 3, or 0.${NC}" ;;
    esac
  done
}

# ===========================================================================
# CONFIGURE LATER — bare minimum install, configure in browser or CLI after
# ===========================================================================
run_configure_later() {
  local env_file="${1:-/opt/seafile/.env}"

  echo ""
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${BOLD}Quick Install${NC}"
  echo ""
  echo -e "  ${DIM}We just need your login credentials — everything else${NC}"
  echo -e "  ${DIM}can be configured later in the browser or CLI.${NC}"
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

  # --- Admin password ---
  echo ""
  echo -ne "  ${BOLD}Admin password${NC} ${DIM}(leave blank for 'changeme')${NC}: "
  read -rs _admin_pass
  echo ""
  _admin_pass="${_admin_pass:-changeme}"
  echo ""

  # --- Auto-detect hostname ---
  local _hostname
  _hostname=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$_hostname" ]] && _hostname=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  [[ -z "$_hostname" ]] && _hostname="localhost"

  local _access_url="http://${_hostname}"

  # --- Generate .env ---
  mkdir -p "$(dirname "$env_file")"

  local template_content
  template_content=$(cat << 'ENVTEMPLATE'
{{ENV_TEMPLATE}}
ENVTEMPLATE
)

  _mini_set() {
    local key="$1" val="$2"
    template_content=$(python3 -c "
import sys, re
key, val = sys.argv[1], sys.argv[2]
content = sys.stdin.read()
print(re.sub(r'^' + re.escape(key) + r'=.*$', lambda m: key + '=' + val, content, flags=re.MULTILINE), end='')
" "$key" "$val" <<< "$template_content")
  }

  _mini_set "SEAFILE_SERVER_HOSTNAME" "$_hostname"
  _mini_set "SEAFILE_SERVER_PROTOCOL" "http"
  _mini_set "INIT_SEAFILE_ADMIN_EMAIL" "$_admin_email"
  _mini_set "INIT_SEAFILE_ADMIN_PASSWORD" "$_admin_pass"
  _mini_set "STORAGE_TYPE" "local"
  _mini_set "SEAFILE_VOLUME" "/opt/seafile-data"
  _mini_set "DB_INTERNAL" "true"
  _mini_set "PROXY_TYPE" "nginx"
  _mini_set "CADDY_PORT" "80"
  _mini_set "CADDY_HTTPS_PORT" "7443"
  _mini_set "OFFICE_SUITE" "none"
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
  _mini_set "COLLABORA_ALIAS_GROUP" "http://${_escaped_host}"
  _mini_set "ONLYOFFICE_JWT_SECRET" "$(openssl rand -hex 16)"
  _mini_set "SEAFILE_MYSQL_DB_HOST" "seafile-db"
  _mini_set "SEAFILE_MYSQL_DB_PASSWORD" "$(openssl rand -hex 24)"
  _mini_set "INIT_SEAFILE_MYSQL_ROOT_PASSWORD" "$(openssl rand -hex 24)"
  _mini_set "CONFIG_UI_PASSWORD" "$(openssl rand -hex 16)"

  echo "$template_content" > "$env_file"
  chmod 600 "$env_file"

  echo -e "  ${GREEN}✓${NC}  Configuration saved."
  echo ""

  # Signal to deploy-footer
  export MINIMAL_INSTALL=true
  export CONFIGURE_LATER=true
  export MINIMAL_ACCESS_URL="$_access_url"
  export MINIMAL_ADMIN_EMAIL="$_admin_email"
  export MINIMAL_ADMIN_PASS="$_admin_pass"
  export SEAFILE_SERVER_PROTOCOL="http"
}

# ===========================================================================
# CHECK FOR .ENV AND OFFER OPTIONS
# ===========================================================================
check_env_and_configure() {
  local env_file="/opt/seafile/.env"
  local env_dir="/opt/seafile"

  # Create directory if needed
  mkdir -p "$env_dir"

  # ── State 1: No .env (or empty) — show configuration timing choice ──────
  if [[ ! -f "$env_file" ]] || [[ ! -s "$env_file" ]]; then
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}  1  ${NC}${BOLD}Configure now${NC}  ${DIM}(default)${NC}"
    echo -e "     ${DIM}Set up your server with the guided installer${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}  2  ${NC}${BOLD}Configure later${NC}"
    echo -e "     ${DIM}Get a basic server running now — configure${NC}"
    echo -e "     ${DIM}everything else in the browser or CLI after${NC}"
    echo ""
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local _timing=""
    while true; do
      echo -ne "  ${BOLD}Select [1/2] (default: 1):${NC} "
      read -r _timing
      _timing="${_timing:-1}"
      case "$_timing" in
        1) _show_deployment_modes "$env_file"; return $? ;;
        2) run_configure_later "$env_file"; return 0 ;;
        *) echo -e "  ${DIM}Enter 1 or 2.${NC}" ;;
      esac
    done
    return 0
  fi

  # ── .env exists and is non-empty — check completeness ───────────────────
  _load_env "$env_file"
  local _chk_missing=()
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
