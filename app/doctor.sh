#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Doctor Script
# Description: Read-only operator diagnostics for common runtime issues.
#              Supports two output modes:
#                * text (default) — human-readable sections + summary line.
#                * --json         — single JSON document on stdout for CI /
#                                   Kubernetes / monitoring consumers.
#                                   Schema "restic-backup-helper.doctor/1";
#                                   adding fields is MINOR, renaming/removing
#                                   fields is MAJOR.
# =========================================================

set -Eeuo pipefail

# shellcheck source=app/lib.sh
. /bin/lib.sh

JSON_MODE=false
case "${1:-}" in
--json | -j)
	JSON_MODE=true
	shift
	;;
-h | --help)
	cat <<'USAGE'
Usage: doctor [--json|-j]

Read-only diagnostics covering runtime versions, masked environment, config
checks, a non-mutating repository probe, replicate job validation, hooks and
the most recent per-worker JSON summaries.

Modes:
  (default)      Human-readable sections + a final "warnings / errors" summary.
  --json, -j     Emit a single JSON document on stdout (schema
                 "restic-backup-helper.doctor/1"). Top-level fields:
                   schema, command, release, hostname, generated_at,
                   generated_epoch, warnings, errors, exit_code,
                   runtime{}, environment{}, repository_probe{},
                   replicate{}, hooks{}, recent_json[], checks[].

Exit code: 0 when no errors, 1 when at least one fail was recorded
(identical in text and JSON mode).
USAGE
	exit 0
	;;
esac

WARNINGS=0
ERRORS=0
CURRENT_SECTION=""

# Accumulators populated alongside text output. Used unconditionally so the two
# render paths stay aligned (the only difference is which sink is flushed at
# the end).
JSON_CHECKS=()
JSON_RUNTIME_KEYS=()
JSON_RUNTIME_VALS=()
JSON_ENV_KEYS=()
JSON_ENV_VALS=()
JSON_REPO_PROBE_STATUS=""
JSON_REPO_PROBE_RC=""
JSON_REPLICATE_KEYS=()
JSON_REPLICATE_VALS=()
JSON_REPLICATE_JOBS_COUNT=0
JSON_REPLICATE_MALFORMED_COUNT=0
JSON_HOOKS_TIMEOUT=""
JSON_HOOKS_DIR_MOUNTED=true
JSON_HOOKS_PRESENT=() # "phase|true|false"
JSON_RECENT_JSON=()   # "path|true|N" or "path|false|0"

section() {
	CURRENT_SECTION="$1"
	${JSON_MODE} || printf '\n== %s ==\n' "$1"
}

# Append a structured finding to the JSON checks accumulator. Caller is one of
# info/ok/warn/fail and we record the current section so consumers can group
# without re-parsing the message.
record_check() {
	local status="$1" msg="$2"
	JSON_CHECKS+=("{\"section\":\"$(json_escape "${CURRENT_SECTION}")\",\"status\":\"${status}\",\"message\":\"$(json_escape "${msg}")\"}")
}

info() {
	${JSON_MODE} || printf '[INFO] %s\n' "$1"
	record_check "info" "$1"
}

ok() {
	${JSON_MODE} || printf '[OK] %s\n' "$1"
	record_check "ok" "$1"
}

warn() {
	WARNINGS=$((WARNINGS + 1))
	${JSON_MODE} || printf '[WARN] %s\n' "$1"
	record_check "warn" "$1"
}

fail() {
	ERRORS=$((ERRORS + 1))
	${JSON_MODE} || printf '[FAIL] %s\n' "$1"
	record_check "fail" "$1"
}

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
}

# Print a key/value pair in text mode AND capture it into the right
# JSON accumulator based on the current section.
print_kv() {
	${JSON_MODE} || printf '  %-34s %s\n' "$1:" "$2"
	case "${CURRENT_SECTION}" in
	"Runtime")
		JSON_RUNTIME_KEYS+=("$1")
		JSON_RUNTIME_VALS+=("$2")
		;;
	"Effective environment")
		JSON_ENV_KEYS+=("$1")
		JSON_ENV_VALS+=("$2")
		;;
	"Replicate")
		JSON_REPLICATE_KEYS+=("$1")
		JSON_REPLICATE_VALS+=("$2")
		;;
	"Hooks")
		if [ "$1" = "HOOK_TIMEOUT" ]; then
			JSON_HOOKS_TIMEOUT="$2"
		fi
		;;
	esac
}

