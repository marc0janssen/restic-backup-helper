#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Prune Script
# Description: Standalone `restic prune` runner so retention can be scheduled
#              independently from the post-backup `restic forget`. When
#              PRUNE_CRON is non-empty, /entry.sh appends a cron entry that
#              invokes this script via /bin/locked_run.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/prune-last.log"
LAST_ERROR_LOGFILE="/var/log/prune-error-last.log"
LAST_MAIL_LOGFILE="/var/log/prune-mail-last.log"

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

# Pre-hook is informational; never abort the prune on a failing pre-hook.
run_hook "pre-prune" || true

start=$(date +%s)

log "🧹 Starting Prune at $(date +"%Y-%m-%d %a %H:%M:%S")"

logLast "RELEASE: ${RELEASE}"
logLast "PRUNE_CRON: ${PRUNE_CRON:-}"
logLast "RESTIC_PRUNE_ARGS: ${RESTIC_PRUNE_ARGS:-}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

prune_cmd=(prune)

if [ -n "${RESTIC_PRUNE_ARGS:-}" ]; then
	read -r -a restic_prune_args <<<"${RESTIC_PRUNE_ARGS}"
	prune_cmd+=("${restic_prune_args[@]}")
	log "🧹 Pruning repository using RESTIC_PRUNE_ARGS..."
else
	log "🧹 Pruning repository with restic defaults..."
fi

# if/else captures restic's exit code without aborting under `set -e`.
if restic "${RESTIC_CACERT_ARGS[@]}" "${prune_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	pruneRC=0
else
	pruneRC=$?
fi
logLast "Finished prune at $(date +"%Y-%m-%d %a %H:%M:%S")"

if [ "$pruneRC" -eq 0 ]; then
	log "✅ Prune Successful"
else
	log "❌ Prune Failed with Status ${pruneRC}"
	if should_auto_unlock; then
		log "🔓 Unlocking repository (RESTIC_AUTO_UNLOCK=ON)..."
		restic "${RESTIC_CACERT_ARGS[@]}" unlock || true
	else
		log "ℹ️ Skipping automatic 'restic unlock' (RESTIC_AUTO_UNLOCK!=ON). Inspect with 'restic list locks' and run 'restic unlock' manually if the lock is stale, or set RESTIC_AUTO_UNLOCK=ON to restore the previous default behaviour."
	fi
	copyErrorLog
fi

end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))

log "🏁 Finished prune at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

write_last_run_json "prune" "${pruneRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}"

notify_webhook "prune" "${pruneRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}" || true

write_metrics_for_job "prune" "${pruneRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Prune" "${pruneRC}" "${duration}" "${MASKED_REPO}")" "${pruneRC}" || true

run_hook "post-prune" "$pruneRC" || true

exit "$pruneRC"
