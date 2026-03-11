#!/usr/bin/env bash
# =============================================================================
# build.sh — Builds all generated scripts from templates and source components
# =============================================================================
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC}  $1"; }
err()  { echo -e "${RED}  ✗${NC}  $1"; }
info() { echo -e "     $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source paths
SETUP_TEMPLATE="${REPO_ROOT}/src/setup.template.sh"
UPDATE_TEMPLATE="${REPO_ROOT}/src/update.template.sh"
HEADER="${REPO_ROOT}/src/deploy-header.sh"
FOOTER="${REPO_ROOT}/src/deploy-footer.sh"
SHARED_LIB="${REPO_ROOT}/src/shared-lib.sh"
DOCKER_COMPOSE="${REPO_ROOT}/src/docker-compose.yml"
CADDYFILE="${REPO_ROOT}/src/Caddyfile"
CONFIG_FIXES="${REPO_ROOT}/scripts/seafile-config-fixes.sh"
ENV_SYNC="${REPO_ROOT}/scripts/env-sync/seafile-env-sync.sh"
RECOVERY_FINALIZE="${REPO_ROOT}/scripts/recovery-finalize/seafile-recovery-finalize.sh"
CONFIG_GIT_SERVER="${REPO_ROOT}/scripts/config-git-server/seafile-config-server.sh"
CONFIG_GIT_SERVICE="${REPO_ROOT}/scripts/config-git-server/seafile-config-server.service"
GITOPS_SYNC="${REPO_ROOT}/scripts/gitops/seafile-gitops-sync.py"
GITOPS_SERVICE="${REPO_ROOT}/scripts/gitops/seafile-gitops-sync.service"
STORAGE_SYNC="${REPO_ROOT}/scripts/storage-sync/seafile-storage-sync.sh"
STORAGE_SYNC_SERVICE="${REPO_ROOT}/scripts/storage-sync/seafile-storage-sync.service"
GUIDED_SETUP="${REPO_ROOT}/src/guided-setup.sh"
ENV_TEMPLATE="${REPO_ROOT}/src/.env.template"
CLI_SCRIPT="${REPO_ROOT}/scripts/seafile-cli.sh"

# Generated outputs
UPDATE_OUTPUT="${REPO_ROOT}/scripts/update.sh"
SETUP_OUTPUT="${REPO_ROOT}/scripts/setup.sh"
DEPLOY_OUTPUT="${REPO_ROOT}/seafile-deploy.sh"

# =============================================================================
# Process a template file, replacing {{EMBED:path}} and {{ENV_TEMPLATE}}
# =============================================================================
process_template() {
  local template="$1" output="$2"
  local -a lines=()
  while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done < "$template"
  > "$output"
  for line in "${lines[@]}"; do
    if [[ "$line" =~ \{\{EMBED:([^}]+)\}\} ]]; then
      local embed_path="${BASH_REMATCH[1]}"
      local full_path="${REPO_ROOT}/${embed_path}"
      [[ ! -f "$full_path" ]] && err "Embed file not found: $embed_path" && return 1
      cat "$full_path" >> "$output"
    elif [[ "$line" =~ \{\{ENV_TEMPLATE\}\} ]]; then
      cat "$ENV_TEMPLATE" >> "$output"
    else
      echo "$line" >> "$output"
    fi
  done
  chmod +x "$output"
}

# =============================================================================
# Verify source files exist
# =============================================================================
verify_sources() {
  local missing=()
  for f in "$SETUP_TEMPLATE" "$UPDATE_TEMPLATE" "$HEADER" "$FOOTER" "$SHARED_LIB" \
           "$DOCKER_COMPOSE" "$CADDYFILE" "$CONFIG_FIXES" "$ENV_SYNC" "$RECOVERY_FINALIZE" \
           "$CONFIG_GIT_SERVER" "$CONFIG_GIT_SERVICE" \
           "$GITOPS_SYNC" "$GITOPS_SERVICE" "$STORAGE_SYNC" "$STORAGE_SYNC_SERVICE" \
           "$GUIDED_SETUP" "$ENV_TEMPLATE" "$CLI_SCRIPT"; do
    [[ -f "$f" ]] || missing+=("$f")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing source files:"; for f in "${missing[@]}"; do echo "       $f"; done; exit 1
  fi
  ok "All source files present"
}

