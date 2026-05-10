#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Rclone bisync Script
# Description: Script for performing bisync with Rclone
# =========================================================

set -Eeuo pipefail

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
if [ ! -s "${SYNC_JOB_FILE:-}" ]; then
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

# Pre-hook is informational; never abort the sync batch on a failing pre-hook
# (matches historical behaviour before `set -e`).
run_hook "pre-sync" || true

# Note sync start
log "🔄 Starting Sync at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "SYNC_CRON: ${SYNC_CRON:-}"
logLast "SYNC_JOB_FILE: ${SYNC_JOB_FILE}"
logLast "SYNC_JOB_ARGS: ${SYNC_JOB_ARGS:-}"

# Split the sync job args into an array while stripping any --resync flag
SYNC_JOB_ARGS_ARRAY=()
if [[ -n "${SYNC_JOB_ARGS:-}" ]]; then
	read -r -a RAW_SYNC_JOB_ARGS <<<"${SYNC_JOB_ARGS}"
	for arg in "${RAW_SYNC_JOB_ARGS[@]}"; do
		[[ "${arg}" == "--resync" ]] && continue
		SYNC_JOB_ARGS_ARRAY+=("${arg}")
	done
	unset RAW_SYNC_JOB_ARGS
fi

# Optional opt-in safety flag for bisync. When ON, every routine bisync run is
# extended with `--check-access` so rclone aborts (instead of treating one side
# as "everything deleted") when the well-known marker file is missing on either
# side. See README "Bisync recovery hardening" for how to seed RCLONE_TEST.
SYNC_BISYNC_CHECK_ACCESS_ARRAY=()
if [[ "${SYNC_BISYNC_CHECK_ACCESS:-OFF}" =~ ^[Oo][Nn]$ ]]; then
	SYNC_BISYNC_CHECK_ACCESS_ARRAY=(--check-access)
	logLast "SYNC_BISYNC_CHECK_ACCESS: ON (--check-access added to bisync runs)"
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

	# Split the line at semicolons. Backwards-compatible: legacy two-column lines
	# (SOURCE;DESTINATION) still work; optional 3rd field selects MODE
	# (bisync|sync|copy), optional 4th field carries per-job extra rclone args
	# that are appended after the global SYNC_JOB_ARGS for this job only.
	SYNC_MODE=""
	SYNC_PER_JOB_ARGS=""
	IFS=';' read -r SYNC_SOURCE SYNC_DESTINATION SYNC_MODE SYNC_PER_JOB_ARGS <<<"${line}"

	if [ -z "${SYNC_SOURCE:-}" ] || [ -z "${SYNC_DESTINATION:-}" ]; then
		errorlog "⚠️ Invalid line: ${line}"
		syncJobsFailed=$((syncJobsFailed + 1))
		syncHasError=1
		[ $overallRC -eq 0 ] && overallRC=2
		continue
	fi

	# Normalise mode and validate. Default to bisync to preserve historical behaviour.
	SYNC_MODE="${SYNC_MODE:-bisync}"
	SYNC_MODE="${SYNC_MODE,,}"
	case "${SYNC_MODE}" in
	bisync | sync | copy) ;;
	*)
		errorlog "⚠️ Invalid sync mode '${SYNC_MODE}' for line: ${line} (allowed: bisync, sync, copy). Skipping."
		syncJobsFailed=$((syncJobsFailed + 1))
		syncHasError=1
		[ $overallRC -eq 0 ] && overallRC=2
		continue
		;;
	esac

	# Build the per-job args array: global SYNC_JOB_ARGS + per-job EXTRA_ARGS.
	# Strip --resync from both because routine bisync runs must never resync
	# implicitly (the recovery branch adds it explicitly when warranted).
	PER_JOB_ARGS_ARRAY=("${SYNC_JOB_ARGS_ARRAY[@]}")
	if [ -n "${SYNC_PER_JOB_ARGS:-}" ]; then
		read -r -a RAW_PER_JOB <<<"${SYNC_PER_JOB_ARGS}"
		for arg in "${RAW_PER_JOB[@]}"; do
			[[ "${arg}" == "--resync" ]] && continue
			PER_JOB_ARGS_ARRAY+=("${arg}")
		done
		unset RAW_PER_JOB
	fi

	# Mask any inline credentials in source/destination before logging so a
	# config like `https://user:pass@host/path` does not leak to cron.log.
	SYNC_SOURCE_MASKED="$(mask_endpoint "${SYNC_SOURCE}")"
	SYNC_DESTINATION_MASKED="$(mask_endpoint "${SYNC_DESTINATION}")"

	case "${SYNC_MODE}" in
	bisync)
		log "🔀 Performing bisync of ${SYNC_SOURCE_MASKED} <-> ${SYNC_DESTINATION_MASKED}..."
		rclone_cmd=(rclone bisync "${SYNC_SOURCE}" "${SYNC_DESTINATION}")
		# --check-access opt-in only applies to bisync.
		rclone_cmd+=("${SYNC_BISYNC_CHECK_ACCESS_ARRAY[@]}")
		;;
	sync)
		log "➡️ Performing sync of ${SYNC_SOURCE_MASKED} -> ${SYNC_DESTINATION_MASKED}..."
		rclone_cmd=(rclone sync "${SYNC_SOURCE}" "${SYNC_DESTINATION}")
		;;
	copy)
		log "📥 Performing copy of ${SYNC_SOURCE_MASKED} -> ${SYNC_DESTINATION_MASKED}..."
		rclone_cmd=(rclone copy "${SYNC_SOURCE}" "${SYNC_DESTINATION}")
		;;
	esac
	rclone_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")

	# if/else captures rclone's exit code without aborting under `set -e`
	# so the recovery branch and per-job accounting can still run.
	if "${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		syncRC=0
	else
		syncRC=$?
	fi
	logLast "Finished ${SYNC_MODE} at $(date +"%Y-%m-%d %a %H:%M:%S")"

	# Error handling
	if [ $syncRC -eq 0 ]; then
		log "✅ ${SYNC_MODE^} Successful"
	else
		syncJobsFailed=$((syncJobsFailed + 1))
		errorlog "❌ ${SYNC_MODE^} Failed with Status ${syncRC}"
		copyErrorLog

		if [ "${SYNC_MODE}" != "bisync" ]; then
			# One-way modes have no safe automatic recovery; surface the failure.
			syncHasError=1
			if [ $overallRC -eq 0 ]; then
				overallRC=$syncRC
			fi
		else
			# Recovery procedure (bisync only).
			errorlog "🚨 Starting recovery procedure for ${SYNC_SOURCE_MASKED}..."

			# Step 1: Update destination from source
			log "🔄 Step 1: Updating from ${SYNC_SOURCE_MASKED} to ${SYNC_DESTINATION_MASKED}"
			rclone_copy_cmd=(rclone copy "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --update)
			rclone_copy_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
			if "${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
				copy1RC=0
			else
				copy1RC=$?
			fi
			if [ $copy1RC -ne 0 ]; then
				syncHasError=1
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy1RC
				fi
			fi

			# Step 2: Update source from destination
			log "🔄 Step 2: Updating from ${SYNC_DESTINATION_MASKED} to ${SYNC_SOURCE_MASKED}"
			rclone_copy_cmd=(rclone copy "${SYNC_DESTINATION}" "${SYNC_SOURCE}" --update)
			rclone_copy_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
			if "${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
				copy2RC=0
			else
				copy2RC=$?
			fi
			if [ $copy2RC -ne 0 ]; then
				syncHasError=1
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy2RC
				fi
			fi

			# Step 3: Resync if both copies were successful
			if [ $copy1RC -eq 0 ] && [ $copy2RC -eq 0 ]; then
				log "🔄 Step 3: Performing full resync between ${SYNC_SOURCE_MASKED} and ${SYNC_DESTINATION_MASKED}"
				rclone_cmd=(rclone bisync "${SYNC_SOURCE}" "${SYNC_DESTINATION}" --resync)
				rclone_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
				# --check-access also applies to the recovery resync.
				rclone_cmd+=("${SYNC_BISYNC_CHECK_ACCESS_ARRAY[@]}")
				if "${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
					syncRC=0
				else
					syncRC=$?
				fi

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

			log "📊 Recovery Exitcode Summary: Source→Dest=${copy1RC}, Dest→Source=${copy2RC}, Resync=${syncRC}"
		fi
	fi

	# Record end time
	end=$(date +%s)
	duration=$((end - job_start))
	minutes=$((duration / 60))
	seconds=$((duration % 60))

	log "🏁 Finished ${SYNC_MODE} at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

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

write_metrics_for_job "sync" "${overallRC}" "${syncRunStart}" "${syncRunEnd}" \
	"sync_jobs_processed" "${syncJobsProcessed}" \
	"sync_jobs_failed" "${syncJobsFailed}" || true

# Sync mails only when at least one job recorded an unrecoverable error
# (independent of MAILX_ON_ERROR), so force the error-only mode on notify_mail.
sync_subject_details="${syncJobsProcessed} jobs (${syncJobsFailed} failed)"
notify_mail "$(format_subject "Sync" "${overallRC}" "$((syncRunEnd - syncRunStart))" "${sync_subject_details}")" "${syncHasError}" "ON" || true

run_hook "post-sync" "$overallRC" || true

exit "$overallRC"
