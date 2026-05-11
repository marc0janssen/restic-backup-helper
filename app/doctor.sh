#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Doctor Script
# Description: Read-only operator diagnostics for common runtime issues
# =========================================================

set -Eeuo pipefail

# shellcheck source=app/lib.sh
. /bin/lib.sh

WARNINGS=0
ERRORS=0

section() {
	printf '\n== %s ==\n' "$1"
}

info() {
	printf '[INFO] %s\n' "$1"
}

ok() {
	printf '[OK] %s\n' "$1"
}

warn() {
	WARNINGS=$((WARNINGS + 1))
	printf '[WARN] %s\n' "$1"
}

fail() {
	ERRORS=$((ERRORS + 1))
	printf '[FAIL] %s\n' "$1"
}

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "${s}"
}

print_kv() {
	printf '  %-34s %s\n' "$1:" "$2"
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

collect_arg_paths() {
	local args="$1"
	local flag="$2"
	local -a parts
	local i token next

	[ -n "${args}" ] || return 0
	read -r -a parts <<<"${args}"

	for ((i = 0; i < ${#parts[@]}; i++)); do
		token="${parts[$i]}"
		case "${token}" in
		"${flag}")
			next="${parts[$((i + 1))]:-}"
			[ -n "${next}" ] && printf '%s\n' "${next}"
			;;
		"${flag}"=*)
			printf '%s\n' "${token#*=}"
			;;
		esac
	done
}

report_command_version() {
	local label="$1"
	shift
	local output rc

	if output="$("$@" 2>&1 | sed -n '1p')"; then
		rc=0
		ok "${label}: ${output}"
	else
		rc=$?
		warn "${label}: unavailable (exit ${rc})"
	fi
}

map_legacy_replicate_env_for_report() {
	EFFECTIVE_REPLICATE_CRON="${REPLICATE_CRON:-}"
	EFFECTIVE_REPLICATE_JOB_FILE="${REPLICATE_JOB_FILE:-/config/replicate_jobs.txt}"
	EFFECTIVE_REPLICATE_JOB_ARGS="${REPLICATE_JOB_ARGS:-}"
	EFFECTIVE_REPLICATE_VERBOSE="${REPLICATE_VERBOSE:-ON}"
	EFFECTIVE_REPLICATE_BISYNC_CHECK_ACCESS="${REPLICATE_BISYNC_CHECK_ACCESS:-OFF}"

	if [ -n "${SYNC_CRON:-}" ] && [ -z "${EFFECTIVE_REPLICATE_CRON}" ]; then
		EFFECTIVE_REPLICATE_CRON="${SYNC_CRON}"
		warn "SYNC_CRON is deprecated; effective REPLICATE_CRON comes from SYNC_CRON."
	fi
	if [ -n "${SYNC_JOB_FILE:-}" ] && { [ -z "${REPLICATE_JOB_FILE:-}" ] || [ "${REPLICATE_JOB_FILE:-}" = "/config/replicate_jobs.txt" ]; }; then
		EFFECTIVE_REPLICATE_JOB_FILE="${SYNC_JOB_FILE}"
		warn "SYNC_JOB_FILE is deprecated; effective REPLICATE_JOB_FILE comes from SYNC_JOB_FILE."
	fi
	if [ -n "${SYNC_JOB_ARGS:-}" ] && [ -z "${EFFECTIVE_REPLICATE_JOB_ARGS}" ]; then
		EFFECTIVE_REPLICATE_JOB_ARGS="${SYNC_JOB_ARGS}"
		warn "SYNC_JOB_ARGS is deprecated; effective REPLICATE_JOB_ARGS comes from SYNC_JOB_ARGS."
	fi
	if [ -n "${SYNC_VERBOSE:-}" ] && { [ -z "${REPLICATE_VERBOSE:-}" ] || [ "${REPLICATE_VERBOSE:-}" = "ON" ]; }; then
		EFFECTIVE_REPLICATE_VERBOSE="${SYNC_VERBOSE}"
		warn "SYNC_VERBOSE is deprecated; effective REPLICATE_VERBOSE comes from SYNC_VERBOSE."
	fi
	if [ -n "${SYNC_BISYNC_CHECK_ACCESS:-}" ] && { [ -z "${REPLICATE_BISYNC_CHECK_ACCESS:-}" ] || [ "${REPLICATE_BISYNC_CHECK_ACCESS:-}" = "OFF" ]; }; then
		EFFECTIVE_REPLICATE_BISYNC_CHECK_ACCESS="${SYNC_BISYNC_CHECK_ACCESS}"
		warn "SYNC_BISYNC_CHECK_ACCESS is deprecated; effective REPLICATE_BISYNC_CHECK_ACCESS comes from SYNC_BISYNC_CHECK_ACCESS."
	fi
}

report_replicate_jobs() {
	local job_file="$1"
	local line raw src dst mode count malformed
	count=0
	malformed=0

	if [ -z "${job_file}" ]; then
		info "Replicate job file: not configured"
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
		pre-replicate post-replicate
		pre-restore post-restore
	)
	local phase hook found
	found=0

	if [ ! -d /hooks ]; then
		info "Hook directory /hooks is not mounted."
		return 0
	fi

	for phase in "${phases[@]}"; do
		hook="/hooks/${phase}.sh"
		if [ -f "${hook}" ]; then
			found=$((found + 1))
			if [ -x "${hook}" ]; then
				ok "${hook} is executable"
			else
				warn "${hook} exists but is not executable"
			fi
		fi
	done

	if [ "${found}" -eq 0 ]; then
		info "No known hook scripts found in /hooks."
	fi
}

report_last_json() {
	local file
	local files=(
		/var/log/last-backup.json
		/var/log/last-check.json
		/var/log/last-prune.json
		/var/log/last-replicate.json
		/var/log/last-restore.json
	)

	for file in "${files[@]}"; do
		if [ -s "${file}" ]; then
			info "${file}:"
			sed 's/^/  /' "${file}"
		else
			info "${file}: missing or empty"
		fi
	done
}

report_log_tail() {
	local file="$1"
	local lines="${2:-40}"

	if [ -s "${file}" ]; then
		info "Last ${lines} lines from ${file}:"
		tail -n "${lines}" "${file}" | sed 's/^/  /'
	else
		info "${file}: missing or empty"
	fi
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
map_legacy_replicate_env_for_report
for name in \
	RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_PASSWORD RESTIC_TAG RESTIC_CACHE_DIR TMPDIR \
	RESTIC_CHECK_REPOSITORY_STATUS RESTIC_AUTO_UNLOCK RESTIC_CACERT NFS_TARGET \
	BACKUP_CRON BACKUP_ROOT_DIR RESTIC_JOB_ARGS RESTIC_FORGET_ARGS \
	CHECK_CRON RESTIC_CHECK_ARGS PRUNE_CRON RESTIC_PRUNE_ARGS \
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
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	fail "RESTIC_REPOSITORY is empty."
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
else
	if probe_output="$(restic "${RESTIC_CACERT_ARGS[@]}" cat config 2>&1 >/dev/null)"; then
		ok "restic cat config succeeded for $(mask_repository "${RESTIC_REPOSITORY}")"
	else
		probe_status=$?
		if [ "${probe_status}" -eq 10 ]; then
			fail "Repository does not exist or is not initialized (restic exit 10). Doctor does not run restic init."
		else
			fail "Repository probe failed with restic exit ${probe_status}."
		fi
		if [ -n "${probe_output}" ]; then
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
if [ "${ERRORS}" -gt 0 ]; then
	fail "Doctor found ${ERRORS} error(s)."
	exit 1
fi
ok "Doctor completed without hard errors."
