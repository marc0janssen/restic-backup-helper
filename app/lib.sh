#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Shared runtime helpers sourced by /entry.sh, /bin/backup, /bin/check,
# /bin/bisync and /bin/rotate_log inside the container.
#
# Contract:
#   - Consumers set LAST_LOGFILE to the per-run log they want to append to.
#     log() and logLast() append to that file (no-op if unset).
#   - Consumers may set LAST_ERROR_LOGFILE; copyErrorLog() copies LAST_LOGFILE
#     to LAST_ERROR_LOGFILE when both are set.
#   - log() echoes to stdout when LOG_VERBOSE (default ON) is "ON" (case
#     insensitive). bisync sets LOG_VERBOSE from SYNC_VERBOSE so user-facing
#     verbosity keeps its existing semantics.
#   - errorlog() always echoes to stdout regardless of LOG_VERBOSE.
# =========================================================

# Mask repository credentials in URLs of the form scheme://user:password@host
# or backend:user:password@host. Returns the masked string on stdout.
mask_repository() {
	local repo="$1"
	local rest="$repo"
	local masked=""
	local before after last_part prefix

	while [[ "$rest" == *"@"* ]]; do
		before="${rest%%@*}"
		after="${rest#*@}"
		last_part="${before##*/}"

		if [[ "$before" == *":"* && "$last_part" == *":"* ]]; then
			prefix="${before%:*}"
			masked+="${prefix}:***@"
		else
			masked+="${before}@"
		fi

		rest="$after"
	done

	masked+="$rest"
	printf '%s' "$masked"
}

# Append a message to the configured per-run log file (no-op if unset).
logLast() {
	[ -n "${LAST_LOGFILE:-}" ] || return 0
	echo "$1" >>"${LAST_LOGFILE}"
}

# Echo to stdout (when LOG_VERBOSE=ON, default ON) and append to LAST_LOGFILE.
log() {
	local message="$1"
	local verbose="${LOG_VERBOSE:-ON}"
	if [[ "${verbose^^}" == "ON" ]]; then
		echo "${message}"
	fi
	logLast "${message}"
}

# Always echo to stdout and append to LAST_LOGFILE; used for errors that should
# never be suppressed by LOG_VERBOSE.
errorlog() {
	local message="$1"
	echo "${message}"
	logLast "${message}"
}

# Copy the current run log to its error-archive copy. Uses LAST_LOGFILE and
# LAST_ERROR_LOGFILE by default; both can be overridden positionally.
copyErrorLog() {
	local src="${1:-${LAST_LOGFILE:-}}"
	local dst="${2:-${LAST_ERROR_LOGFILE:-}}"
	if [ -n "${src}" ] && [ -n "${dst}" ] && [ -f "${src}" ]; then
		cp "${src}" "${dst}"
	fi
}

# JSON-escape a string for inclusion as a JSON value. Handles backslash, quote
# and the ASCII control range so callers do not need to depend on jq inside the
# image. Multi-byte UTF-8 sequences are passed through as-is (valid JSON).
json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\b'/\\b}"
	s="${s//$'\f'/\\f}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

# Format an epoch seconds value as ISO 8601 in the container's timezone.
iso8601_local() {
	date -d "@$1" +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"
}

# Render the per-job last-run JSON document to stdout. Shared between
# write_last_run_json (file sink) and notify_webhook (HTTP sink) so both
# surfaces stay in sync.
#
# Usage:
#   render_last_run_json <job> <exit_code> <start_epoch> <end_epoch> [extra_key extra_value ...]
#
# Always-included fields: job, hostname, release, started_at, finished_at,
# duration_seconds, exit_code. Extra positional pairs are added as string
# fields (JSON-escaped) so callers can attach details such as "repository"
# (masked), "snapshot_id", "sync_jobs_processed", etc.
render_last_run_json() {
	local job="$1"
	local exit_code="$2"
	local start_epoch="$3"
	local end_epoch="$4"
	shift 4

	local started finished duration release hostname
	started="$(iso8601_local "${start_epoch}")"
	finished="$(iso8601_local "${end_epoch}")"
	duration=$((end_epoch - start_epoch))
	release="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
	hostname="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

	printf '{\n'
	printf '  "job": "%s",\n' "$(json_escape "${job}")"
	printf '  "hostname": "%s",\n' "$(json_escape "${hostname}")"
	printf '  "release": "%s",\n' "$(json_escape "${release}")"
	printf '  "started_at": "%s",\n' "$(json_escape "${started}")"
	printf '  "finished_at": "%s",\n' "$(json_escape "${finished}")"
	printf '  "duration_seconds": %d,\n' "${duration}"
	# Optional string extras. Numbers should be passed as strings; consumers
	# can coerce. Keeps the renderer dependency-free.
	while [ "$#" -ge 2 ]; do
		printf '  "%s": "%s",\n' "$(json_escape "$1")" "$(json_escape "$2")"
		shift 2
	done
	printf '  "exit_code": %d\n' "${exit_code}"
	printf '}\n'
}

