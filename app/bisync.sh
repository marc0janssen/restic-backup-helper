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

# Map SYNC_VERBOSE onto the shared LOG_VERBOSE used by /bin/lib.sh's log().
LOG_VERBOSE="${SYNC_VERBOSE:-OFF}"

# shellcheck source=lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

# Check if the file exists and is not empty
if [ ! -s "${SYNC_JOB_FILE}" ]; then
	errorlog "❌ The sync job file is empty or does not exist"
	exit 1
fi

# Check if the file contains at least one line with a semicolon
if ! grep -q ".*;" "${SYNC_JOB_FILE}"; then
	errorlog "❌ The sync job file does not contain semicolons for separation"
	exit 1
fi

# Clear log files
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

run_hook "pre-sync"

# Note sync start
log "🔄 Starting Sync at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "SYNC_CRON: ${SYNC_CRON}"
logLast "SYNC_JOB_FILE: ${SYNC_JOB_FILE}"
logLast "SYNC_JOB_ARGS: ${SYNC_JOB_ARGS}"

# Split the sync job args into an array while stripping any --resync flag
SYNC_JOB_ARGS_ARRAY=()
if [[ -n "${SYNC_JOB_ARGS}" ]]; then
	read -r -a RAW_SYNC_JOB_ARGS <<<"${SYNC_JOB_ARGS}"
	for arg in "${RAW_SYNC_JOB_ARGS[@]}"; do
		[[ "${arg}" == "--resync" ]] && continue
		SYNC_JOB_ARGS_ARRAY+=("${arg}")
	done
	unset RAW_SYNC_JOB_ARGS
fi

# Track sync errors across all jobs
syncHasError=0
overallRC=0
syncJobsProcessed=0
syncJobsFailed=0
syncRunStart=$(date +%s)

# Perform sync
while IFS= read -r line; do
	job_start=$(date +%s)
	# Skip empty lines and comment lines
	[[ -z "${line}" || "${line}" == \#* ]] && continue
	syncJobsProcessed=$((syncJobsProcessed + 1))

	# Split the line at the semicolon
	IFS=';' read -r SYNC_SOURCE SYNC_DESTINATION <<<"${line}"

	# Check if both variables have values
	if [ -z "$SYNC_SOURCE" ] || [ -z "$SYNC_DESTINATION" ]; then
		errorlog "⚠️ Invalid line: ${line}"
		continue
	fi

	log "🔀 Performing sync of ${SYNC_SOURCE} <-> ${SYNC_DESTINATION}..."
	rclone_cmd=(rclone bisync "${SYNC_SOURCE}" "${SYNC_DESTINATION}")
	rclone_cmd+=("${SYNC_JOB_ARGS_ARRAY[@]}")
	"${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
	syncRC=$?
	logLast "Finished sync at $(date +"%Y-%m-%d %a %H:%M:%S")"

	# Error handling
	if [ $syncRC -eq 0 ]; then
		log "✅ Sync Successful"
	else
		syncJobsFailed=$((syncJobsFailed + 1))
		errorlog "❌ Sync Failed with Status ${syncRC}"
		copyErrorLog

		# Recovery procedure
		errorlog "🚨 Starting recovery procedure for ${SYNC_SOURCE}..."

		# Step 1: Update destination from source
		log "🔄 Step 1: Updating from ${SYNC_SOURCE} to ${SYNC_DESTINATION}"
		rclone_copy_cmd=(rclone copy "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --update)
		rclone_copy_cmd+=("${SYNC_JOB_ARGS_ARRAY[@]}")
		"${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
		copy1RC=$?
		if [ $copy1RC -ne 0 ]; then
			syncHasError=1
			if [ $overallRC -eq 0 ]; then
				overallRC=$copy1RC
			fi
		fi

		# Step 2: Update source from destination
		log "🔄 Step 2: Updating from ${SYNC_DESTINATION} to ${SYNC_SOURCE}"
		rclone_copy_cmd=(rclone copy "${SYNC_DESTINATION}" "${SYNC_SOURCE}" --update)
		rclone_copy_cmd+=("${SYNC_JOB_ARGS_ARRAY[@]}")
		"${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
		copy2RC=$?
		if [ $copy2RC -ne 0 ]; then
			syncHasError=1
			if [ $overallRC -eq 0 ]; then
				overallRC=$copy2RC
			fi
		fi

		# Step 3: Resync if both copies were successful
		if [ $copy1RC -eq 0 ] && [ $copy2RC -eq 0 ]; then
			log "🔄 Step 3: Performing full resync between ${SYNC_SOURCE} and ${SYNC_DESTINATION}"
			rclone_cmd=(rclone bisync "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --resync)
			rclone_cmd+=("${SYNC_JOB_ARGS_ARRAY[@]}")
			"${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
			syncRC=$?

			if [ $syncRC -eq 0 ]; then
				errorlog "✅ Recovery Successful - All steps completed"
			else
				errorlog "❌ Recovery Failed - Resync failed with status ${syncRC}"
				syncHasError=1
				if [ $overallRC -eq 0 ]; then
					overallRC=$syncRC
				fi
			fi
		else
			# Detailed error reporting
			if [ $copy1RC -ne 0 ] && [ $copy2RC -ne 0 ]; then
				errorlog "❌ Recovery Failed - Both update operations failed"
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy1RC
				fi
			elif [ $copy1RC -ne 0 ]; then
				errorlog "❌ Recovery Failed - Source to destination update failed with status ${copy1RC}"
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy1RC
				fi
			else
				errorlog "❌ Recovery Failed - Destination to source update failed with status ${copy2RC}"
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy2RC
				fi
			fi
		fi

		# Log final recovery status
		log "📊 Recovery Exitcode Summary: Source→Dest=${copy1RC}, Dest→Source=${copy2RC}, Resync=${syncRC}"
	fi

	# Record end time
	end=$(date +%s)
	duration=$((end - job_start))
	minutes=$((duration / 60))
	seconds=$((duration % 60))

	log "🏁 Finished sync at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

done <"${SYNC_JOB_FILE}"

syncRunEnd=$(date +%s)

# Persist a structured per-run summary for external monitoring.
write_last_run_json "sync" "${overallRC}" "${syncRunStart}" "${syncRunEnd}" \
	"sync_jobs_processed" "${syncJobsProcessed}" \
	"sync_jobs_failed" "${syncJobsFailed}"

# POST the same payload to WEBHOOK_URL when configured (no-op otherwise).
notify_webhook "sync" "${overallRC}" "${syncRunStart}" "${syncRunEnd}" \
	"sync_jobs_processed" "${syncJobsProcessed}" \
	"sync_jobs_failed" "${syncJobsFailed}" || true

# Send mail notification
if [ -n "${MAILX_RCPT}" ] && [ "$syncHasError" -ne 0 ]; then
	log "📧 Sending email notification to ${MAILX_RCPT}..."
	if mail -v -s "Result of the last ${HOSTNAME} sync" "${MAILX_RCPT}" <"${LAST_LOGFILE}" >"${LAST_MAIL_LOGFILE}" 2>&1; then
		log "✅ Mail notification successfully sent"
	else
		errorlog "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
	fi
fi

run_hook "post-sync" "$overallRC" || true

exit "$overallRC"