masked_env_value() {
	local name="$1"
	local value="${!name:-}"

	case "${name}" in
	RESTIC_PASSWORD | OS_PASSWORD | WEBHOOK_HEADER_AUTH)
		if [ -n "${value}" ]; then
			printf '<set, hidden>'
		else
			printf '<empty>'
		fi
		;;
	RESTIC_REPOSITORY)
		mask_repository "${value}"
		;;
	WEBHOOK_URL)
		if [ -n "${value}" ]; then
			mask_webhook_url "${value}"
		else
			printf '<empty>'
		fi
		;;
	*)
		if [ -n "${value}" ]; then
			printf '%s' "${value}"
		else
			printf '<empty>'
		fi
		;;
	esac
}

check_readable_file() {
	local label="$1"
	local path="$2"

	if [ -z "${path}" ]; then
		info "${label}: not configured"
	elif [ -r "${path}" ]; then
		ok "${label}: readable (${path})"
	else
		fail "${label}: not readable (${path})"
	fi
}

check_optional_readable_file() {
	local label="$1"
	local path="$2"

	if [ -z "${path}" ]; then
		info "${label}: not configured"
	elif [ -r "${path}" ]; then
		ok "${label}: readable (${path})"
	else
		warn "${label}: not readable (${path})"
	fi
}

check_writable_dir() {
	local label="$1"
	local path="$2"

	if [ -z "${path}" ]; then
		info "${label}: not configured"
	elif [ -d "${path}" ] && [ -w "${path}" ]; then
		ok "${label}: writable (${path})"
	elif [ -d "${path}" ]; then
		warn "${label}: exists but is not writable (${path})"
	else
		warn "${label}: directory missing (${path})"
	fi
}

# Capture the first line of `cmd --version` output. Also recorded into the
# runtime JSON object so the doctor JSON has a single typed home for
# `restic_version`, `rclone_version`, `bash_version`.
report_command_version() {
	local label="$1"
	shift
	local output rc
	if output="$("$@" 2>&1 | sed -n '1p')"; then
		rc=0
		ok "${label}: ${output}"
		JSON_RUNTIME_KEYS+=("${label}_version")
		JSON_RUNTIME_VALS+=("${output}")
	else
		rc=$?
		warn "${label}: unavailable (exit ${rc})"
		JSON_RUNTIME_KEYS+=("${label}_version")
		JSON_RUNTIME_VALS+=("unavailable")
	fi
}

replicate_env_for_report() {
	EFFECTIVE_REPLICATE_CRON="${REPLICATE_CRON:-}"
	EFFECTIVE_REPLICATE_JOB_FILE="${REPLICATE_JOB_FILE:-/config/replicate_jobs.txt}"
	EFFECTIVE_REPLICATE_JOB_ARGS="${REPLICATE_JOB_ARGS:-}"
	EFFECTIVE_REPLICATE_VERBOSE="${REPLICATE_VERBOSE:-ON}"
	EFFECTIVE_REPLICATE_BISYNC_CHECK_ACCESS="${REPLICATE_BISYNC_CHECK_ACCESS:-OFF}"
}

