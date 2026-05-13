#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Forget Script (standalone)
# Description: Standalone `restic forget` runner so retention can be
#              scheduled independently from /bin/backup. When
#              FORGET_CRON is non-empty, /entry.sh appends a cron entry
#              that invokes this script via /bin/locked_run, and
#              /bin/backup skips its inline post-backup forget so the
#              repository's exclusive lock is only ever taken by this
#              dedicated maintenance window.
#
#              Mirrors /bin/prune (cheap-vs-expensive split): forget is
#              the cheap metadata-only operation that enforces retention
#              policy; prune is the expensive pack-reclaim that follows
#              on its own cadence via PRUNE_CRON. Splitting them lets
#              operators on shared (multi-host) repositories stagger
#              both the cron windows AND the exclusive-lock holders
#              instead of every host's backup racing for the same lock.
#
#              Reuses RESTIC_FORGET_ARGS verbatim so existing retention
#              policies move over unchanged. Exit code 11 (failed to
#              lock repository) is treated as a soft skip — same
#              rationale as the inline path in /bin/backup: the lock we
#              lose is another host's legitimate lock, never auto-unlock
#              on exit 11.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/forget-last.log"
LAST_ERROR_LOGFILE="/var/log/forget-error-last.log"
LAST_MAIL_LOGFILE="/var/log/forget-mail-last.log"

# shellcheck source=lib.sh
. /bin/lib.sh

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO=$(mask_repository "${RESTIC_REPOSITORY}")
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

build_restic_cacert_args

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

run_hook "pre-forget" || true

start=$(date +%s)

log "🧹 Starting Forget at $(date +"%Y-%m-%d %a %H:%M:%S")"

logLast "RELEASE: ${RELEASE}"
logLast "FORGET_CRON: ${FORGET_CRON:-}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS:-}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

if [ -z "${RESTIC_FORGET_ARGS:-}" ]; then
	errorlog "❌ No retention policy configured. Set RESTIC_FORGET_ARGS (e.g. '--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12') before scheduling FORGET_CRON; the standalone forget worker has nothing to do otherwise."
	forgetRC=2
	end=$(date +%s)
	duration=$((end - start))
	write_last_run_json "forget" "${forgetRC}" "${start}" "${end}" \
		"repository" "${MASKED_REPO}"
	notify_webhook "forget" "${forgetRC}" "${start}" "${end}" \
		"repository" "${MASKED_REPO}" || true
	write_metrics_for_job "forget" "${forgetRC}" "${start}" "${end}" || true
	notify_mail "$(format_subject "Forget" "${forgetRC}" "${duration}" "${MASKED_REPO}")" "${forgetRC}" || true
	run_hook "post-forget" "$forgetRC" || true
	exit "${forgetRC}"
fi

read -r -a forget_args <<<"${RESTIC_FORGET_ARGS}"
log "🧹 Forgetting old snapshots based on: ${RESTIC_FORGET_ARGS}"

# if/else captures restic's exit code without aborting under `set -e`.
if restic "${RESTIC_CACERT_ARGS[@]}" forget "${forget_args[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	forgetRC=0
else
	forgetRC=$?
fi
logLast "Finished forget at $(date +"%Y-%m-%d %a %H:%M:%S")"

case "${forgetRC}" in
0)
	log "✅ Forget Successful"
	;;
11)
	# Restic exit 11 = "failed to lock repository". On multi-host
	# repositories this is the benign race: another host already holds
	# the exclusive lock. Forget is cumulative so the next FORGET_CRON
	# tick catches up. Crucially do NOT auto-unlock: the lock that
	# blocked us is another host's legitimate lock. Recommend
	# '--retry-lock=DURATION' in RESTIC_FORGET_ARGS, and/or stagger
	# FORGET_CRON between hosts so the windows do not converge.
	log "⏭ Forget skipped: repository was locked by another host (exit 11). Retention will catch up on the next FORGET_CRON tick. Add '--retry-lock=5m' (or similar) to RESTIC_FORGET_ARGS to wait for the lock, and/or stagger FORGET_CRON between hosts."
	;;
*)
	log "❌ Forget Failed with Status ${forgetRC}"
	if should_auto_unlock; then
		log "🔓 Unlocking repository (RESTIC_AUTO_UNLOCK=ON)..."
		restic "${RESTIC_CACERT_ARGS[@]}" unlock || true
	else
		log "ℹ️ Skipping automatic 'restic unlock' (RESTIC_AUTO_UNLOCK!=ON). Inspect with 'restic list locks' and run 'restic unlock' manually if the lock is stale, or set RESTIC_AUTO_UNLOCK=ON to restore the previous default behaviour."
	fi
	copyErrorLog
	;;
esac

end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished forget at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

write_last_run_json "forget" "${forgetRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}"

notify_webhook "forget" "${forgetRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}" || true

write_metrics_for_job "forget" "${forgetRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Forget" "${forgetRC}" "${duration}" "${MASKED_REPO}")" "${forgetRC}" || true

run_hook "post-forget" "$forgetRC" || true

exit "$forgetRC"
