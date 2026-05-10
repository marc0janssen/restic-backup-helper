#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Check Script
# Description: Script for verifying repository integrity with Restic
# =========================================================

# Define log files (kept on disk under their existing names; variable names are
# unified to LAST_LOGFILE / LAST_ERROR_LOGFILE so /bin/lib.sh helpers can be
# shared with /bin/backup and /bin/bisync).
LAST_LOGFILE="/var/log/check-last.log"
LAST_ERROR_LOGFILE="/var/log/check-error-last.log"
LAST_MAIL_LOGFILE="/var/log/check-mail-last.log"

# shellcheck source=lib.sh
. /bin/lib.sh

if [ -n "${RESTIC_REPOSITORY}" ]; then
	MASKED_REPO=$(mask_repository "${RESTIC_REPOSITORY}")
else
	MASKED_REPO="${RESTIC_REPOSITORY}"
fi

# Releasestring: ENV gezet bij image build (build-arg)
RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

# Build --cacert flags from RESTIC_CACERT (no-op when unset).
build_restic_cacert_args

# Clear log files
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

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

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

# Perform repository check
if [ -n "${RESTIC_CHECK_ARGS}" ]; then
	log "🔍 Verifying repository integrity using RESTIC_CHECK_ARGS..."
else
	log "🔍 Verifying repository integrity with restic defaults..."
fi

check_cmd=(check)

if [ -n "${RESTIC_CHECK_ARGS}" ]; then
	read -r -a restic_check_args <<<"${RESTIC_CHECK_ARGS}"
	check_cmd+=("${restic_check_args[@]}")
fi

restic "${RESTIC_CACERT_ARGS[@]}" "${check_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
checkRC=$?
logLast "Finished check at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ "$checkRC" -eq 0 ]; then
	log "✅ Check Successful"
else
	log "❌ Check Failed with Status ${checkRC}"
	log "🔓 Unlocking repository..."
	restic "${RESTIC_CACERT_ARGS[@]}" unlock
	copyErrorLog
fi

# Record end time
end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished check at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

# Persist a structured per-run summary for external monitoring.
write_last_run_json "check" "${checkRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}"

# Send mail notification (on failure if MAILX_ON_ERROR=ON, else always when MAILX_RCPT set)
if [ -n "${MAILX_RCPT}" ] && {
	[ "${MAILX_ON_ERROR^^}" != "ON" ] || { [ "${MAILX_ON_ERROR^^}" == "ON" ] && [ "$checkRC" -ne 0 ]; }
}; then
	log "📧 Sending email notification to ${MAILX_RCPT}..."
	if mail -v -s "Result of the last ${HOSTNAME} check run on ${MASKED_REPO}" "${MAILX_RCPT}" <"${LAST_LOGFILE}" >"${LAST_MAIL_LOGFILE}" 2>&1; then
		log "✅ Mail notification successfully sent"
	else
		log "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
	fi
fi

# Check if post-check script exists and execute it
if [ -f "/hooks/post-check.sh" ]; then
	log "🚀 Starting post-check script..."
	/hooks/post-check.sh "$checkRC"
else
	log "ℹ️ Post-check script not found..."
fi

exit "$checkRC"
