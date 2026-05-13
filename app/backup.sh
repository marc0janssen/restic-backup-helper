#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Script
# Description: Script for performing backups with Restic
# =========================================================

set -Eeuo pipefail

# Define log files
LAST_LOGFILE="/var/log/backup-last.log"
LAST_ERROR_LOGFILE="/var/log/backup-error-last.log"
LAST_MAIL_LOGFILE="/var/log/backup-mail-last.log"

# shellcheck source=lib.sh
. /bin/lib.sh

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO=$(mask_repository "${RESTIC_REPOSITORY}")
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

# Releasestring: ENV gezet bij image build (build-arg)
RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

# Build --cacert flags from RESTIC_CACERT (no-op when unset).
build_restic_cacert_args

# Clear log files
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Pre-hook is informational; never abort the backup on a failing pre-hook
# (matches historical behaviour before `set -e`).
run_hook "pre-backup" || true

# Record start time
start=$(date +%s)

# Note backup start
log "🔄 Starting Backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "BACKUP_CRON: ${BACKUP_CRON:-}"
logLast "BACKUP_ROOT_DIR: ${BACKUP_ROOT_DIR:-}"
logLast "RESTIC_TAG: ${RESTIC_TAG:-}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS:-}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS:-}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

if [ -z "${BACKUP_ROOT_DIR:-}" ] && [ -z "${RESTIC_JOB_ARGS:-}" ]; then
	log "⚠️ WARNING: BACKUP_ROOT_DIR and RESTIC_JOB_ARGS are both empty — restic will run without explicit backup paths (usually unintended). Set at least one of them."
fi

# Perform backup
if [ -n "${BACKUP_ROOT_DIR:-}" ]; then
	log "📦 Performing backup of ${BACKUP_ROOT_DIR}..."
elif [ -n "${RESTIC_JOB_ARGS:-}" ]; then
	log "📦 Performing backup using RESTIC_JOB_ARGS..."
else
	log "📦 Performing backup with restic defaults..."
fi

backup_cmd=(backup)

if [ -n "${RESTIC_JOB_ARGS:-}" ]; then
	read -r -a restic_job_args <<<"${RESTIC_JOB_ARGS}"
	backup_cmd+=("${restic_job_args[@]}")
fi

if [ -z "${RESTIC_TAG:-}" ]; then
	log "❌ RESTIC_TAG is unset or empty. Set it to a non-empty value (e.g. 'daily', '${HOSTNAME:-host}-data') so snapshots can be filtered by tag. Aborting backup."
	exit 2
fi
backup_cmd+=("--tag=${RESTIC_TAG}")

if [ -n "${BACKUP_ROOT_DIR:-}" ]; then
	backup_cmd+=("${BACKUP_ROOT_DIR}")
fi

# if/else captures restic's exit code without aborting under `set -e` —
# downstream forget / unlock / mail / webhook all need backupRC.
if restic "${RESTIC_CACERT_ARGS[@]}" "${backup_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	backupRC=0
else
	backupRC=$?
fi
logLast "Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ "$backupRC" -eq 0 ]; then
	log "✅ Backup Successful"
else
	log "❌ Backup Failed with Status ${backupRC}"
	if should_auto_unlock; then
		log "🔓 Unlocking repository (RESTIC_AUTO_UNLOCK=ON)..."
		restic "${RESTIC_CACERT_ARGS[@]}" unlock || true
	else
		log "ℹ️ Skipping automatic 'restic unlock' (RESTIC_AUTO_UNLOCK!=ON). Inspect with 'restic list locks' and run 'restic unlock' manually if the lock is stale, or set RESTIC_AUTO_UNLOCK=ON to restore the previous default behaviour."
	fi
	copyErrorLog
fi