# Write a per-job last-run JSON document to /var/log/last-<job>.json (atomic
# tmp+mv). See render_last_run_json for the field schema.
write_last_run_json() {
	local job="$1"
	local target="/var/log/last-${job}.json"
	local tmp="${target}.tmp"
	render_last_run_json "$@" >"${tmp}" && mv -f "${tmp}" "${target}"
}

# Mask a webhook URL down to scheme+host for log messages so per-recipient
# secrets in path/query (healthchecks.io UUIDs, Slack webhook tokens, ntfy
# topic names, ...) never end up in container logs.
mask_webhook_url() {
	local url="$1"
	local masked
	masked="$(printf '%s' "${url}" | sed -nE 's#^(https?://[^/?#]+).*#\1/...#p')"
	if [ -n "${masked}" ]; then
		printf '%s' "${masked}"
	else
		printf '***'
	fi
}

# POST the same JSON document as write_last_run_json to WEBHOOK_URL. No-op
# when WEBHOOK_URL is unset. Honours WEBHOOK_ON_ERROR (only fire on non-zero
# exit when set to ON), WEBHOOK_TIMEOUT (curl --max-time, default 10s) and
# the optional WEBHOOK_HEADER_AUTH (added as Authorization header). Curl
# failures are logged as errors but never propagate to the worker exit code.
notify_webhook() {
	local job="$1"
	local exit_code="$2"
	local url="${WEBHOOK_URL:-}"
	local on_error="${WEBHOOK_ON_ERROR:-OFF}"
	local timeout="${WEBHOOK_TIMEOUT:-10}"
	local payload curl_args=() curl_output curl_rc masked

	if [ -z "${url}" ]; then
		return 0
	fi
	if [[ "${on_error^^}" == "ON" ]] && [ "${exit_code}" -eq 0 ]; then
		return 0
	fi
	if [[ ! "${timeout}" =~ ^[1-9][0-9]*$ ]]; then
		errorlog "⚠️ WEBHOOK_TIMEOUT='${timeout}' is not a positive integer; using 10s."
		timeout=10
	fi

	payload="$(render_last_run_json "$@")"
	masked="$(mask_webhook_url "${url}")"

	curl_args=(
		--silent --show-error --fail
		--max-time "${timeout}"
		--header "Content-Type: application/json"
		--data "${payload}"
	)
	if [ -n "${WEBHOOK_HEADER_AUTH:-}" ]; then
		curl_args+=(--header "Authorization: ${WEBHOOK_HEADER_AUTH}")
		log "📡 Posting ${job} webhook to ${masked} (timeout ${timeout}s, auth header set)..."
	else
		log "📡 Posting ${job} webhook to ${masked} (timeout ${timeout}s)..."
	fi

	if curl_output="$(curl "${curl_args[@]}" "${url}" 2>&1)"; then
		curl_rc=0
		log "✅ Webhook delivered (HTTP 2xx)"
	else
		curl_rc=$?
		errorlog "❌ Webhook delivery to ${masked} failed (curl exit ${curl_rc}): ${curl_output}"
	fi
	return "${curl_rc}"
}

