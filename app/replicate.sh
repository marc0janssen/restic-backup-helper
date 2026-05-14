#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Rclone replicate Script
# Description: Script for running rclone replication jobs (bisync/sync/copy)
# =========================================================

set -Eeuo pipefail

# Define log files
LAST_LOGFILE="/var/log/replicate-last.log"
LAST_ERROR_LOGFILE="/var/log/replicate-error-last.log"
LAST_MAIL_LOGFILE="/var/log/replicate-mail-last.log"

# shellcheck source=lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

# Clear log files before the run banner so operators only see the current tick.
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

REPLICATE_JOB_FILE="${REPLICATE_JOB_FILE:-/config/replicate_jobs.txt}"
REPLICATE_JOB_ARGS="${REPLICATE_JOB_ARGS:-}"
REPLICATE_CRON="${REPLICATE_CRON:-}"
REPLICATE_VERBOSE="${REPLICATE_VERBOSE:-ON}"
REPLICATE_BISYNC_CHECK_ACCESS="${REPLICATE_BISYNC_CHECK_ACCESS:-OFF}"
LOG_VERBOSE="${REPLICATE_VERBOSE}"

# Check if the file exists and is not empty
if [ ! -s "${REPLICATE_JOB_FILE:-}" ]; then
	errorlog "❌ The replicate job file is empty or does not exist"
	exit 1
fi

# Check if the file contains at least one line with a semicolon
if ! grep -q ".*;" "${REPLICATE_JOB_FILE}"; then
	errorlog "❌ The replicate job file does not contain semicolons for separation"
	exit 1
fi

# Pre-hook is informational; never abort the replicate batch on a failing pre-hook
# (matches historical behaviour before `set -e`).
run_hook "pre-replicate" || true

# Note replicate start
log "🔄 Starting Replicate at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "REPLICATE_CRON: ${REPLICATE_CRON:-}"
logLast "REPLICATE_JOB_FILE: ${REPLICATE_JOB_FILE}"
logLast "REPLICATE_JOB_ARGS: ${REPLICATE_JOB_ARGS:-}"

# Split the replicate job args into an array while stripping any --resync flag
REPLICATE_JOB_ARGS_ARRAY=()
if [[ -n "${REPLICATE_JOB_ARGS:-}" ]]; then
	read -r -a RAW_REPLICATE_JOB_ARGS <<<"${REPLICATE_JOB_ARGS}"
	for arg in "${RAW_REPLICATE_JOB_ARGS[@]}"; do
		[[ "${arg}" == "--resync" ]] && continue
		REPLICATE_JOB_ARGS_ARRAY+=("${arg}")
	done
	unset RAW_REPLICATE_JOB_ARGS
fi

# Optional opt-in safety flag for bisync. When ON, every routine bisync run is
# extended with `--check-access` so rclone aborts (instead of treating one side
# as "everything deleted") when the well-known marker file is missing on either
# side. See README "Bisync recovery hardening" for how to seed RCLONE_TEST.
REPLICATE_BISYNC_CHECK_ACCESS_ARRAY=()
if [[ "${REPLICATE_BISYNC_CHECK_ACCESS:-OFF}" =~ ^[Oo][Nn]$ ]]; then
	REPLICATE_BISYNC_CHECK_ACCESS_ARRAY=(--check-access)
	logLast "REPLICATE_BISYNC_CHECK_ACCESS: ON (--check-access added to bisync runs)"
fi

# Track replicate errors across all jobs
replicateHasError=0
overallRC=0
replicateJobsProcessed=0
replicateJobsFailed=0
replicateRunStart=$(date +%s)

