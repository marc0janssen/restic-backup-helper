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