# Send a mail notification for a worker run via msmtp/mailx. Honours MAILX_RCPT
# (no-op when unset) and MAILX_ON_ERROR (when set to ON, only mail on non-zero
# exit_code). Uses LAST_LOGFILE as the mail body (must already be populated by
# the caller) and LAST_MAIL_LOGFILE to capture mailx's verbose stderr/stdout.
#
# Usage:
#   notify_mail <subject> <exit_code> [error_only_override]
#
# The caller is responsible for masking sensitive values in the subject. Mail
# delivery failures are logged but never propagate to the worker exit code so a
# misconfigured msmtp / unreachable relay cannot turn an otherwise-successful
# backup into a failed one.
#
# error_only_override (optional, third positional arg): when set to "ON" the
# helper behaves as if MAILX_ON_ERROR=ON regardless of the env value. This
# preserves the historical bisync semantics ("mail only when at least one job
# failed irrecoverably") without requiring a global env flip per worker.
notify_mail() {
	local subject="$1"
	local exit_code="$2"
	local on_error="${3:-${MAILX_ON_ERROR:-OFF}}"
	local rcpt="${MAILX_RCPT:-}"
	local mail_log="${LAST_MAIL_LOGFILE:-/dev/null}"

	if [ -z "${rcpt}" ]; then
		return 0
	fi
	if [[ "${on_error^^}" == "ON" ]] && [ "${exit_code}" -eq 0 ]; then
		return 0
	fi
	if [ -z "${LAST_LOGFILE:-}" ] || [ ! -f "${LAST_LOGFILE}" ]; then
		errorlog "❌ notify_mail: LAST_LOGFILE is unset or missing; cannot send mail."
		return 1
	fi

	log "📧 Sending email notification to ${rcpt}..."
	if mail -v -s "${subject}" "${rcpt}" <"${LAST_LOGFILE}" >"${mail_log}" 2>&1; then
		log "✅ Mail notification successfully sent"
		return 0
	else
		local rc=$?
		errorlog "❌ Sending mail notification FAILED. Check ${mail_log} for further information."
		return "${rc}"
	fi
}

# Run an optional /hooks/<phase>.sh script with consistent logging and an
# optional timeout. Returns 0 (and logs an info message) when the hook script
# does not exist, so callers do not need pre-existence checks.
#
# Usage:
#   run_hook <phase> [arg ...]
#
# Behaviour:
#   - Hook path: /hooks/<phase>.sh
#   - When HOOK_TIMEOUT is unset, empty or 0: run without a timeout (unchanged
#     historical behaviour).
#   - When HOOK_TIMEOUT is a positive integer: wrap the hook in `timeout
#     ${HOOK_TIMEOUT}s`. The `timeout` exit code 124 (timed out) is logged
#     prominently as an error.
#   - Logs hook start, exit code and duration via log()/errorlog().
run_hook() {
	local phase="$1"
	shift
	local hook="/hooks/${phase}.sh"
	local hook_timeout="${HOOK_TIMEOUT:-0}"
	local hook_start hook_end hook_duration hook_rc

	if [ ! -f "${hook}" ]; then
		log "ℹ️ Hook ${phase} not found (${hook})"
		return 0
	fi
	if [ ! -x "${hook}" ]; then
		errorlog "❌ Hook ${phase} is not executable (${hook}); skipping."
		return 126
	fi

	if [[ ! "${hook_timeout}" =~ ^[0-9]+$ ]]; then
		errorlog "⚠️ HOOK_TIMEOUT='${hook_timeout}' is not a non-negative integer; running ${phase} without a timeout."
		hook_timeout="0"
	fi

	hook_start=$(date +%s)
	# Use if/else so callers running with `set -e` do not abort on a
	# non-zero hook exit before we capture its rc and log the duration.
	if [ "${hook_timeout}" -gt 0 ]; then
		log "🚀 Running hook ${phase} (timeout ${hook_timeout}s)..."
		if timeout "${hook_timeout}s" "${hook}" "$@"; then
			hook_rc=0
		else
			hook_rc=$?
		fi
	else
		log "🚀 Running hook ${phase}..."
		if "${hook}" "$@"; then
			hook_rc=0
		else
			hook_rc=$?
		fi
	fi
	hook_end=$(date +%s)
	hook_duration=$((hook_end - hook_start))

	if [ "${hook_rc}" -eq 0 ]; then
		log "✅ Hook ${phase} completed in ${hook_duration}s (exit 0)"
	elif [ "${hook_rc}" -eq 124 ] && [ "${hook_timeout}" -gt 0 ]; then
		errorlog "❌ Hook ${phase} timed out after ${hook_timeout}s (exit 124, ran ${hook_duration}s)"
	else
		errorlog "❌ Hook ${phase} failed in ${hook_duration}s (exit ${hook_rc})"
	fi

	return "${hook_rc}"
}