# Execute forget if backup was successful, RESTIC_FORGET_ARGS is set,
# AND no standalone /bin/forget worker is scheduled. When FORGET_CRON
# is set, retention is owned by the dedicated worker so the repository's
# exclusive forget-lock is only ever taken by that maintenance window
# (key win on multi-host repos; see /bin/forget for the full rationale).
forgetRC=""
if [ "$backupRC" -eq 0 ] && [ -n "${RESTIC_FORGET_ARGS:-}" ] && [ -z "${FORGET_CRON:-}" ]; then
	log "🧹 Forgetting old snapshots based on: ${RESTIC_FORGET_ARGS}"
	read -r -a forget_args <<<"${RESTIC_FORGET_ARGS}"
	if restic "${RESTIC_CACERT_ARGS[@]}" forget "${forget_args[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		forgetRC=0
	else
		forgetRC=$?
	fi
	logLast "Finished forget at $(date +"%Y-%m-%d %a %H:%M:%S")"

	# Error handling for forget
	case "${forgetRC}" in
	0)
		log "✅ Forget Successful"
		;;
	11)
		# Restic exit 11 = "failed to lock repository". On multi-host
		# repositories this is a benign race: two hosts finish backup
		# at the same time, only one can hold the exclusive lock that
		# `forget` requires, the other one returns 11 immediately.
		# Forget is cumulative (retention catches up on the next
		# tick), so downgrade this to an actionable skip instead of
		# treating it as a hard failure. Crucially, DO NOT auto-unlock
		# here: the lock that blocked us is another host's legitimate
		# lock, and clearing it would let two hosts mutate the
		# repository concurrently. Recommend `--retry-lock=DURATION`
		# in RESTIC_FORGET_ARGS for operators who want to wait instead
		# of skipping.
		log "⏭ Forget skipped: repository was locked by another host (exit 11). Retention will catch up on the next backup tick. Add '--retry-lock=5m' (or similar) to RESTIC_FORGET_ARGS to wait for the lock instead of skipping."
		;;
	*)
		log "❌ Forget Failed with Status ${forgetRC}"
		if should_auto_unlock; then
			log "🔓 Unlocking repository (RESTIC_AUTO_UNLOCK=ON)..."
			restic "${RESTIC_CACERT_ARGS[@]}" unlock || true
		else
			log "ℹ️ Skipping automatic 'restic unlock' (RESTIC_AUTO_UNLOCK!=ON); see backup-failure log entry above for guidance."
		fi
		copyErrorLog
		;;
	esac
elif [ "$backupRC" -eq 0 ] && [ -n "${RESTIC_FORGET_ARGS:-}" ] && [ -n "${FORGET_CRON:-}" ]; then
	log "⏭ Skipping inline forget: FORGET_CRON is set ('${FORGET_CRON}'), retention is owned by the standalone /bin/forget worker. RESTIC_FORGET_ARGS reused verbatim there."
fi

# Record end time
end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished backup at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

parse_restic_backup_stats "${LAST_LOGFILE}"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"backup_root_dir" "${BACKUP_ROOT_DIR:-}"
	"restic_tag" "${RESTIC_TAG:-}"
)
if [ -n "${forgetRC}" ]; then
	# Expose the forget result separately so a skipped forget (exit 11
	# on multi-host repos) or a hard forget failure stays visible in
	# monitoring even when backupRC is 0. Reserved values: 0 = success,
	# 11 = skipped (locked by another host), other = restic error.
	last_run_extras+=("forget_exit_code" "${forgetRC}")
fi
if [ -n "${BACKUP_STATS_SNAPSHOT_ID}" ]; then
	last_run_extras+=("snapshot_id" "${BACKUP_STATS_SNAPSHOT_ID}")
fi
if [ -n "${BACKUP_STATS_FILES_NEW}" ]; then
	last_run_extras+=(
		"files_new" "${BACKUP_STATS_FILES_NEW}"
		"files_changed" "${BACKUP_STATS_FILES_CHANGED}"
		"files_unmodified" "${BACKUP_STATS_FILES_UNMODIFIED}"
	)
fi
if [ -n "${BACKUP_STATS_BYTES_ADDED}" ]; then
	last_run_extras+=(
		"bytes_added" "${BACKUP_STATS_BYTES_ADDED}"
		"bytes_stored" "${BACKUP_STATS_BYTES_STORED}"
	)
fi

write_last_run_json "backup" "${backupRC}" "${start}" "${end}" "${last_run_extras[@]}"

notify_webhook "backup" "${backupRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

write_metrics_for_job "backup" "${backupRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

# Build a richer mail subject: "[OK] Backup larak · 5m12s · 1.234 MiB new (snap a1b2c3d4)".
mail_details=""
if [ -n "${BACKUP_STATS_BYTES_ADDED}" ]; then
	mail_details+="${BACKUP_STATS_BYTES_ADDED} new"
elif [ -n "${BACKUP_STATS_FILES_NEW}" ]; then
	mail_details+="${BACKUP_STATS_FILES_NEW} new files"
fi
if [ -n "${BACKUP_STATS_SNAPSHOT_ID}" ]; then
	[ -n "${mail_details}" ] && mail_details+=" "
	mail_details+="(snap ${BACKUP_STATS_SNAPSHOT_ID:0:8})"
fi
[ -n "${mail_details}" ] || mail_details="${MASKED_REPO}"
notify_mail "$(format_subject "Backup" "${backupRC}" "${duration}" "${mail_details}")" "${backupRC}" || true

run_hook "post-backup" "$backupRC" || true

exit "$backupRC"
