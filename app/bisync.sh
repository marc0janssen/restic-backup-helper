#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Rclone bisync Script
# Description: Script for performing bisync with Rclone
# =========================================================

# Define log files
LAST_LOGFILE="/var/log/sync-last.log"
LAST_ERROR_LOGFILE="/var/log/sync-error-last.log"
LAST_MAIL_LOGFILE="/var/log/sync-mail-last.log"

# Get releasenumber from file
RELEASE=$(cat /.release)

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
  [[ "${SYNC_VERBOSE^^}" == "ON" ]] && echo "${message}"
  logLast "${message}"
}

# Function to log errors to both console and log file
errorlog() {
  local message="$1"
  echo "${message}"
  logLast "${message}"
}

# Check if the file exists and is not empty
if [ ! -s ${SYNC_JOB_FILE} ]; then
  errorlog "❌ The sync job file is empty or does not exist"
  exit 1
fi

# Check if the file contains at least one line with a semicolon
if ! grep -q ".*;" ${SYNC_JOB_FILE}; then
  errorlog "❌ The sync job file does not contain semicolons for separation"
  exit 1
fi

# Clear log files
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Check if pre-sync script exists and execute it
if [ -f "/hooks/pre-sync.sh" ]; then
  log "🚀 Starting pre-sync script..."
  /hooks/pre-sync.sh
else
  log "ℹ️ Pre-sync script not found..."
fi

# Record start time
start=$(date +%s)

# Note sync start
log "🔄 Starting Sync at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "SYNC_CRON: ${SYNC_CRON}"
logLast "SYNC_JOB_FILE: ${SYNC_JOB_FILE}"
logLast "SYNC_JOB_ARGS: ${SYNC_JOB_ARGS}"

# Set possible sync errors to no errors
syncHasNoError=0

# Perform sync
while IFS= read -r line; do
  # Skip empty lines and comment lines
    [[ -z "${line}" || "${line}" == \#* ]] && continue

  # Split the line at the semicolon
  IFS=';' read -r SYNC_SOURCE SYNC_DESTINATION <<< "${line}"

  # Check if both variables have values
  if [ -z "$SYNC_SOURCE" ] || [ -z "$SYNC_DESTINATION" ]; then
    errorlog "⚠️ Invalid line: ${line}"
    continue
  fi
  
  log "🔀 Performing sync of ${SYNC_SOURCE} <-> ${SYNC_DESTINATION}..."
  SYNC_JOB_ARGS=$(echo "$SYNC_JOB_ARGS" | sed 's/--resync//g')
  rclone bisync ${SYNC_SOURCE} ${SYNC_DESTINATION} ${SYNC_JOB_ARGS} >> "${LAST_LOGFILE}" 2>&1
  syncRC=$?
  logLast "Finished sync at $(date +"%Y-%m-%d %a %H:%M:%S")"

  # Error handling
  if [ $syncRC -eq 0 ]; then
    log "✅ Sync Successful"
  else
    errorlog "❌ Sync Failed with Status ${syncRC}"
    copyErrorLog
    
    # Recovery procedure
    errorlog "🚨 Starting recovery procedure for ${SYNC_SOURCE}..."
    
    # Step 1: Update destination from source
    log "🔄 Step 1: Updating from ${SYNC_SOURCE} to ${SYNC_DESTINATION}"
    rclone copy "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --update ${SYNC_JOB_ARGS} >> "${LAST_LOGFILE}" 2>&1
    copy1RC=$?
    
    # Step 2: Update source from destination
    log "🔄 Step 2: Updating from ${SYNC_DESTINATION} to ${SYNC_SOURCE}"
    rclone copy "${SYNC_DESTINATION}" "${SYNC_SOURCE}" --update ${SYNC_JOB_ARGS} >> "${LAST_LOGFILE}" 2>&1
    copy2RC=$?
    
    # Step 3: Resync if both copies were successful
    if [ $copy1RC -eq 0 ] && [ $copy2RC -eq 0 ]; then
      log "🔄 Step 3: Performing full resync between ${SYNC_SOURCE} and ${SYNC_DESTINATION}"
      rclone bisync "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --resync ${SYNC_JOB_ARGS} >> "${LAST_LOGFILE}" 2>&1
      syncRC=$?
      
      if [ $syncRC -eq 0 ]; then
        errorlog "✅ Recovery Successful - All steps completed"
      else
        errorlog "❌ Recovery Failed - Resync failed with status ${syncRC}"
        syncHasNoError=1
      fi
    else
      # Detailed error reporting
      if [ $copy1RC -ne 0 ] && [ $copy2RC -ne 0 ]; then
        errorlog "❌ Recovery Failed - Both update operations failed"
      elif [ $copy1RC -ne 0 ]; then
        errorlog "❌ Recovery Failed - Source to destination update failed with status ${copy1RC}"
      else
        errorlog "❌ Recovery Failed - Destination to source update failed with status ${copy2RC}"
      fi
    fi
    
    # Log final recovery status
    log "📊 Recovery Exitcode Summary: Source→Dest=${copy1RC}, Dest→Source=${copy2RC}, Resync=${syncRC}"
  fi

  # Record end time
  end=$(date +%s)
  duration=$((end-start))
  minutes=$((duration / 60))
  seconds=$((duration % 60))

  log "🏁 Finished sync at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"
  
done < ${SYNC_JOB_FILE}

# Send mail notification
if [ -n "${MAILX_RCPT}" ] && [ $syncHasNoError -ne 0 ]; then
  log "📧 Sending email notification to ${MAILX_RCPT}..."
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} sync' ${MAILX_RCPT} < ${LAST_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
    log "✅ Mail notification successfully sent"
  else
    errorlog "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
  fi
fi

# Check if post-sync script exists and execute it
if [ -f "/hooks/post-sync.sh" ]; then
  log "🚀 Starting post-sync script..."
  /hooks/post-sync.sh $syncRC
else
  log "ℹ️ Post-sync script not found..."
fi

exit $syncRC
