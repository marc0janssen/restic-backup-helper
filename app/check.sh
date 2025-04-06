#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Check Script
# Description: Script for verifying repository integrity with Restic
# =========================================================

# Define log files
LAST_CHECK_LOGFILE="/var/log/check-last.log"
LAST_ERROR_CHECK_LOGFILE="/var/log/check-error-last.log"
LAST_MAIL_LOGFILE="/var/log/check-mail-last.log"

# Function to copy error log
copyErrorLog() {
  cp "${LAST_CHECK_LOGFILE}" "${LAST_ERROR_CHECK_LOGFILE}"
}

# Function to write to the last log file
logLast() {
  echo "$1" >> "${LAST_CHECK_LOGFILE}"
}

# Function to log messages to both console and log file
log() {
  local message="$1"
  echo "${message}"
  logLast "${message}"
}

# Check if pre-check script exists and execute it
if [ -f "/hooks/pre-check.sh" ]; then
  log "🚀 Starting pre-check script..."
  /hooks/pre-check.sh
else
  log "ℹ️ Pre-check script not found..."
fi

# Record start time
start=$(date +%s)

# Clear log files
rm -f "${LAST_CHECK_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Note check start
log "🔍 Starting Check at $(date +"%Y-%m-%d %a %H:%M:%S")"
#log "Starting Check at $(date)" >> "${LAST_CHECK_LOGFILE}"

# Log environment variables
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"

# Perform repository check
log "🔍 Verifying repository integrity..."
restic check ${RESTIC_CHECK_ARGS} >> "${LAST_CHECK_LOGFILE}" 2>&1
checkRC=$?
logLast "Finished check at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ $checkRC -eq 0 ]; then
  log "✅ Check Successful"
else
  log "❌ Check Failed with Status ${checkRC}"
  log "🔓 Unlocking repository..."
  restic unlock
  copyErrorLog
fi

# Record end time
end=$(date +%s)
duration=$((end-start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished check at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

# Send mail notification
if [ -n "${MAILX_RCPT}" ] && (
  [ "${MAILX_ON_ERROR^^}" == "ON" ] && [ $checkRC -ne 0 ] ||
  [ "${MAILX_ON_ERROR^^}" != "ON" ]
); then
  log "📧 Sending email notification to ${MAILX_RCPT}..."
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} check run on ${RESTIC_REPOSITORY}' ${MAILX_RCPT} < ${LAST_CHECK_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
    log "✅ Mail notification successfully sent"
  else
    log "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
  fi
fi

# Check if post-check script exists and execute it
if [ -f "/hooks/post-check.sh" ]; then
  log "🚀 Starting post-check script..."
  /hooks/post-check.sh $checkRC
else
  log "ℹ️ Post-check script not found..."
fi

exit $checkRC
