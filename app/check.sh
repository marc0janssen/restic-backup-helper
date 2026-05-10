#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Check Script
# Description: Script for verifying repository integrity with Restic
# =========================================================

set -Eeuo pipefail

# Define log files (kept on disk under their existing names; variable names are
# unified to LAST_LOGFILE / LAST_ERROR_LOGFILE so /bin/lib.sh helpers can be
# shared with /bin/backup and /bin/bisync).
LAST_LOGFILE="/var/log/check-last.log"
LAST_ERROR_LOGFILE="/var/log/check-error-last.log"
LAST_MAIL_LOGFILE="/var/log/check-mail-last.log"

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

# Pre-hook is informational; never abort the check on a failing pre-hook
# (matches historical behaviour before `set -e`).
run_hook "pre-check" || true

# Record start time
start=$(date +%s)

# Note check start
log "🔍 Starting Check at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Log environment variables
logLast "RELEASE: ${RELEASE}"
logLast "CHECK_CRON: ${CHECK_CRON:-}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS:-}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"

# Perform repository check
if [ -n "${RESTIC_CHECK_ARGS:-}" ]; then
	log "🔍 Verifying repository integrity using RESTIC_CHECK_ARGS..."
else
	log "🔍 Verifying repository integrity with restic defaults..."
fi

check_cmd=(check)

if [ -n "${RESTIC_CHECK_ARGS:-}" ]; then
	read -r -a restic_check_args <<<"${RESTIC_CHECK_ARGS}"
	check_cmd+=("${restic_check_args[@]}")
fi

# if/else captures restic's exit code without aborting under `set -e`.
if restic "${RESTIC_CACERT_ARGS[@]}" "${check_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	checkRC=0
else
	checkRC=$?
fi
logLast "Finished check at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Error handling
if [ "$checkRC" -eq 0 ]; then
	log "✅ Check Successful"
else
	log "❌ Check Failed with Status ${checkRC}"
	log "🔓 Unlocking repository..."
	restic "${RESTIC_CACERT_ARGS[@]}" unlock || true
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

# POST the same payload to WEBHOOK_URL when configured (no-op otherwise).
notify_webhook "check" "${checkRC}" "${start}" "${end}" \
	"repository" "${MASKED_REPO}" || true

notify_mail "Result of the last ${HOSTNAME:-} check run on ${MASKED_REPO}" "${checkRC}" || true

run_hook "post-check" "$checkRC" || true

exit "$checkRC"
