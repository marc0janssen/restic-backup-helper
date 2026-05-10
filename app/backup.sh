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

run_hook "pre-backup"

# Record start time
start=$(date +%s)

# Note backup start
log "🔄 Starting Backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "BACKUP_CRON: ${BACKUP_CRON}"
logLast "BACKUP_ROOT_DIR: ${BACKUP_ROOT_DIR}"
logLast "RESTIC_TAG: ${RESTIC_TAG}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

if [ -z "${BACKUP_ROOT_DIR:-}" ] && [ -z "${RESTIC_JOB_ARGS:-}" ]; then
	log "⚠️ WARNING: BACKUP_ROOT_DIR and RESTIC_JOB_ARGS are both empty — restic will run without explicit backup paths (usually unintended). Set at least one of them."
fi

# Perform backup
if [ -n "${BACKUP_ROOT_DIR}" ]; then
	log "📦 Performing backup of ${BACKUP_ROOT_DIR}..."
elif [ -n "${RESTIC_JOB_ARGS}" ]; then
	log "📦 Performing backup using RESTIC_JOB_ARGS..."
else
	log "📦 Performing backup with restic defaults..."
fi

backup_cmd=(backup)

if [ -n "${RESTIC_JOB_ARGS}" ]; then
	read -r -a restic_job_args <<<"${RESTIC_JOB_ARGS}"
	backup_cmd+=("${restic_job_args[@]}")
fi

backup_cmd+=("--tag=${RESTIC_TAG?"Missing environment variable RESTIC_TAG"}")

if [ -n "${BACKUP_ROOT_DIR}" ]; then
	backup_cmd+=("${BACKUP_ROOT_DIR}")
fi

restic "${RESTIC_CACERT_ARGS[@]}" "${backup_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1
backupRC=$?
logLast "Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ "$backupRC" -eq 0 ]; then
	log "✅ Backup Successful"
else
	log "❌ Backup Failed with Status ${backupRC}"
	log "🔓 Unlocking repository..."
	restic "${RESTIC_CACERT_ARGS[@]}" unlock
	copyErrorLog
fi

# Execute forget if backup was successful and RESTIC_FORGET_ARGS is set
if [ "$backupRC" -eq 0 ] && [ -n "${RESTIC_FORGET_ARGS}" ]; then
	log "🧹 Forgetting old snapshots based on: ${RESTIC_FORGET_ARGS}"
	read -r -a forget_args <<<"${RESTIC_FORGET_ARGS}"
	restic "${RESTIC_CACERT_ARGS[@]}" forget "${forget_args[@]}" >>"${LAST_LOGFILE}" 2>&1
	rc=$?
	logLast "Finished forget at $(date +"%Y-%m-%d %a %H:%M:%S")"

	# Error handling for forget
	if [ "$rc" -eq 0 ]; then
		log "✅ Forget Successful"
	else
		log "❌ Forget Failed with Status ${rc}"
		log "🔓 Unlocking repository..."
		restic "${RESTIC_CACERT_ARGS[@]}" unlock
		copyErrorLog
	fi
fi

# Record end time
end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

# Persist a structured per-run summary for external monitoring.
write_last_run_json "backup" "${backupRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}" \
	"backup_root_dir" "${BACKUP_ROOT_DIR:-}" \
	"restic_tag" "${RESTIC_TAG:-}"

# Send mail notification (on failure if MAILX_ON_ERROR=ON, else always when MAILX_RCPT set)
if [ -n "${MAILX_RCPT}" ] && {
	[ "${MAILX_ON_ERROR^^}" != "ON" ] || { [ "${MAILX_ON_ERROR^^}" == "ON" ] && [ "$backupRC" -ne 0 ]; }
}; then
	log "📧 Sending email notification to ${MAILX_RCPT}..."
	if mail -v -s "Result of the last ${HOSTNAME} backup run on ${MASKED_REPO}" "${MAILX_RCPT}" <"${LAST_LOGFILE}" >"${LAST_MAIL_LOGFILE}" 2>&1; then
		log "✅ Mail notification successfully sent"
	else
		log "❌ Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
	fi
fi

run_hook "post-backup" "$backupRC" || true

exit "$backupRC"
