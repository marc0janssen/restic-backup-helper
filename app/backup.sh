#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Script
# Description: Script for performing backups with Restic
# =========================================================

# Define log files
LAST_LOGFILE="/var/log/backup-last.log"
LAST_ERROR_LOGFILE="/var/log/backup-error-last.log"
LAST_MAIL_LOGFILE="/var/log/backup-mail-last.log"

# Function to copy error log
copyErrorLog() {
  cp "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
}

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

# Clear log files
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Check if pre-backup script exists and execute it
if [ -f "/hooks/pre-backup.sh" ]; then
  log "🚀 Starting pre-backup script..."
  /hooks/pre-backup.sh
else
  log "ℹ️ Pre-backup script not found..."
fi

# Record start time
start=$(date +%s)

# Note backup start
log "🔄 Starting Backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "BACKUP_CRON: ${BACKUP_CRON}"
logLast "BACKUP_ROOT_DIR: ${BACKUP_ROOT_DIR}"
logLast "RESTIC_TAG: ${RESTIC_TAG}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"

# Perform backup
if [ -n "${BACKUP_ROOT_DIR}" ]; then
  log "📦 Performing backup of ${BACKUP_ROOT_DIR}..."
else
  log "📦 Performing backup of serveral sources..."
fi
restic backup "${BACKUP_ROOT_DIR}" ${RESTIC_JOB_ARGS} --tag="${RESTIC_TAG?"Missing environment variable RESTIC_TAG"}" >> "${LAST_LOGFILE}" 2>&1
backupRC=$?
logLast "Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ $backupRC -eq 0 ]; then
  log "✅ Backup Successful"
else
  log "❌ Backup Failed with Status ${backupRC}"
  log "🔓 Unlocking repository..."
  restic unlock
  copyErrorLog
fi

# Execute forget if backup was successful and RESTIC_FORGET_ARGS is set
if [ $backupRC -eq 0 ] && [ -n "${RESTIC_FORGET_ARGS}" ]; then
  log "🧹 Forgetting old snapshots based on: ${RESTIC_FORGET_ARGS}"
  restic forget ${RESTIC_FORGET_ARGS} >> "${LAST_LOGFILE}" 2>&1
  rc=$?
  logLast "Finished forget at $(date +"%Y-%m-%d %a %H:%M:%S")"
  
  # Error handling for forget
  if [ $rc -eq 0 ]; then
    log "✅ Forget Successful"
  else
    log "❌ Forget Failed with Status ${rc}"
    log "🔓 Unlocking repository..."
    restic unlock
    copyErrorLog
  fi
fi

# Record end time
end=$(date +%s)
duration=$((end-start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

# Check if post-backup script exists and execute it
if [ -f "/hooks/post-backup.sh" ]; then
  log "🚀 Starting post-backup script..."
  /hooks/post-backup.sh $backupRC
else
  log "ℹ️ Post-backup script not found..."
fi

# Send mail notification
if [ -n "${MAILX_RCPT}" ] && (
  [ "${MAILX_ON_ERROR^^}" == "ON" ] && [ $backupRC -ne 0 ] ||
  [ "${MAILX_ON_ERROR^^}" != "ON" ]
); then
  log "📧 Sending email notification to ${MAILX_RCPT}..."
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} backup run on ${RESTIC_REPOSITORY}' ${MAILX_RCPT} < ${LAST_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
    log "✅ Mail notification successfully sent"
  else
    log "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
  fi
fi

exit $backupRC