clean_generated() {
  echo "Cleaning generated files..."
  rm -f "$UPDATE_OUTPUT" "$SETUP_OUTPUT" "$DEPLOY_OUTPUT"
  ok "Cleaned generated files"
}

# =============================================================================
# Main build
# =============================================================================
build_all() {
  echo ""; echo "Building from templates..."; echo ""

  # Step 1: Process shared-lib.sh (resolve {{ENV_TEMPLATE}})
  info "Processing shared-lib.sh..."
  local processed_shared; processed_shared=$(mktemp)
  sed -e "/{{ENV_TEMPLATE}}/r ${ENV_TEMPLATE}" -e "/{{ENV_TEMPLATE}}/d" "$SHARED_LIB" > "$processed_shared"
  ok "Processed shared-lib.sh ($(wc -l < "$processed_shared") lines)"

  # Step 2: Process update.sh
  # update.template.sh embeds shared-lib and docker-compose — we need shared-lib
  # pre-processed (with .env.template resolved), so temporarily replace src/shared-lib.sh
  local shared_backup; shared_backup=$(mktemp)
  cp "$SHARED_LIB" "$shared_backup"
  cp "$processed_shared" "$SHARED_LIB"

  info "Processing update.template.sh..."
  process_template "$UPDATE_TEMPLATE" "$UPDATE_OUTPUT" \
    && ok "Generated scripts/update.sh ($(wc -l < "$UPDATE_OUTPUT") lines)" \
    || { err "Failed to process update.template.sh"; cp "$shared_backup" "$SHARED_LIB"; exit 1; }

  # Step 3: Process setup.sh (embeds update.sh, config-fixes, CLI, etc.)
  info "Processing setup.template.sh..."
  process_template "$SETUP_TEMPLATE" "$SETUP_OUTPUT" \
    && ok "Generated scripts/setup.sh ($(wc -l < "$SETUP_OUTPUT") lines)" \
    || { err "Failed to process setup.template.sh"; cp "$shared_backup" "$SHARED_LIB"; exit 1; }

  # Restore original shared-lib.sh (with {{ENV_TEMPLATE}} marker intact)
  cp "$shared_backup" "$SHARED_LIB"

  # Step 4: Process guided-setup.sh (resolve {{ENV_TEMPLATE}})
  info "Processing guided-setup.sh..."
  local processed_guided; processed_guided=$(mktemp)
  sed -e "/{{ENV_TEMPLATE}}/r ${ENV_TEMPLATE}" -e "/{{ENV_TEMPLATE}}/d" "$GUIDED_SETUP" > "$processed_guided"

  # Step 5: Process deploy-footer.sh (resolve {{ENV_TEMPLATE}} in normalize_env)
  # Footer no longer has {{ENV_TEMPLATE}} since normalize moved to shared-lib,
  # but process it anyway for future-proofing
  local processed_footer; processed_footer=$(mktemp)
  sed -e "/{{ENV_TEMPLATE}}/r ${ENV_TEMPLATE}" -e "/{{ENV_TEMPLATE}}/d" "$FOOTER" > "$processed_footer"

  # Step 6: Assemble seafile-deploy.sh
  echo ""; info "Assembling seafile-deploy.sh..."
  {
    cat "$HEADER"
    echo ""
    echo "# ==========================================================================="
    echo "# Shared Library (embedded from src/shared-lib.sh)"
    echo "# ==========================================================================="
    cat "$processed_shared"
    echo ""
    echo "# ==========================================================================="
    echo "# Guided Setup Wizard (embedded from src/guided-setup.sh)"
    echo "# ==========================================================================="
    cat "$processed_guided"
    echo ""
    echo "# ==========================================================================="
    echo "# Embedded setup.sh (unified install + recover)"
    echo "# ==========================================================================="
    echo "extract_setup() {"
    printf "cat << 'SETUP_EMBED_EOF'\n"
    cat "$SETUP_OUTPUT"
    printf "\nSETUP_EMBED_EOF\n"
    echo "}"
    echo ""
    cat "$processed_footer"
  } > "$DEPLOY_OUTPUT"

  rm -f "$processed_shared" "$processed_guided" "$processed_footer" "$shared_backup"
  chmod +x "$DEPLOY_OUTPUT"
  ok "Generated seafile-deploy.sh ($(wc -l < "$DEPLOY_OUTPUT") lines)"
  echo ""; echo "Build complete!"
}

