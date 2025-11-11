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

# Masked variables
MASKED_REPO=$(echo "${RESTIC_REPOSITORY}" | sed -E 's#(https://[^:]+:)[^@]+(@)#\1***\2#')

# Get releasenumber from file
RELEASE=$(cat /.release)

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

# If the RESTIC_PUBLICKEY variable is set, add the --cacert option with its value; otherwise, leave it empty.
#[ -n "${RESTIC_PUBLICKEY}" ] && CACERT_OPTION="--cacert ${RESTIC_PUBLICKEY}" || CACERT_OPTION=""

# Clear log files
rm -f "${LAST_CHECK_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Check if pre-check script exists and execute it
if [ -f "/hooks/pre-check.sh" ]; then
  log "🚀 Starting pre-check script..."
  /hooks/pre-check.sh
else
  log "ℹ️ Pre-check script not found..."
fi

# Record start time
start=$(date +%s)

# Note check start
log "🔍 Starting Check at $(date +"%Y-%m-%d %a %H:%M:%S")"
#log "Starting Check at $(date)" >> "${LAST_CHECK_LOGFILE}"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

# Perform repository check
if [ -n "${RESTIC_CHECK_ARGS}" ]; then
  log "🔍 Verifying repository integrity using RESTIC_CHECK_ARGS..."
else
  log "🔍 Verifying repository integrity with restic defaults..."
fi

check_cmd=(check)

if [ -n "${RESTIC_CHECK_ARGS}" ]; then
  read -r -a restic_check_args <<< "${RESTIC_CHECK_ARGS}"
  check_cmd+=("${restic_check_args[@]}")
fi

restic "${check_cmd[@]}" >> "${LAST_CHECK_LOGFILE}" 2>&1
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
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} check run on ${MASKED_REPO}' ${MAILX_RCPT} < ${LAST_CHECK_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
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
