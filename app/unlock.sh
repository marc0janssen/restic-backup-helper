#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Unlock Script (operator-driven)
# Description: Explicit, audited wrapper around `restic unlock`. Pairs with
#              the safer RESTIC_AUTO_UNLOCK=OFF default (since 1.12.0): the
#              workers no longer auto-clear locks on failure, so on
#              repositories shared by multiple hosts a legitimate concurrent
#              lock is never wiped behind your back. When you have
#              independently confirmed that a lock is stale (the holding
#              container is gone, the host is rebooted, etc.), run this
#              helper to remove it — same plumbing as the other operator
#              wrappers (masked log, last-*.json, restic_unlock.prom,
#              mail/webhook, pre-/post-unlock hooks).
#
#              `restic unlock` removes stale exclusive locks by default.
#              `--remove-all` widens the action to non-exclusive locks too;
#              use only when you have confirmed no other concurrent reader
#              (check, prune dry-run, mount) is in flight.
#
#              `--dry-run` only lists current locks; it does NOT call
#              `restic unlock`. Restic itself has no unlock --dry-run, so
#              this helper synthesises one by running `restic list locks`
#              and printing the IDs that would be removed.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/unlock-last.log"
LAST_ERROR_LOGFILE="/var/log/unlock-error-last.log"
LAST_MAIL_LOGFILE="/var/log/unlock-mail-last.log"

# shellcheck source=app/lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO="$(mask_repository "${RESTIC_REPOSITORY}")"
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

build_restic_cacert_args

usage() {
	cat <<'EOF'
Usage: /bin/unlock [OPTIONS]

Explicit manual `restic unlock` wrapper. Pairs with the safer
RESTIC_AUTO_UNLOCK=OFF default so workers never auto-clear another host's
legitimate lock; run this helper yourself once you have confirmed the lock
is stale.

Default scope:
  * Removes stale EXCLUSIVE locks (the same default as `restic unlock`).
  * Logs masked repository URL, lock counts before/after, exit code.

Options:
  --remove-all     Also remove non-exclusive locks (passes --remove-all to
                   `restic unlock`). Use only when no concurrent reader
                   (check, prune dry-run, mount, list, snapshot-export) is
                   in flight.
  --dry-run        Only list current locks via `restic list locks`; do NOT
                   call `restic unlock`. JSON / metrics / mail / webhook
                   are still produced so the audit trail is consistent.
  --help           Show this help.

Audit trail:
  * /var/log/unlock-last.log
  * /var/log/last-unlock.json
  * /hooks/pre-unlock.sh
  * /hooks/post-unlock.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing as
    backup/check/prune/forget/forget-preview/replicate/restore.

Examples:
  /bin/unlock                  # remove stale exclusive locks
  /bin/unlock --dry-run        # only list current locks (no removal)
  /bin/unlock --remove-all     # also remove non-exclusive locks
EOF
}

REMOVE_ALL="OFF"
DRY_RUN="OFF"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--remove-all)
		REMOVE_ALL="ON"
		shift
		;;
	--dry-run)
		DRY_RUN="ON"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/unlock --help for usage." >&2
		exit 2
		;;
	esac
done

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
unlockRC=0

log "🔓 Starting unlock at $(date +"%Y-%m-%d %a %H:%M:%S")"
logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "REMOVE_ALL: ${REMOVE_ALL}"
logLast "DRY_RUN: ${DRY_RUN}"
logLast "RESTIC_AUTO_UNLOCK: ${RESTIC_AUTO_UNLOCK:-OFF}"

run_hook "pre-unlock" || true

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	errorlog "❌ RESTIC_REPOSITORY is empty."
	unlockRC=2
fi

if [ "${unlockRC}" -eq 0 ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
	errorlog "❌ Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD."
	unlockRC=2
fi

# Count locks before; non-fatal if listing itself fails (e.g. password wrong,
# repo unreachable). The unlock call below will surface the real error.
count_locks() {
	local out
	if out="$(restic "${RESTIC_CACERT_ARGS[@]}" list locks 2>>"${LAST_LOGFILE}")"; then
		printf '%s\n' "${out}" | sed '/^$/d' | wc -l | tr -d ' '
	else
		printf '%s' "unknown"
	fi
}

LOCKS_BEFORE="unknown"
LOCKS_AFTER="unknown"

if [ "${unlockRC}" -eq 0 ]; then
	LOCKS_BEFORE="$(count_locks)"
	log "🔎 Locks before: ${LOCKS_BEFORE}"
fi

if [ "${unlockRC}" -eq 0 ] && [ "${DRY_RUN}" = "ON" ]; then
	log "🧪 Dry-run mode: not invoking 'restic unlock'."
	logLast "Would run: restic unlock $([ "${REMOVE_ALL}" = "ON" ] && echo "--remove-all" || echo "")"
	LOCKS_AFTER="${LOCKS_BEFORE}"
elif [ "${unlockRC}" -eq 0 ]; then
	unlock_cmd=(unlock)
	if [ "${REMOVE_ALL}" = "ON" ]; then
		unlock_cmd+=(--remove-all)
		log "⚠️ Removing ALL locks (including non-exclusive). Make sure no concurrent check / prune / mount / list / snapshot-export is in flight."
	else
		log "🔓 Removing stale exclusive locks (use --remove-all to also clear non-exclusive locks)."
	fi

	{
		printf 'About to run: restic'
		for word in "${RESTIC_CACERT_ARGS[@]}" "${unlock_cmd[@]}"; do
			printf ' %q' "${word}"
		done
		printf '\n'
	} >>"${LAST_LOGFILE}"

	if restic "${RESTIC_CACERT_ARGS[@]}" "${unlock_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		unlockRC=0
	else
		unlockRC=$?
	fi
	logLast "Finished unlock at $(date +"%Y-%m-%d %a %H:%M:%S")"
	LOCKS_AFTER="$(count_locks)"
fi

if [ "${unlockRC}" -eq 0 ]; then
	if [ "${DRY_RUN}" = "ON" ]; then
		log "✅ Unlock dry-run completed (locks=${LOCKS_BEFORE})"
	else
		log "✅ Unlock successful (locks ${LOCKS_BEFORE} → ${LOCKS_AFTER})"
	fi
else
	log "❌ Unlock failed with Status ${unlockRC}"
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished unlock at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"remove_all" "${REMOVE_ALL}"
	"dry_run" "${DRY_RUN}"
	"locks_before" "${LOCKS_BEFORE}"
	"locks_after" "${LOCKS_AFTER}"
)

write_last_run_json "unlock" "${unlockRC}" "${start}" "${end}" "${last_run_extras[@]}"

notify_webhook "unlock" "${unlockRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

write_metrics_for_job "unlock" "${unlockRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Unlock" "${unlockRC}" "${duration}" "${MASKED_REPO}")" "${unlockRC}" || true

run_hook "post-unlock" "${unlockRC}" || true

exit "${unlockRC}"