# =============================================================================
# Verify
# =============================================================================
verify_build() {
  echo ""; echo "Verifying build..."; echo ""
  local errors=0
  for script in "$UPDATE_OUTPUT" "$SETUP_OUTPUT" "$DEPLOY_OUTPUT"; do
    if [[ -f "$script" ]]; then
      if bash -n "$script" 2>/dev/null; then ok "$(basename "$script") — syntax OK"
      else err "$(basename "$script") — syntax ERROR"; bash -n "$script" 2>&1 | head -5; errors=$((errors + 1)); fi
    else err "$(basename "$script") — file not found"; errors=$((errors + 1)); fi
  done
  echo ""
  for script in "$UPDATE_OUTPUT" "$SETUP_OUTPUT"; do
    if grep -q '{{EMBED:\|{{ENV_TEMPLATE}}' "$script" 2>/dev/null; then
      err "$(basename "$script") — unprocessed markers found!"
      grep '{{EMBED:\|{{ENV_TEMPLATE}}' "$script" | head -3
      errors=$((errors + 1))
    else ok "$(basename "$script") — all markers processed"; fi
  done
  echo ""
  grep -q "^cat << 'SETUP_EMBED_EOF'" "$DEPLOY_OUTPUT" && ok "SETUP_EMBED_EOF marker present" \
    || { err "SETUP_EMBED_EOF MISSING"; errors=$((errors + 1)); }
  head -1 "$DEPLOY_OUTPUT" | grep -q "^#!/bin/bash" && ok "shebang correct" \
    || { err "shebang MISSING"; errors=$((errors + 1)); }
  # Check guided-setup is at global scope
  local extract_line guided_line
  extract_line=$(grep -n "^extract_setup()" "$DEPLOY_OUTPUT" | head -1 | cut -d: -f1 || echo "0")
  guided_line=$(grep -n "^check_env_and_configure()" "$DEPLOY_OUTPUT" | head -1 | cut -d: -f1 || echo "99999")
  if [[ "$guided_line" -lt "$extract_line" ]]; then
    ok "guided-setup at global scope (before extract_setup)"
  else
    err "guided-setup NOT at global scope"; errors=$((errors + 1))
  fi
  echo ""
  if [[ $errors -eq 0 ]]; then ok "All verification checks passed!"; else err "$errors check(s) failed"; exit 1; fi
}

print_summary() {
  echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Generated files:"; echo ""
  printf "  %-35s %6d lines\n" "scripts/update.sh" "$(wc -l < "$UPDATE_OUTPUT")"
  printf "  %-35s %6d lines\n" "scripts/setup.sh" "$(wc -l < "$SETUP_OUTPUT")"
  printf "  %-35s %6d lines\n" "seafile-deploy.sh" "$(wc -l < "$DEPLOY_OUTPUT")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

case "${1:-}" in
  --clean) clean_generated; exit 0 ;;
  --verify) verify_sources; build_all; verify_build; print_summary ;;
  --help|-h) echo "Usage: $0 [--verify|--clean|--help]"; exit 0 ;;
  *) verify_sources; build_all; print_summary ;;
esac
