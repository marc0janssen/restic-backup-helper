#!/usr/bin/env bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Cron List
# Description: Print effective cron configuration for operators
# =========================================================

set -Eeuo pipefail

CRONTAB_FILE="/var/spool/cron/crontabs/root"

effective_replicate_cron() {
	if [ -n "${REPLICATE_CRON:-}" ]; then
		printf '%s' "${REPLICATE_CRON}"
	elif [ -n "${SYNC_CRON:-}" ]; then
		printf '%s' "${SYNC_CRON}"
	fi
}

effective_replicate_job_file() {
	if [ -n "${REPLICATE_JOB_FILE:-}" ]; then
		printf '%s' "${REPLICATE_JOB_FILE}"
	elif [ -n "${SYNC_JOB_FILE:-}" ]; then
		printf '%s' "${SYNC_JOB_FILE}"
	else
		printf '%s' "/config/replicate_jobs.txt"
	fi
}

cron_line_for_job() {
	local job="$1"
	local expr="$2"

	case "${job}" in
	backup)
		printf '%s /bin/locked_run backup /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	check)
		printf '%s /bin/locked_run check /var/run/check.lock /bin/check >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	replicate)
		printf '%s /bin/locked_run replicate /var/run/replicate.lock /bin/replicate >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	forget)
		printf '%s /bin/locked_run forget /var/run/forget.lock /bin/forget >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	prune)
		printf '%s /bin/locked_run prune /var/run/prune.lock /bin/prune >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	rotate_log)
		printf '%s /bin/locked_run rotate_log /var/run/rotate_log.lock /bin/rotate_log >> /var/log/cron.log 2>&1\n' "${expr}"
		;;
	esac
}

print_rendered_from_env() {
	cron_line_for_job "backup" "${BACKUP_CRON:-}"
	[ -n "${CHECK_CRON:-}" ] && cron_line_for_job "check" "${CHECK_CRON}"
	[ -n "$(effective_replicate_cron)" ] && cron_line_for_job "replicate" "$(effective_replicate_cron)"
	[ -n "${FORGET_CRON:-}" ] && cron_line_for_job "forget" "${FORGET_CRON}"
	[ -n "${PRUNE_CRON:-}" ] && cron_line_for_job "prune" "${PRUNE_CRON}"
	cron_line_for_job "rotate_log" "${ROTATE_LOG_CRON:-}"
}

describe_field() {
	local label="$1"
	local value="$2"

	case "${value}" in
	"*")
		printf '%s=every' "${label}"
		;;
	"*/"*)
		printf '%s=every %s' "${label}" "${value#*/}"
		;;
	*)
		printf '%s=%s' "${label}" "${value}"
		;;
	esac
}

describe_schedule() {
	local expr="$1"
	local -a f
	local extra

	read -r -a f <<<"${expr}"
	extra="${f[5]:-}"
	if [ "${#f[@]}" -ne 5 ] || [ -n "${extra}" ]; then
		printf 'custom/non-5-field expression: %s' "${expr:-<empty>}"
		return 0
	fi

	case "${expr}" in
	"0 */"*' * * *')
		printf 'every %s hours at minute 0' "${f[1]#*/}"
		;;
	"*/"*' * * * *')
		printf 'every %s minutes' "${f[0]#*/}"
		;;
	"0 0 * * "*)
		printf 'weekly/daily midnight pattern (%s)' "${expr}"
		;;
	*)
		printf '%s; %s; %s; %s; %s' \
			"$(describe_field minute "${f[0]}")" \
			"$(describe_field hour "${f[1]}")" \
			"$(describe_field day-of-month "${f[2]}")" \
			"$(describe_field month "${f[3]}")" \
			"$(describe_field day-of-week "${f[4]}")"
		;;
	esac
}

print_job_summary() {
	local name="$1"
	local expr="$2"
	local command="$3"
	local note="${4:-}"

	if [ -z "${expr}" ]; then
		printf '  %-12s disabled\n' "${name}"
		return 0
	fi

	printf '  %-12s %s\n' "${name}" "${expr}"
	printf '  %-12s -> %s\n' "" "$(describe_schedule "${expr}")"
	printf '  %-12s command: %s\n' "" "${command}"
	if [ -n "${note}" ]; then
		printf '  %-12s note: %s\n' "" "${note}"
	fi
}

print_section() {
	printf '\n== %s ==\n' "$1"
}

replicate_cron="$(effective_replicate_cron)"

print_section "Timezone"
printf 'TZ: %s\n' "${TZ:-<unset>}"
printf 'Current time: %s\n' "$(date '+%Y-%m-%d %a %H:%M:%S %Z')"

print_section "Rendered Crontab"
if [ -r "${CRONTAB_FILE}" ]; then
	printf '# Source: %s\n' "${CRONTAB_FILE}"
	while IFS= read -r line || [ -n "${line}" ]; do
		printf '%s\n' "${line}"
	done <"${CRONTAB_FILE}"
else
	printf '# Source: environment preview (crontab file not readable yet: %s)\n' "${CRONTAB_FILE}"
	print_rendered_from_env
fi

print_section "Schedule Summary"
print_job_summary "backup" "${BACKUP_CRON:-}" "/bin/backup" "Always rendered by entrypoint; BACKUP_CRON should be a 5-field cron expression."
print_job_summary "check" "${CHECK_CRON:-}" "/bin/check"
print_job_summary "replicate" "${replicate_cron}" "/bin/replicate" "Job file: $(effective_replicate_job_file). Legacy SYNC_CRON is accepted until 3.0.0."
print_job_summary "forget" "${FORGET_CRON:-}" "/bin/forget" "When enabled, /bin/backup skips inline restic forget and RESTIC_FORGET_ARGS is reused here."
print_job_summary "prune" "${PRUNE_CRON:-}" "/bin/prune"
print_job_summary "rotate_log" "${ROTATE_LOG_CRON:-}" "/bin/rotate_log"

print_section "Retention Notes"
if [ -n "${FORGET_CRON:-}" ]; then
	printf 'Standalone forget enabled: backup inline forget is skipped when RESTIC_FORGET_ARGS is set.\n'
elif [ -n "${RESTIC_FORGET_ARGS:-}" ]; then
	printf 'Inline forget enabled: /bin/backup runs restic forget after successful backups using RESTIC_FORGET_ARGS.\n'
else
	printf 'No forget policy configured: RESTIC_FORGET_ARGS is empty and FORGET_CRON is empty.\n'
fi