report_replicate_jobs() {
	local job_file="$1"
	local line raw src dst mode count malformed
	count=0
	malformed=0

	if [ -z "${job_file}" ]; then
		info "Replicate job file: not configured"
		JSON_REPLICATE_JOBS_COUNT=0
		JSON_REPLICATE_MALFORMED_COUNT=0
		return 0
	fi
	if [ ! -e "${job_file}" ]; then
		if [ -n "${EFFECTIVE_REPLICATE_CRON:-}" ]; then
			warn "Replicate job file is configured but missing: ${job_file}"
		else
			info "Replicate job file not present (replicate disabled): ${job_file}"
		fi
		return 0
	fi
	if [ ! -r "${job_file}" ]; then
		warn "Replicate job file is not readable: ${job_file}"
		return 0
	fi

	while IFS= read -r raw || [ -n "${raw}" ]; do
		line="$(trim "${raw}")"
		[ -z "${line}" ] && continue
		[[ "${line}" == \#* ]] && continue

		IFS=';' read -r src dst mode _extra <<<"${line}"
		src="$(trim "${src:-}")"
		dst="$(trim "${dst:-}")"
		mode="$(trim "${mode:-bisync}")"
		[ -z "${mode}" ] && mode="bisync"

		count=$((count + 1))
		if [ -z "${src}" ] || [ -z "${dst}" ] || [[ ! "${mode}" =~ ^(bisync|sync|copy)$ ]]; then
			malformed=$((malformed + 1))
			warn "Replicate job ${count} malformed: $(mask_endpoint "${line}")"
		else
			info "Replicate job ${count}: $(mask_endpoint "${src}") -> $(mask_endpoint "${dst}") (${mode})"
		fi
	done <"${job_file}"

	JSON_REPLICATE_JOBS_COUNT="${count}"
	JSON_REPLICATE_MALFORMED_COUNT="${malformed}"

	if [ "${count}" -eq 0 ]; then
		warn "Replicate job file is readable but contains no active jobs: ${job_file}"
	elif [ "${malformed}" -eq 0 ]; then
		ok "Replicate job file: ${count} active job(s), 0 malformed"
	else
		warn "Replicate job file: ${count} active job(s), ${malformed} malformed"
	fi
}

report_hooks() {
	local phases=(
		pre-backup post-backup
		pre-check post-check
		pre-prune post-prune
		pre-forget post-forget
		pre-replicate post-replicate
		pre-restore post-restore
		pre-snapshot-export post-snapshot-export
		pre-forget-preview post-forget-preview
		pre-mount-snapshot post-mount-snapshot
		pre-unlock post-unlock
		pre-sources-report post-sources-report
		pre-init-repo post-init-repo
		pre-notify-test post-notify-test
		pre-restore-test post-restore-test
	)
	local phase hook found
	found=0

	if [ ! -d /hooks ]; then
		JSON_HOOKS_DIR_MOUNTED=false
		info "Hook directory /hooks is not mounted."
		return 0
	fi

	for phase in "${phases[@]}"; do
		hook="/hooks/${phase}.sh"
		if [ -f "${hook}" ]; then
			found=$((found + 1))
			if [ -x "${hook}" ]; then
				ok "${hook} is executable"
				JSON_HOOKS_PRESENT+=("${phase}|true")
			else
				warn "${hook} exists but is not executable"
				JSON_HOOKS_PRESENT+=("${phase}|false")
			fi
		fi
	done

	if [ "${found}" -eq 0 ]; then
		info "No known hook scripts found in /hooks."
	fi
}

report_last_json() {
	local file size
	local files=(
		/var/log/last-backup.json
		/var/log/last-check.json
		/var/log/last-prune.json
		/var/log/last-forget.json
		/var/log/last-replicate.json
		/var/log/last-restore.json
		/var/log/last-snapshot-export.json
		/var/log/last-forget-preview.json
		/var/log/last-mount-snapshot.json
		/var/log/last-unlock.json
		/var/log/last-sources-report.json
		/var/log/last-init-repo.json
		/var/log/last-notify-test.json
		/var/log/last-restore-test.json
	)

	for file in "${files[@]}"; do
		if [ -s "${file}" ]; then
			size="$(wc -c <"${file}" 2>/dev/null | tr -d ' ' || echo 0)"
			JSON_RECENT_JSON+=("${file}|true|${size}")
			if ! ${JSON_MODE}; then
				info "${file}:"
				sed 's/^/  /' "${file}"
			fi
		else
			JSON_RECENT_JSON+=("${file}|false|0")
			${JSON_MODE} || info "${file}: missing or empty"
		fi
	done
}

report_log_tail() {
	local file="$1"
	local lines="${2:-40}"

	# In JSON mode the cron log tail is not part of the schema (it is mostly
	# free-form text and we already capture worker results in last-*.json /
	# recent_json[] and checks[]). Skip the noisy block entirely.
	${JSON_MODE} && return 0

	if [ -s "${file}" ]; then
		info "Last ${lines} lines from ${file}:"
		tail -n "${lines}" "${file}" | sed 's/^/  /'
	else
		info "${file}: missing or empty"
	fi
}

# Render the doctor JSON document on stdout.
# Schema "restic-backup-helper.doctor/1" — adding fields is MINOR,
# renaming/removing fields is MAJOR.
emit_doctor_json() {
	local exit_code="$1"
	local hostname now_epoch now_iso release
	hostname="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
	release="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
	now_epoch="$(date +%s)"
	now_iso="$(iso8601_local "${now_epoch}")"

	local i sep entry IFS_save

	printf '{\n'
	printf '  "schema": "restic-backup-helper.doctor/1",\n'
	printf '  "command": "doctor",\n'
	printf '  "release": "%s",\n' "$(json_escape "${release}")"
	printf '  "hostname": "%s",\n' "$(json_escape "${hostname}")"
	printf '  "generated_at": "%s",\n' "$(json_escape "${now_iso}")"
	printf '  "generated_epoch": %d,\n' "${now_epoch}"
	printf '  "warnings": %d,\n' "${WARNINGS}"
	printf '  "errors": %d,\n' "${ERRORS}"
	printf '  "exit_code": %d,\n' "${exit_code}"

	# runtime{}
	# Iterate only when the array is non-empty. The size-guard pattern works on
	# every bash (3.2/4.x/5.x) while keeping `set -u` happy; the alternative
	# `${!arr[@]+...}` is buggy on Bash 3.2 (silently empty even for populated
	# arrays — bites macOS smoke tests).
	printf '  "runtime": {'
	sep=""
	if [ ${#JSON_RUNTIME_KEYS[@]} -gt 0 ]; then
		for i in "${!JSON_RUNTIME_KEYS[@]}"; do
			printf '%s\n    "%s": "%s"' \
				"${sep}" \
				"$(json_escape "${JSON_RUNTIME_KEYS[$i]}")" \
				"$(json_escape "${JSON_RUNTIME_VALS[$i]}")"
			sep=","
		done
		printf '\n  '
	fi
	printf '},\n'

	# environment{}
	printf '  "environment": {'
	sep=""
	if [ ${#JSON_ENV_KEYS[@]} -gt 0 ]; then
		for i in "${!JSON_ENV_KEYS[@]}"; do
			printf '%s\n    "%s": "%s"' \
				"${sep}" \
				"$(json_escape "${JSON_ENV_KEYS[$i]}")" \
				"$(json_escape "${JSON_ENV_VALS[$i]}")"
			sep=","
		done
		printf '\n  '
	fi
	printf '},\n'

	# repository_probe{}
	printf '  "repository_probe": {\n'
	printf '    "status": "%s",\n' "$(json_escape "${JSON_REPO_PROBE_STATUS:-skipped}")"
	printf '    "repository": "%s",\n' "$(json_escape "$(mask_repository "${RESTIC_REPOSITORY:-}")")"
	if [ -n "${JSON_REPO_PROBE_RC}" ]; then
		printf '    "restic_exit_code": %d\n' "${JSON_REPO_PROBE_RC}"
	else
		printf '    "restic_exit_code": null\n'
	fi
	printf '  },\n'

	# replicate{}
	printf '  "replicate": {\n'
	printf '    "effective": {'
	sep=""
	if [ ${#JSON_REPLICATE_KEYS[@]} -gt 0 ]; then
		for i in "${!JSON_REPLICATE_KEYS[@]}"; do
			printf '%s\n      "%s": "%s"' \
				"${sep}" \
				"$(json_escape "${JSON_REPLICATE_KEYS[$i]}")" \
				"$(json_escape "${JSON_REPLICATE_VALS[$i]}")"
			sep=","
		done
		printf '\n    '
	fi
	printf '},\n'
	printf '    "jobs_count": %d,\n' "${JSON_REPLICATE_JOBS_COUNT}"
	printf '    "malformed_count": %d\n' "${JSON_REPLICATE_MALFORMED_COUNT}"
	printf '  },\n'

	# hooks{}
	printf '  "hooks": {\n'
	printf '    "hook_timeout": "%s",\n' "$(json_escape "${JSON_HOOKS_TIMEOUT}")"
	if ${JSON_HOOKS_DIR_MOUNTED}; then
		printf '    "directory_mounted": true,\n'
	else
		printf '    "directory_mounted": false,\n'
	fi
	printf '    "present": ['
	sep=""
	IFS_save="${IFS}"
	if [ ${#JSON_HOOKS_PRESENT[@]} -gt 0 ]; then
		for entry in "${JSON_HOOKS_PRESENT[@]}"; do
			IFS='|' read -r phase exec_flag <<<"${entry}"
			printf '%s\n      {"phase": "%s", "executable": %s}' \
				"${sep}" \
				"$(json_escape "${phase}")" \
				"${exec_flag}"
			sep=","
		done
		printf '\n    '
	fi
	IFS="${IFS_save}"
	printf ']\n'
	printf '  },\n'

	# recent_json[]
	printf '  "recent_json": ['
	sep=""
	IFS_save="${IFS}"
	if [ ${#JSON_RECENT_JSON[@]} -gt 0 ]; then
		for entry in "${JSON_RECENT_JSON[@]}"; do
			IFS='|' read -r path present size <<<"${entry}"
			printf '%s\n    {"path": "%s", "present": %s, "size_bytes": %d}' \
				"${sep}" \
				"$(json_escape "${path}")" \
				"${present}" \
				"${size}"
			sep=","
		done
		printf '\n  '
	fi
	IFS="${IFS_save}"
	printf '],\n'

	# checks[]
	printf '  "checks": ['
	sep=""
	if [ ${#JSON_CHECKS[@]} -gt 0 ]; then
		for i in "${!JSON_CHECKS[@]}"; do
			printf '%s\n    %s' "${sep}" "${JSON_CHECKS[$i]}"
			sep=","
		done
		printf '\n  '
	fi
	printf ']\n'
	printf '}\n'
}

section "Runtime"
print_kv "release" "${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
print_kv "hostname" "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
print_kv "date" "$(date +"%Y-%m-%d %a %H:%M:%S %z")"
print_kv "timezone" "${TZ:-<unset>}"
report_command_version "restic" restic version
report_command_version "rclone" rclone version
report_command_version "bash" bash --version

section "Effective environment"
replicate_env_for_report
for name in \
	RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE RESTIC_PASSWORD_FILE RESTIC_PASSWORD RESTIC_TAG RESTIC_CACHE_DIR TMPDIR \
	RESTIC_CHECK_REPOSITORY_STATUS RESTIC_AUTO_UNLOCK RESTIC_CACERT NFS_TARGET \
	BACKUP_CRON BACKUP_ROOT_DIR RESTIC_JOB_ARGS RESTIC_FORGET_ARGS RESTIC_INIT_ARGS \
	CHECK_CRON RESTIC_CHECK_ARGS FORGET_CRON PRUNE_CRON RESTIC_PRUNE_ARGS \
	RCLONE_CONFIG REPLICATE_JOB_FILE REPLICATE_JOB_ARGS REPLICATE_CRON REPLICATE_VERBOSE REPLICATE_BISYNC_CHECK_ACCESS \
	HOOK_TIMEOUT MAILX_RCPT MAILX_ON_ERROR WEBHOOK_URL WEBHOOK_HEADER_AUTH WEBHOOK_TIMEOUT WEBHOOK_ON_ERROR \
	METRICS_DIR ROTATE_LOG_CRON CRON_LOG_MAX_SIZE MAX_CRON_LOG_ARCHIVES; do
	if [[ "${name}" == REPLICATE_* ]]; then
		effective_name="EFFECTIVE_${name}"
		print_kv "${name}" "${!effective_name:-}"
	else
		print_kv "${name}" "$(masked_env_value "${name}")"
	fi
done

section "Configuration checks"
if [ -n "${RESTIC_REPOSITORY_FILE:-}" ]; then
	# resolve_restic_repository_file (auto-invoked by lib.sh) left
	# RESTIC_REPOSITORY_FILE set, meaning promotion failed: file is
	# unreadable, empty or only contains comments. Surface the exact reason
	# so the operator does not have to guess.
	if [ ! -r "${RESTIC_REPOSITORY_FILE}" ]; then
		fail "RESTIC_REPOSITORY_FILE is set but not readable (${RESTIC_REPOSITORY_FILE})"
	else
		fail "RESTIC_REPOSITORY_FILE is set but contains no repository URL (${RESTIC_REPOSITORY_FILE})"
	fi
elif [ -z "${RESTIC_REPOSITORY:-}" ]; then
	fail "RESTIC_REPOSITORY is empty (set RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE)."
else
	ok "RESTIC_REPOSITORY is set to $(mask_repository "${RESTIC_REPOSITORY}")"
fi

if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
	check_readable_file "RESTIC_PASSWORD_FILE" "${RESTIC_PASSWORD_FILE}"
elif [ -n "${RESTIC_PASSWORD:-}" ]; then
	ok "RESTIC_PASSWORD is set (hidden)."
else
	fail "Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD."
fi

if [ -z "${RESTIC_TAG:-}" ]; then
	fail "RESTIC_TAG is empty; backups will abort."
else
	ok "RESTIC_TAG is set (${RESTIC_TAG})."
fi

if [ -z "${BACKUP_ROOT_DIR:-}" ] && [ -z "${RESTIC_JOB_ARGS:-}" ]; then
	fail "BACKUP_ROOT_DIR and RESTIC_JOB_ARGS are both empty (no backup paths)."
elif [ -n "${BACKUP_ROOT_DIR:-}" ]; then
	if [ -d "${BACKUP_ROOT_DIR}" ] && [ -r "${BACKUP_ROOT_DIR}" ]; then
		ok "BACKUP_ROOT_DIR is readable (${BACKUP_ROOT_DIR})."
	else
		warn "BACKUP_ROOT_DIR is not a readable directory (${BACKUP_ROOT_DIR})."
	fi
else
	ok "Backup paths are expected from RESTIC_JOB_ARGS."
fi

while IFS= read -r path; do
	check_readable_file "RESTIC_JOB_ARGS --files-from" "${path}"
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--files-from")

while IFS= read -r path; do
	check_optional_readable_file "RESTIC_JOB_ARGS --exclude-file" "${path}"
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--exclude-file")

if [[ "${RESTIC_REPOSITORY:-}" == rclone:* ]]; then
	check_readable_file "RCLONE_CONFIG" "${RCLONE_CONFIG:-/config/rclone.conf}"
else
	repo_type="${RESTIC_REPOSITORY:-}"
	info "RCLONE_CONFIG is not required for repository type: ${repo_type%%:*}"
fi

check_optional_readable_file "RESTIC_CACERT" "${RESTIC_CACERT:-}"
check_writable_dir "RESTIC_CACHE_DIR" "${RESTIC_CACHE_DIR:-}"
check_writable_dir "TMPDIR" "${TMPDIR:-}"
check_writable_dir "/var/log" "/var/log"
check_writable_dir "METRICS_DIR" "${METRICS_DIR:-}"

section "Repository probe"
build_restic_cacert_args
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	warn "Skipping repository probe because RESTIC_REPOSITORY is empty."
	JSON_REPO_PROBE_STATUS="skipped"
else
	# ${arr[@]+...} keeps `set -u` happy when RESTIC_CACERT_ARGS is the empty
	# array (RESTIC_CACERT unset, the common case).
	if probe_output="$(restic ${RESTIC_CACERT_ARGS[@]+"${RESTIC_CACERT_ARGS[@]}"} cat config 2>&1 >/dev/null)"; then
		ok "restic cat config succeeded for $(mask_repository "${RESTIC_REPOSITORY}")"
		JSON_REPO_PROBE_STATUS="ok"
		JSON_REPO_PROBE_RC=0
	else
		probe_status=$?
		JSON_REPO_PROBE_STATUS="fail"
		JSON_REPO_PROBE_RC="${probe_status}"
		if [ "${probe_status}" -eq 10 ]; then
			fail "Repository does not exist or is not initialized (restic exit 10). Doctor does not run restic init."
		else
			fail "Repository probe failed with restic exit ${probe_status}."
		fi
		if ! ${JSON_MODE} && [ -n "${probe_output}" ]; then
			info "Probe stderr:"
			printf '%s\n' "${probe_output}" | while IFS= read -r line; do
				printf '  %s\n' "$(mask_repository "${line}")"
			done
		fi
	fi
fi

section "Replicate"
print_kv "effective REPLICATE_CRON" "${EFFECTIVE_REPLICATE_CRON:-}"
print_kv "effective REPLICATE_JOB_FILE" "${EFFECTIVE_REPLICATE_JOB_FILE:-}"
print_kv "effective REPLICATE_JOB_ARGS" "${EFFECTIVE_REPLICATE_JOB_ARGS:-}"
print_kv "effective REPLICATE_VERBOSE" "${EFFECTIVE_REPLICATE_VERBOSE:-}"
print_kv "effective REPLICATE_BISYNC_CHECK_ACCESS" "${EFFECTIVE_REPLICATE_BISYNC_CHECK_ACCESS:-}"
report_replicate_jobs "${EFFECTIVE_REPLICATE_JOB_FILE:-}"

section "Hooks"
print_kv "HOOK_TIMEOUT" "${HOOK_TIMEOUT:-0}"
report_hooks

section "Recent JSON summaries"
report_last_json

section "Recent cron log"
report_log_tail "/var/log/cron.log" 40

section "Summary"
print_kv "warnings" "${WARNINGS}"
print_kv "errors" "${ERRORS}"

if ${JSON_MODE}; then
	exit_code=0
	[ "${ERRORS}" -gt 0 ] && exit_code=1
	emit_doctor_json "${exit_code}"
	exit "${exit_code}"
fi

if [ "${ERRORS}" -gt 0 ]; then
	fail "Doctor found ${ERRORS} error(s)."
	exit 1
fi
ok "Doctor completed without hard errors."