# Perform replicate jobs
while IFS= read -r line; do
	job_start=$(date +%s)
	# Skip empty lines and comment lines
	[[ -z "${line}" || "${line}" == \#* ]] && continue
	replicateJobsProcessed=$((replicateJobsProcessed + 1))

	# Split the line at semicolons. Backwards-compatible: legacy two-column lines
	# (SOURCE;DESTINATION) still work; optional 3rd field selects MODE
	# (bisync|sync|copy), optional 4th field carries per-job extra rclone args
	# that are appended after the global REPLICATE_JOB_ARGS for this job only.
	REPLICATE_MODE=""
	REPLICATE_PER_JOB_ARGS=""
	IFS=';' read -r REPLICATE_SOURCE REPLICATE_DESTINATION REPLICATE_MODE REPLICATE_PER_JOB_ARGS <<<"${line}"

	if [ -z "${REPLICATE_SOURCE:-}" ] || [ -z "${REPLICATE_DESTINATION:-}" ]; then
		errorlog "⚠️ Invalid line: ${line}"
		replicateJobsFailed=$((replicateJobsFailed + 1))
		replicateHasError=1
		[ $overallRC -eq 0 ] && overallRC=2
		continue
	fi

	# Normalise mode and validate. Default to bisync to preserve historical behaviour.
	REPLICATE_MODE="${REPLICATE_MODE:-bisync}"
	REPLICATE_MODE="${REPLICATE_MODE,,}"
	case "${REPLICATE_MODE}" in
	bisync | sync | copy) ;;
	*)
		errorlog "⚠️ Invalid replicate mode '${REPLICATE_MODE}' for line: ${line} (allowed: bisync, sync, copy). Skipping."
		replicateJobsFailed=$((replicateJobsFailed + 1))
		replicateHasError=1
		[ $overallRC -eq 0 ] && overallRC=2
		continue
		;;
	esac

	# Build the per-job args array: global REPLICATE_JOB_ARGS + per-job EXTRA_ARGS.
	# Strip --resync from both because routine bisync runs must never resync
	# implicitly (the recovery branch adds it explicitly when warranted).
	PER_JOB_ARGS_ARRAY=("${REPLICATE_JOB_ARGS_ARRAY[@]}")
	if [ -n "${REPLICATE_PER_JOB_ARGS:-}" ]; then
		read -r -a RAW_PER_JOB <<<"${REPLICATE_PER_JOB_ARGS}"
		for arg in "${RAW_PER_JOB[@]}"; do
			[[ "${arg}" == "--resync" ]] && continue
			PER_JOB_ARGS_ARRAY+=("${arg}")
		done
		unset RAW_PER_JOB
	fi

	# Mask any inline credentials in source/destination before logging so a
	# config like `https://user:pass@host/path` does not leak to cron.log.
	REPLICATE_SOURCE_MASKED="$(mask_endpoint "${REPLICATE_SOURCE}")"
	REPLICATE_DESTINATION_MASKED="$(mask_endpoint "${REPLICATE_DESTINATION}")"

	case "${REPLICATE_MODE}" in
	bisync)
		log "🔀 Performing bisync of ${REPLICATE_SOURCE_MASKED} <-> ${REPLICATE_DESTINATION_MASKED}..."
		rclone_cmd=(rclone bisync "${REPLICATE_SOURCE}" "${REPLICATE_DESTINATION}")
		# --check-access opt-in only applies to bisync.
		rclone_cmd+=("${REPLICATE_BISYNC_CHECK_ACCESS_ARRAY[@]}")
		;;
	sync)
		log "➡️ Performing sync of ${REPLICATE_SOURCE_MASKED} -> ${REPLICATE_DESTINATION_MASKED}..."
		rclone_cmd=(rclone sync "${REPLICATE_SOURCE}" "${REPLICATE_DESTINATION}")
		;;
	copy)
		log "📥 Performing copy of ${REPLICATE_SOURCE_MASKED} -> ${REPLICATE_DESTINATION_MASKED}..."
		rclone_cmd=(rclone copy "${REPLICATE_SOURCE}" "${REPLICATE_DESTINATION}")
		;;
	esac
	rclone_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")

	# if/else captures rclone's exit code without aborting under `set -e`
	# so the recovery branch and per-job accounting can still run.
	if "${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		replicateRC=0
	else
		replicateRC=$?
	fi
	logLast "Finished ${REPLICATE_MODE} at $(date +"%Y-%m-%d %a %H:%M:%S")"

	# Error handling
	if [ $replicateRC -eq 0 ]; then
		log "✅ ${REPLICATE_MODE^} Successful"
	else
		replicateJobsFailed=$((replicateJobsFailed + 1))
		errorlog "❌ ${REPLICATE_MODE^} Failed with Status ${replicateRC}"
		copyErrorLog

		if [ "${REPLICATE_MODE}" != "bisync" ]; then
			# One-way modes have no safe automatic recovery; surface the failure.
			replicateHasError=1
			if [ $overallRC -eq 0 ]; then
				overallRC=$replicateRC
			fi
		else
			# Recovery procedure (bisync only).
			errorlog "🚨 Starting recovery procedure for ${REPLICATE_SOURCE_MASKED}..."

			# Step 1: Update destination from source
			log "🔄 Step 1: Updating from ${REPLICATE_SOURCE_MASKED} to ${REPLICATE_DESTINATION_MASKED}"
			rclone_copy_cmd=(rclone copy "${REPLICATE_SOURCE}" "${REPLICATE_DESTINATION}" --update)
			rclone_copy_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
			if "${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
				copy1RC=0
			else
				copy1RC=$?
			fi
			if [ $copy1RC -ne 0 ]; then
				replicateHasError=1
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy1RC
				fi
			fi

			# Step 2: Update source from destination
			log "🔄 Step 2: Updating from ${REPLICATE_DESTINATION_MASKED} to ${REPLICATE_SOURCE_MASKED}"
			rclone_copy_cmd=(rclone copy "${REPLICATE_DESTINATION}" "${REPLICATE_SOURCE}" --update)
			rclone_copy_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
			if "${rclone_copy_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
				copy2RC=0
			else
				copy2RC=$?
			fi
			if [ $copy2RC -ne 0 ]; then
				replicateHasError=1
				if [ $overallRC -eq 0 ]; then
					overallRC=$copy2RC
				fi
			fi

			# Step 3: Resync if both copies were successful
			if [ $copy1RC -eq 0 ] && [ $copy2RC -eq 0 ]; then
				log "🔄 Step 3: Performing full resync between ${REPLICATE_SOURCE_MASKED} and ${REPLICATE_DESTINATION_MASKED}"
				rclone_cmd=(rclone bisync "${REPLICATE_SOURCE}" "${REPLICATE_DESTINATION}" --resync)
				rclone_cmd+=("${PER_JOB_ARGS_ARRAY[@]}")
				# --check-access also applies to the recovery resync.
				rclone_cmd+=("${REPLICATE_BISYNC_CHECK_ACCESS_ARRAY[@]}")
				if "${rclone_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
					replicateRC=0
				else
					replicateRC=$?
				fi

				if [ $replicateRC -eq 0 ]; then
					errorlog "✅ Recovery Successful - All steps completed"
				else
					errorlog "❌ Recovery Failed - Resync failed with status ${replicateRC}"
					replicateHasError=1
					if [ $overallRC -eq 0 ]; then
						overallRC=$replicateRC
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

			log "📊 Recovery Exitcode Summary: Source→Dest=${copy1RC}, Dest→Source=${copy2RC}, Resync=${replicateRC}"
		fi
	fi

	# Record end time
	end=$(date +%s)
	duration=$((end - job_start))
	minutes=$((duration / 60))
	seconds=$((duration % 60))

	log "🏁 Finished ${REPLICATE_MODE} at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

