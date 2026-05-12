#!/bin/bash

# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# This script rotates the cron.log file when it reaches CRON_LOG_MAX_SIZE in size.
# Old log files are compressed using tar and only the MAX_CRON_LOG_ARCHIVES most recent archives are kept.
# =========================================================

set -Eeuo pipefail

# Define variables
LAST_LOGFILE="/var/log/rotate-last.log"
LOG_FILE="/var/log/cron.log"
ARCHIVE_DIR="/var/log"

# shellcheck source=lib.sh
. /bin/lib.sh

# Clear log file
rm -f "${LAST_LOGFILE}"

# Note backup start
log "📋 Starting rotation check at $(date +"%Y-%m-%d %a %H:%M:%S")..."

# Log environment variables
logLast "ROTATE_LOG_CRON: ${ROTATE_LOG_CRON:-}"
logLast "CRON_LOG_MAX_SIZE: ${CRON_LOG_MAX_SIZE:-}"
logLast "MAX_CRON_LOG_ARCHIVES: ${MAX_CRON_LOG_ARCHIVES:-}"

is_positive_int() {
	[[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

if ! is_positive_int "${CRON_LOG_MAX_SIZE:-}"; then
	log "❌ CRON_LOG_MAX_SIZE must be a positive integer (got '${CRON_LOG_MAX_SIZE:-}')."
	exit 1
fi

if ! is_positive_int "${MAX_CRON_LOG_ARCHIVES:-}"; then
	log "❌ MAX_CRON_LOG_ARCHIVES must be a positive integer (got '${MAX_CRON_LOG_ARCHIVES:-}')."
	exit 1
fi

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
if [ "$FILE_SIZE" -ge "${CRON_LOG_MAX_SIZE}" ]; then
	TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
	ARCHIVE_NAME="cron_log_${TIMESTAMP}.tar.gz"
	ARCHIVE_PATH="${ARCHIVE_DIR}/${ARCHIVE_NAME}"
	LOG_BASENAME="$(basename "${LOG_FILE}")"
	LOG_DIR="$(dirname "${LOG_FILE}")"

	# Archive with relative path so extraction does not recreate /var/log/...
	if tar -C "${LOG_DIR}" -czf "${ARCHIVE_PATH}" "${LOG_BASENAME}" >/dev/null 2>&1; then
		# Only truncate after a successful archive to avoid losing log data on tar failure.
		: >"$LOG_FILE"
		log "🔄 Log file rotated and archived as ${ARCHIVE_NAME}..."
	else
		log "❌ Failed to create archive ${ARCHIVE_PATH}; cron.log left intact."
		rm -f "${ARCHIVE_PATH}"
		exit 1
	fi

	# Remove oldest archives if we have more than ENV MAX_CRON_LOG_ARCHIVES
	ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'cron_log_*.tar.gz' 2>/dev/null | wc -l | tr -d '[:space:]')
	if [ "$ARCHIVE_COUNT" -gt "${MAX_CRON_LOG_ARCHIVES}" ]; then
		# Names are cron_log_<timestamp>.tar.gz only (mtime sort via ls -t)
		# shellcheck disable=SC2012
		while IFS= read -r path; do
			[ -n "$path" ] && rm -f "$path"
		done < <(ls -t "$ARCHIVE_DIR"/cron_log_*.tar.gz 2>/dev/null | tail -n +$((MAX_CRON_LOG_ARCHIVES + 1)))
		log "🗑️ Removed oldest archives, keeping the ${MAX_CRON_LOG_ARCHIVES} most recent ones."
	fi
else
	log "📊 Log file size is ${FILE_SIZE} bytes, rotation not needed."
fi

log "✅ Log rotation check completed successfully at $(date +"%Y-%m-%d %a %H:%M:%S")..."

exit 0
