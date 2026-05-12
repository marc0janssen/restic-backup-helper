#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Forget Preview Script
# Description: Safe dry-run wrapper for restic forget using the configured
#              RESTIC_FORGET_ARGS retention policy.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/forget-preview-last.log"
LAST_ERROR_LOGFILE="/var/log/forget-preview-error-last.log"
LAST_MAIL_LOGFILE="/var/log/forget-preview-mail-last.log"

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
Usage: /bin/forget-preview [OPTIONS]

Preview the configured retention policy without deleting snapshots. The helper
always invokes `restic forget --dry-run`; it never runs a mutating forget.

Default scope:
  * Uses RESTIC_FORGET_ARGS as the retention policy.
  * Adds --host "$HOSTNAME" and --tag "$RESTIC_TAG" by default so multi-host
    repositories preview only this container's snapshots.

Options:
  --repo-wide        Do not add --host / --tag. Preview repository-wide
                     retention explicitly.
  --host HOST        Override the default host filter (default: $HOSTNAME).
  --tag TAG          Override the default tag filter (default: $RESTIC_TAG).
  --policy ARGS      Use these retention args instead of RESTIC_FORGET_ARGS.
                     Quote as one shell argument, e.g.
                     --policy "--keep-daily 7 --keep-weekly 4".
  --extra ARGS       Append extra restic forget args after the policy. Quote as
                     one shell argument.
  --help             Show this help.

Audit trail:
  * /var/log/forget-preview-last.log
  * /var/log/last-forget-preview.json
  * /hooks/pre-forget-preview.sh
  * /hooks/post-forget-preview.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing as
    backup/check/prune/replicate/restore.
EOF
}

REPO_WIDE="OFF"
HOST_FILTER="${HOSTNAME:-}"
TAG_FILTER="${RESTIC_TAG:-}"
POLICY_ARGS="${RESTIC_FORGET_ARGS:-}"
EXTRA_ARGS=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo-wide)
		REPO_WIDE="ON"
		shift
		;;
	--host)
		HOST_FILTER="${2:-}"
		shift 2
		;;
	--tag)
		TAG_FILTER="${2:-}"
		shift 2
		;;
	--policy)
		POLICY_ARGS="${2:-}"
		shift 2
		;;
	--extra)
		EXTRA_ARGS="${2:-}"
		shift 2
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/forget-preview --help for usage." >&2
		exit 2
		;;
	esac
done

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
forgetPreviewRC=0

log "🧹 Starting forget preview at $(date +"%Y-%m-%d %a %H:%M:%S")"
logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS:-}"
logLast "POLICY_ARGS: ${POLICY_ARGS}"
logLast "EXTRA_ARGS: ${EXTRA_ARGS}"
logLast "REPO_WIDE: ${REPO_WIDE}"
logLast "HOST_FILTER: ${HOST_FILTER:-}"
logLast "TAG_FILTER: ${TAG_FILTER:-}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"

run_hook "pre-forget-preview" || true

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	errorlog "❌ RESTIC_REPOSITORY is empty."
	forgetPreviewRC=2
fi

if [ "${forgetPreviewRC}" -eq 0 ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
	errorlog "❌ Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD."
	forgetPreviewRC=2
fi

if [ "${forgetPreviewRC}" -eq 0 ] && [ -z "${POLICY_ARGS}" ]; then
	errorlog "❌ No retention policy configured. Set RESTIC_FORGET_ARGS or pass --policy."
	forgetPreviewRC=2
fi

if [ "${forgetPreviewRC}" -eq 0 ] && [ "${REPO_WIDE}" != "ON" ]; then
	if [ -z "${HOST_FILTER}" ]; then
		errorlog "❌ Host filter is empty. Pass --host HOST or use --repo-wide for an explicit repository-wide preview."
		forgetPreviewRC=2
	fi
	if [ -z "${TAG_FILTER}" ]; then
		errorlog "❌ Tag filter is empty. Set RESTIC_TAG, pass --tag TAG, or use --repo-wide for an explicit repository-wide preview."
		forgetPreviewRC=2
	fi
fi

forget_cmd=(forget --dry-run)

if [ "${forgetPreviewRC}" -eq 0 ]; then
	read -r -a policy_words <<<"${POLICY_ARGS}"
	forget_cmd+=("${policy_words[@]}")

	if [ "${REPO_WIDE}" = "ON" ]; then
		log "⚠️ Running repository-wide retention preview (--repo-wide)."
	else
		forget_cmd+=(--host "${HOST_FILTER}" --tag "${TAG_FILTER}")
		log "🔎 Running host/tag-scoped retention preview (host='${HOST_FILTER}', tag='${TAG_FILTER}')."
	fi

	if [ -n "${EXTRA_ARGS}" ]; then
		read -r -a extra_words <<<"${EXTRA_ARGS}"
		forget_cmd+=("${extra_words[@]}")
	fi

	{
		printf 'About to run: restic'
		for word in "${RESTIC_CACERT_ARGS[@]}" "${forget_cmd[@]}"; do
			printf ' %q' "${word}"
		done
		printf '\n'
	} >>"${LAST_LOGFILE}"

	if restic "${RESTIC_CACERT_ARGS[@]}" "${forget_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		forgetPreviewRC=0
	else
		forgetPreviewRC=$?
	fi
	logLast "Finished forget preview at $(date +"%Y-%m-%d %a %H:%M:%S")"
fi

if [ "${forgetPreviewRC}" -eq 0 ]; then
	log "✅ Forget preview completed successfully"
else
	log "❌ Forget preview failed with Status ${forgetPreviewRC}"
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished forget preview at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"repo_wide" "${REPO_WIDE}"
	"policy_args" "${POLICY_ARGS}"
	"extra_args" "${EXTRA_ARGS}"
)
if [ "${REPO_WIDE}" != "ON" ]; then
	last_run_extras+=(
		"host_filter" "${HOST_FILTER}"
		"tag_filter" "${TAG_FILTER}"
	)
fi

write_last_run_json "forget-preview" "${forgetPreviewRC}" "${start}" "${end}" "${last_run_extras[@]}"

notify_webhook "forget-preview" "${forgetPreviewRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

write_metrics_for_job "forget_preview" "${forgetPreviewRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Forget preview" "${forgetPreviewRC}" "${duration}" "${MASKED_REPO}")" "${forgetPreviewRC}" || true

run_hook "post-forget-preview" "${forgetPreviewRC}" || true

exit "${forgetPreviewRC}"