done <"${REPLICATE_JOB_FILE}"

replicateRunEnd=$(date +%s)

# Persist a structured per-run summary for external monitoring.
write_last_run_json "replicate" "${overallRC}" "${replicateRunStart}" "${replicateRunEnd}" \
	"replicate_jobs_processed" "${replicateJobsProcessed}" \
	"replicate_jobs_failed" "${replicateJobsFailed}"

# POST the same payload to WEBHOOK_URL when configured (no-op otherwise).
notify_webhook "replicate" "${overallRC}" "${replicateRunStart}" "${replicateRunEnd}" \
	"replicate_jobs_processed" "${replicateJobsProcessed}" \
	"replicate_jobs_failed" "${replicateJobsFailed}" || true

write_metrics_for_job "replicate" "${overallRC}" "${replicateRunStart}" "${replicateRunEnd}" \
	"replicate_jobs_processed" "${replicateJobsProcessed}" \
	"replicate_jobs_failed" "${replicateJobsFailed}" || true

# Replicate mails only when at least one job recorded an unrecoverable error
# (independent of MAILX_ON_ERROR), so force the error-only mode on notify_mail.
replicate_subject_details="${replicateJobsProcessed} jobs (${replicateJobsFailed} failed)"
notify_mail "$(format_subject "Replicate" "${overallRC}" "$((replicateRunEnd - replicateRunStart))" "${replicate_subject_details}")" "${replicateHasError}" "ON" || true

run_hook "post-replicate" "$overallRC" || true

exit "$overallRC"
