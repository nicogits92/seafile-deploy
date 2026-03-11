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
