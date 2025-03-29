#!/bin/bash

# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# This script rotates the cron.log file when it reaches CRON_LOG_MAX_SIZE in size.
# Old log files are compressed using tar and only the MAX_CRON_LOG_ARCHIVES most recent archives are kept.
# =========================================================

# Define variables
LAST_LOGFILE="/var/log/rotate-last.log"
LOG_FILE="/var/log/cron.log"
ARCHIVE_DIR="/var/log"

# Function to write to the last log file
logLast() {
  echo "$1" >> "${LAST_LOGFILE}"
}

# Function to log messages to both console and log file
log() {
  local message="$1"
  echo "${message}"
  logLast "${message}"
}

# Clear log file
rm -f "${LAST_LOGFILE}"

# Note backup start
log "📋 Starting rotation check at $(date +"%Y-%m-%d %a %H:%M:%S")..."

# Log environment variables
logLast "ROTATE_LOG_CRON: ${ROTATE_LOG_CRON}"
logLast "CRON_LOG_MAX_SIZE: ${CRON_LOG_MAX_SIZE}"
logLast "MAX_CRON_LOG_ARCHIVES: ${MAX_CRON_LOG_ARCHIVES}"

# Create archive directory if it doesn't exist
if [ ! -d "$ARCHIVE_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR"
    log "📁 Created archive directory: $ARCHIVE_DIR..."
fi

# Check if log file exists
if [ ! -f "$LOG_FILE" ]; then
    log "❌ Log file does not exist: $LOG_FILE..."
    exit 1
fi

# Get file size in bytes
FILE_SIZE=$(stat -c%s "$LOG_FILE")

# Rotate log if size exceeds maximum
if [ $FILE_SIZE -ge ${CRON_LOG_MAX_SIZE} ]; then
    # Create timestamp for archive name
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    
    # Create tar archive
    tar -czf "$ARCHIVE_DIR/cron_log_$TIMESTAMP.tar.gz" "${LOG_FILE}" > /dev/null 2>&1
    
    # Clear the log file
    > "$LOG_FILE"
    
    log "🔄 Log file rotated and archived as cron_log_$TIMESTAMP.tar.gz..."
    
    # Remove oldest archives if we have more than ENV MAX_CRON_LOG_ARCHIVES
    ARCHIVE_COUNT=$(ls -1 "$ARCHIVE_DIR"/cron_log_*.tar.gz 2>/dev/null | wc -l)
    if [ $ARCHIVE_COUNT -gt ${MAX_CRON_LOG_ARCHIVES} ]; then
        # Find and delete the oldest archives
        ls -t "$ARCHIVE_DIR"/cron_log_*.tar.gz | tail -n +$((MAX_CRON_LOG_ARCHIVES+1)) | xargs rm -f
        log "🗑️ Removed oldest archives, keeping the ${MAX_CRON_LOG_ARCHIVES} most recent ones."
    fi
else
    log "📊 Log file size is ${FILE_SIZE} bytes, rotation not needed."
fi

log "✅ Log rotation check completed successfully at $(date +"%Y-%m-%d %a %H:%M:%S")..."

exit 0
