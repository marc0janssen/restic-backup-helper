#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Notify Test (operator-driven)
# Description: Explicit test wrapper for the same notify_mail and
#              notify_webhook helpers used by real jobs. Lets operators
#              validate msmtprc, MAILX_RCPT, WEBHOOK_URL, optional
#              Authorization headers and timeout handling before waiting
#              for a real backup failure.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/notify-test-last.log"
LAST_ERROR_LOGFILE="/var/log/notify-test-error-last.log"
LAST_MAIL_LOGFILE="/var/log/notify-test-mail-last.log"

# shellcheck source=app/lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

usage() {
	cat <<'EOF'
Usage: /bin/notify-test [OPTIONS]

Send clearly-labelled test mail and/or webhook notifications through the
same notify_mail / notify_webhook helpers used by real jobs. Delivery
failures DO affect this helper's exit code so operators can use it as a
real configuration check.

Default behaviour:
  * Sends to every configured target:
      - mail when MAILX_RCPT is set
      - webhook when WEBHOOK_URL is set
  * Fails with exit 2 when no target is configured.

Options:
  --mail           Test mail only. Fails with exit 2 when MAILX_RCPT is empty.
  --webhook        Test webhook only. Fails with exit 2 when WEBHOOK_URL is empty.
  --all            Test both configured targets (default). If both targets are
                   explicitly requested, missing config for either target is
                   an exit-2 configuration error.
  --dry-run        Print what would be sent without invoking mail or curl.
                   JSON / metrics / hooks are still written.
  --subject TEXT   Override the mail subject prefix / webhook detail.
                   Default: "Notify test".
  --message TEXT   Add an operator message to the log body and JSON payload.
  --help, -h       Show this help.

Audit trail:
  * /var/log/notify-test-last.log
  * /var/log/notify-test-mail-last.log
  * /var/log/last-notify-test.json
  * /hooks/pre-notify-test.sh
  * /hooks/post-notify-test.sh "$rc"
  * restic_notify_test.prom when METRICS_DIR is set

Exit codes:
  0  Requested test notification(s) delivered, or dry-run completed.
  1  At least one requested delivery failed (mailx / msmtp / curl).
  2  Configuration or argument error (no target, missing requested target).
EOF
}

TARGET_MODE="auto"
DRY_RUN="OFF"
SUBJECT_PREFIX="Notify test"
MESSAGE=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--mail)
		TARGET_MODE="mail"
		shift
		;;
	--webhook)
		TARGET_MODE="webhook"
		shift
		;;
	--all)
		TARGET_MODE="all"
		shift
		;;
	--dry-run)
		DRY_RUN="ON"
		shift
		;;
	--subject)
		[ -n "${2:-}" ] || {
			echo "❌ --subject needs a non-empty argument." >&2
			exit 2
		}
		SUBJECT_PREFIX="$2"
		shift 2
		;;
	--subject=*)
		SUBJECT_PREFIX="${1#*=}"
		shift
		;;
	--message)
		[ -n "${2:-}" ] || {
			echo "❌ --message needs a non-empty argument." >&2
			exit 2
		}
		MESSAGE="$2"
		shift 2
		;;
	--message=*)
		MESSAGE="${1#*=}"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/notify-test --help for usage." >&2
		exit 2
		;;
	esac
done

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
notifyTestRC=0

MAIL_CONFIGURED="OFF"
WEBHOOK_CONFIGURED="OFF"
SEND_MAIL="OFF"
SEND_WEBHOOK="OFF"
MAIL_RESULT="skipped"
WEBHOOK_RESULT="skipped"
MAIL_RC="0"
WEBHOOK_RC="0"

[ -n "${MAILX_RCPT:-}" ] && MAIL_CONFIGURED="ON"
[ -n "${WEBHOOK_URL:-}" ] && WEBHOOK_CONFIGURED="ON"

case "${TARGET_MODE}" in
auto)
	[ "${MAIL_CONFIGURED}" = "ON" ] && SEND_MAIL="ON"
	[ "${WEBHOOK_CONFIGURED}" = "ON" ] && SEND_WEBHOOK="ON"
	;;
all)
	SEND_MAIL="ON"
	SEND_WEBHOOK="ON"
	;;
mail)
	SEND_MAIL="ON"
	;;
webhook)
	SEND_WEBHOOK="ON"
	;;
esac

masked_webhook=""
if [ -n "${WEBHOOK_URL:-}" ]; then
	masked_webhook="$(mask_webhook_url "${WEBHOOK_URL}")"
fi

log "📣 Starting notify-test at $(date +"%Y-%m-%d %a %H:%M:%S")"
log "Release:              ${RELEASE}"
log "Target mode:          ${TARGET_MODE}"
log "Dry-run:              ${DRY_RUN}"
log "MAILX_RCPT:           ${MAILX_RCPT:-(empty)}"
log "MAILX_ON_ERROR:       ${MAILX_ON_ERROR:-OFF}"
log "WEBHOOK_URL:          ${masked_webhook:-(empty)}"
log "WEBHOOK_ON_ERROR:     ${WEBHOOK_ON_ERROR:-OFF}"
log "WEBHOOK_TIMEOUT:      ${WEBHOOK_TIMEOUT:-10}"
if [ -n "${WEBHOOK_HEADER_AUTH:-}" ]; then
	log "WEBHOOK_HEADER_AUTH:  set (value masked)"
else
	log "WEBHOOK_HEADER_AUTH:  (empty)"
fi
if [ -n "${MESSAGE}" ]; then
	log "Operator message:     ${MESSAGE}"
fi

run_hook "pre-notify-test" || true

