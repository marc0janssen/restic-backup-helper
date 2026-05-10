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

# Write a per-job last-run JSON document to /var/log/last-<job>.json. Intended
# for external monitoring (no daemons or push gateways needed).
#
# Usage:
#   write_last_run_json <job> <exit_code> <start_epoch> <end_epoch> [extra_key extra_value ...]
#
# Always-included fields: job, hostname, release, started_at, finished_at,
# duration_seconds, exit_code. Extra positional pairs are added as string
# fields (already JSON-escaped) so callers can attach details such as
# "repository" (masked), "snapshot_id", "sync_jobs_processed", etc.
write_last_run_json() {
	local job="$1"
	local exit_code="$2"
	local start_epoch="$3"
	local end_epoch="$4"
	shift 4

	local target="/var/log/last-${job}.json"
	local tmp="${target}.tmp"
	local started finished duration release hostname
	started="$(iso8601_local "${start_epoch}")"
	finished="$(iso8601_local "${end_epoch}")"
	duration=$((end_epoch - start_epoch))
	release="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
	hostname="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"

	{
		printf '{\n'
		printf '  "job": "%s",\n' "$(json_escape "${job}")"
		printf '  "hostname": "%s",\n' "$(json_escape "${hostname}")"
		printf '  "release": "%s",\n' "$(json_escape "${release}")"
		printf '  "started_at": "%s",\n' "$(json_escape "${started}")"
		printf '  "finished_at": "%s",\n' "$(json_escape "${finished}")"
		printf '  "duration_seconds": %d,\n' "${duration}"
		# Optional string extras. Numbers should be passed as strings; consumers
		# can coerce. Keeps the writer dependency-free.
		while [ "$#" -ge 2 ]; do
			printf '  "%s": "%s",\n' "$(json_escape "$1")" "$(json_escape "$2")"
			shift 2
		done
		printf '  "exit_code": %d\n' "${exit_code}"
		printf '}\n'
	} >"${tmp}" && mv -f "${tmp}" "${target}"
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
