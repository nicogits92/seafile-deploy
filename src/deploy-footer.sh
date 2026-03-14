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