if [ "${SEND_MAIL}" = "OFF" ] && [ "${SEND_WEBHOOK}" = "OFF" ]; then
	errorlog "❌ No notification target configured. Set MAILX_RCPT and/or WEBHOOK_URL, or pass --mail / --webhook with the matching env var."
	notifyTestRC=2
fi

if [ "${notifyTestRC}" -eq 0 ] && [ "${SEND_MAIL}" = "ON" ] && [ "${MAIL_CONFIGURED}" = "OFF" ]; then
	errorlog "❌ Mail test requested but MAILX_RCPT is empty."
	notifyTestRC=2
fi

if [ "${notifyTestRC}" -eq 0 ] && [ "${SEND_WEBHOOK}" = "ON" ] && [ "${WEBHOOK_CONFIGURED}" = "OFF" ]; then
	errorlog "❌ Webhook test requested but WEBHOOK_URL is empty."
	notifyTestRC=2
fi

if [ "${notifyTestRC}" -eq 0 ]; then
	log ""
	log "This is a clearly-labelled restic-backup-helper notification test."
	log "It was triggered manually by /bin/notify-test so operators can validate notification plumbing before waiting for a real worker event."
	log "Configured targets selected for this run:"
	log "  - mail:    ${SEND_MAIL}"
	log "  - webhook: ${SEND_WEBHOOK}"
fi

end_for_payload() {
	date +%s
}

build_extras() {
	local now="$1"
	local duration_so_far=$((now - start))
	NOTIFY_TEST_EXTRAS=(
		"target_mode" "${TARGET_MODE}"
		"dry_run" "${DRY_RUN}"
		"mail_requested" "${SEND_MAIL}"
		"webhook_requested" "${SEND_WEBHOOK}"
		"mail_configured" "${MAIL_CONFIGURED}"
		"webhook_configured" "${WEBHOOK_CONFIGURED}"
		"mail_result" "${MAIL_RESULT}"
		"webhook_result" "${WEBHOOK_RESULT}"
		"mail_rc" "${MAIL_RC}"
		"webhook_rc" "${WEBHOOK_RC}"
		"webhook_url" "${masked_webhook}"
		"webhook_auth_header_set" "$([ -n "${WEBHOOK_HEADER_AUTH:-}" ] && printf 'ON' || printf 'OFF')"
		"mail_on_error" "${MAILX_ON_ERROR:-OFF}"
		"webhook_on_error" "${WEBHOOK_ON_ERROR:-OFF}"
		"webhook_timeout" "${WEBHOOK_TIMEOUT:-10}"
		"subject" "${SUBJECT_PREFIX}"
		"message" "${MESSAGE}"
		"duration_so_far_seconds" "${duration_so_far}"
	)
}

if [ "${notifyTestRC}" -eq 0 ] && [ "${DRY_RUN}" = "ON" ]; then
	log "🧪 Dry-run mode: not invoking mail or webhook delivery."
	[ "${SEND_MAIL}" = "ON" ] && MAIL_RESULT="dry-run"
	[ "${SEND_WEBHOOK}" = "ON" ] && WEBHOOK_RESULT="dry-run"
fi

if [ "${notifyTestRC}" -eq 0 ] && [ "${DRY_RUN}" = "OFF" ] && [ "${SEND_WEBHOOK}" = "ON" ]; then
	log "📡 Sending webhook test through notify_webhook ..."
	WEBHOOK_RESULT="failed"
	build_extras "$(end_for_payload)"
	# Force the test webhook to send even when WEBHOOK_ON_ERROR=ON; the
	# original policy is still logged and captured in JSON.
	if WEBHOOK_ON_ERROR=OFF notify_webhook "notify-test" 0 "${start}" "$(end_for_payload)" "${NOTIFY_TEST_EXTRAS[@]}"; then
		WEBHOOK_RC=0
		WEBHOOK_RESULT="delivered"
	else
		WEBHOOK_RC=$?
		notifyTestRC=1
	fi
fi

if [ "${notifyTestRC}" -le 1 ] && [ "${DRY_RUN}" = "OFF" ] && [ "${SEND_MAIL}" = "ON" ]; then
	log "📧 Sending mail test through notify_mail ..."
	MAIL_RESULT="failed"
	mail_subject="$(format_subject "${SUBJECT_PREFIX}" 0 "$(($(date +%s) - start))" "manual notification plumbing test")"
	# Force the test mail to send even when MAILX_ON_ERROR=ON; the original
	# policy is logged and included in JSON, but this helper's job is to
	# validate delivery plumbing now, not wait for a synthetic failure.
	if notify_mail "${mail_subject}" 0 "OFF"; then
		MAIL_RC=0
		MAIL_RESULT="delivered"
	else
		MAIL_RC=$?
		notifyTestRC=1
	fi
fi

if [ "${notifyTestRC}" -eq 0 ]; then
	if [ "${DRY_RUN}" = "ON" ]; then
		log "✅ Notify-test dry-run completed."
	else
		log "✅ Notify-test completed: mail=${MAIL_RESULT}, webhook=${WEBHOOK_RESULT}."
	fi
else
	log "❌ Notify-test failed with Status ${notifyTestRC}: mail=${MAIL_RESULT} (rc=${MAIL_RC}), webhook=${WEBHOOK_RESULT} (rc=${WEBHOOK_RC})."
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished notify-test at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

build_extras "${end}"

write_last_run_json "notify-test" "${notifyTestRC}" "${start}" "${end}" "${NOTIFY_TEST_EXTRAS[@]}"

write_metrics_for_job "notify_test" "${notifyTestRC}" "${start}" "${end}" || true

run_hook "post-notify-test" "${notifyTestRC}" || true

exit "${notifyTestRC}"
