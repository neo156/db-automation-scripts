#!/bin/bash

# PostgreSQL Automated Backup Script for macOS
# Author: Your Name
# Date: 2025-11-14

set -e
set -o pipefail

# ============================================================================
# CONFIGURATION SECTION
# ============================================================================

CURRENT_USER=$(whoami)
HOSTNAME=$(hostname -s)

# Directory Configuration
BASE_DIR="$HOME/Laboratory Exercises/Lab8"
BACKUP_DIR="${BASE_DIR}/backups"
LOG_FILE="/var/log/pg_backup.log"

# Database Configuration
DB_NAME="production_db"
DB_USER="$CURRENT_USER"
DB_HOST="localhost"
DB_PORT="5432"

# Email Configuration
ADMIN_EMAIL="dba-alerts@yourcompany.com"
FROM_EMAIL="$(whoami)@$(hostname)"

# Cloud Configuration
GDRIVE_REMOTE="gdrive_backups:"
GDRIVE_PATH="postgresql_backups"

# Backup Retention (days)
RETENTION_DAYS=7

# Timestamp for backup files
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)

# Backup filenames
LOGICAL_BACKUP="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump"
PHYSICAL_BACKUP="${BACKUP_DIR}/pg_base_backup_${TIMESTAMP}.tar.gz"

# Status flag
BACKUP_FAILED=0

# ============================================================================
# FUNCTIONS
# ============================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"
    
    echo -e "Subject: ${subject}\nFrom: ${FROM_EMAIL}\nTo: ${ADMIN_EMAIL}\n\n${body}" | \
        msmtp -a default "$ADMIN_EMAIL" 2>&1 | tee -a "$LOG_FILE"
}