# Parse a `restic backup` text-format log into the BACKUP_STATS_* globals so
# callers can attach the values to last-run.json / webhook payloads. The
# function always defines all globals (empty when not found) so callers can
# safely test with `[ -n "${BACKUP_STATS_*}" ]`.
#
# Captured fields (best-effort, restic 0.13+ text format; survives missing
# lines from failed runs):
#   - BACKUP_STATS_SNAPSHOT_ID         e.g. "abc12345" from "snapshot abc12345 saved"
#   - BACKUP_STATS_FILES_NEW           integer
#   - BACKUP_STATS_FILES_CHANGED       integer
#   - BACKUP_STATS_FILES_UNMODIFIED    integer
#   - BACKUP_STATS_BYTES_ADDED         human string with unit, e.g. "1.234 MiB"
#   - BACKUP_STATS_BYTES_STORED        human string with unit (deduplicated)
#
# Bytes are kept as restic's pre-formatted strings to avoid losing the unit
# and to keep the helper jq-free; downstream consumers can re-parse if they
# need raw integers.
parse_restic_backup_stats() {
	local log="$1"
	BACKUP_STATS_SNAPSHOT_ID=""
	BACKUP_STATS_FILES_NEW=""
	BACKUP_STATS_FILES_CHANGED=""
	BACKUP_STATS_FILES_UNMODIFIED=""
	BACKUP_STATS_BYTES_ADDED=""
	BACKUP_STATS_BYTES_STORED=""

	[ -n "${log}" ] && [ -f "${log}" ] || return 0

	# `|| true` keeps the helper safe when the caller has `set -o pipefail`
	# and grep finds no matches (returns 1) for a partial / failed run.
	local line

	line="$(grep -E 'snapshot [a-f0-9]+ saved' "${log}" 2>/dev/null | tail -n 1 || true)"
	if [ -n "${line}" ]; then
		BACKUP_STATS_SNAPSHOT_ID="$(printf '%s' "${line}" | sed -nE 's/.*snapshot ([a-f0-9]+) saved.*/\1/p')"
	fi

	line="$(grep -E '^Files:[[:space:]]+[0-9]+ new,' "${log}" 2>/dev/null | tail -n 1 || true)"
	if [ -n "${line}" ]; then
		BACKUP_STATS_FILES_NEW="$(printf '%s' "${line}" | sed -nE 's/^Files:[[:space:]]+([0-9]+) new,[[:space:]]+([0-9]+) changed,[[:space:]]+([0-9]+) unmodified.*/\1/p')"
		BACKUP_STATS_FILES_CHANGED="$(printf '%s' "${line}" | sed -nE 's/^Files:[[:space:]]+([0-9]+) new,[[:space:]]+([0-9]+) changed,[[:space:]]+([0-9]+) unmodified.*/\2/p')"
		BACKUP_STATS_FILES_UNMODIFIED="$(printf '%s' "${line}" | sed -nE 's/^Files:[[:space:]]+([0-9]+) new,[[:space:]]+([0-9]+) changed,[[:space:]]+([0-9]+) unmodified.*/\3/p')"
	fi

	line="$(grep -E '^Added to the repository:' "${log}" 2>/dev/null | tail -n 1 || true)"
	if [ -n "${line}" ]; then
		BACKUP_STATS_BYTES_ADDED="$(printf '%s' "${line}" | sed -nE 's/^Added to the repository:[[:space:]]+(.+)[[:space:]]+\((.+) stored\).*/\1/p')"
		BACKUP_STATS_BYTES_STORED="$(printf '%s' "${line}" | sed -nE 's/^Added to the repository:[[:space:]]+(.+)[[:space:]]+\((.+) stored\).*/\2/p')"
	fi
}

# Populate the global RESTIC_CACERT_ARGS array with --cacert flags derived from
# the RESTIC_CACERT environment variable. Empty array when RESTIC_CACERT is
# unset; warns (without aborting) when set but the file is not readable so the
# downstream restic invocation surfaces its own TLS error.
build_restic_cacert_args() {
	RESTIC_CACERT_ARGS=()
	if [ -z "${RESTIC_CACERT:-}" ]; then
		return 0
	fi
	if [ -r "${RESTIC_CACERT}" ]; then
		RESTIC_CACERT_ARGS=(--cacert "${RESTIC_CACERT}")
	else
		errorlog "⚠️ RESTIC_CACERT is set but file is not readable: ${RESTIC_CACERT}; --cacert flag not added."
	fi
}