handle_error() {
    local error_msg="$1"
    log_message "ERROR: $error_msg"
    BACKUP_FAILED=1
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

log_message "=========================================="
log_message "Starting PostgreSQL Backup Process"
log_message "=========================================="

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    log_message "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
fi

# Verify PostgreSQL is running
if ! psql -d postgres -c '\q' 2>/dev/null; then
    handle_error "PostgreSQL is not running or not accessible"
    send_email "FAILURE: PostgreSQL Backup Task" \
        "PostgreSQL service is not running or not accessible.\n\nPlease check the PostgreSQL service status.\n\nLast log entries:\n$(tail -n 15 "$LOG_FILE")"
    exit 1
fi

log_message "Pre-flight checks completed successfully"

# ============================================================================
# TASK 1: FULL LOGICAL BACKUP (pg_dump)
# ============================================================================

log_message "Starting Task 1: Full Logical Backup"
log_message "Backup file: $LOGICAL_BACKUP"

if pg_dump -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" \
    -Fc -f "$LOGICAL_BACKUP" "$DB_NAME" 2>&1 | tee -a "$LOG_FILE"; then
    
    LOGICAL_SIZE=$(du -h "$LOGICAL_BACKUP" | cut -f1)
    log_message "SUCCESS: Logical backup completed - Size: $LOGICAL_SIZE"
else
    handle_error "Logical backup failed for database: $DB_NAME"
fi

# ============================================================================
# TASK 2: PHYSICAL BASE BACKUP (pg_basebackup)
# ============================================================================

log_message "Starting Task 2: Physical Base Backup"
log_message "Backup file: $PHYSICAL_BACKUP"

PGDATA_DIR=$(psql -d postgres -t -c "SHOW data_directory;" | xargs)

if [ -d "$PGDATA_DIR" ]; then
    log_message "Data directory: $PGDATA_DIR"
    
    # Use tar to create physical backup
    if tar -czf "$PHYSICAL_BACKUP" -C "$(dirname "$PGDATA_DIR")" "$(basename "$PGDATA_DIR")" 2>&1 | tee -a "$LOG_FILE"; then
        PHYSICAL_SIZE=$(du -h "$PHYSICAL_BACKUP" | cut -f1)
        log_message "SUCCESS: Physical backup completed - Size: $PHYSICAL_SIZE"
    else
        handle_error "Physical backup failed"
    fi
else
    handle_error "Could not locate PostgreSQL data directory"
fi

# ============================================================================
# ERROR HANDLING AND NOTIFICATION
# ============================================================================

if [ $BACKUP_FAILED -eq 1 ]; then
    log_message "Backup process FAILED - sending notification"
    
    FAILURE_DETAILS="One or more backup tasks failed.\n\n"
    FAILURE_DETAILS+="Please review the details below:\n\n"
    FAILURE_DETAILS+="=== Last 15 Log Entries ===\n"
    FAILURE_DETAILS+="$(tail -n 15 "$LOG_FILE")\n"
    
    send_email "FAILURE: PostgreSQL Backup Task" "$FAILURE_DETAILS"
    
    log_message "Backup process terminated due to errors"
    exit 1
fi

log_message "All backup tasks completed successfully"

# ============================================================================
# TASK 3: CLOUD UPLOAD (Google Drive via rclone)
# ============================================================================

log_message "Starting cloud upload to Google Drive"

UPLOAD_FAILED=0

# Upload logical backup
log_message "Uploading logical backup: $(basename "$LOGICAL_BACKUP")"
if ! rclone copy "$LOGICAL_BACKUP" "${GDRIVE_REMOTE}${GDRIVE_PATH}/" -v 2>&1 | tee -a "$LOG_FILE"; then
    handle_error "Failed to upload logical backup to Google Drive"
    UPLOAD_FAILED=1
fi

# Upload physical backup
log_message "Uploading physical backup: $(basename "$PHYSICAL_BACKUP")"
if ! rclone copy "$PHYSICAL_BACKUP" "${GDRIVE_REMOTE}${GDRIVE_PATH}/" -v 2>&1 | tee -a "$LOG_FILE"; then
    handle_error "Failed to upload physical backup to Google Drive"
    UPLOAD_FAILED=1
fi

if [ $UPLOAD_FAILED -eq 1 ]; then
    log_message "Upload to Google Drive FAILED - sending notification"
    
    UPLOAD_FAILURE="Backups were created locally but failed to upload to Google Drive.\n\n"
    UPLOAD_FAILURE+="Local backup files:\n"
    UPLOAD_FAILURE+="- $(basename "$LOGICAL_BACKUP")\n"
    UPLOAD_FAILURE+="- $(basename "$PHYSICAL_BACKUP")\n\n"
    UPLOAD_FAILURE+="Please check rclone configuration and network connectivity.\n\n"
    UPLOAD_FAILURE+="=== Last 15 Log Entries ===\n"
    UPLOAD_FAILURE+="$(tail -n 15 "$LOG_FILE")\n"
    
    send_email "FAILURE: PostgreSQL Backup Upload" "$UPLOAD_FAILURE"
    
    log_message "Backup process completed but uploads failed"
    exit 1
fi

log_message "All backups uploaded successfully to Google Drive"

# Send success notification
SUCCESS_MESSAGE="PostgreSQL backup and upload completed successfully!\n\n"
SUCCESS_MESSAGE+="Database: ${DB_NAME}\n"
SUCCESS_MESSAGE+="Timestamp: ${TIMESTAMP}\n\n"
SUCCESS_MESSAGE+="Files created and uploaded:\n"
SUCCESS_MESSAGE+="1. Logical backup: $(basename "$LOGICAL_BACKUP") (${LOGICAL_SIZE})\n"
SUCCESS_MESSAGE+="2. Physical backup: $(basename "$PHYSICAL_BACKUP") (${PHYSICAL_SIZE})\n\n"
SUCCESS_MESSAGE+="Backup location: ${GDRIVE_REMOTE}${GDRIVE_PATH}/\n"

send_email "SUCCESS: PostgreSQL Backup and Upload" "$SUCCESS_MESSAGE"

# ============================================================================
# TASK 4: LOCAL CLEANUP
# ============================================================================

log_message "Starting local cleanup - removing backups older than ${RETENTION_DAYS} days"

DELETED_COUNT=0
while IFS= read -r file; do
    log_message "Deleting old backup: $(basename "$file")"
    rm -f "$file"
    ((DELETED_COUNT++))
done < <(find "$BACKUP_DIR" -type f \( -name "*.dump" -o -name "*.tar.gz" \) -mtime +${RETENTION_DAYS})

if [ $DELETED_COUNT -gt 0 ]; then
    log_message "Cleanup completed - removed $DELETED_COUNT old backup file(s)"
else
    log_message "No old backup files to remove"
fi

# ============================================================================
# COMPLETION
# ============================================================================

log_message "=========================================="
log_message "Backup Process Completed Successfully"
log_message "=========================================="

exit 0
