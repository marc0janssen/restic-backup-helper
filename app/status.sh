#!/usr/bin/env bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Status / health summary
# Description: Fast read-only operator summary for daily use. Unlike
#              /bin/doctor, this command never probes the repository and never
#              calls restic/rclone; it only reads local state (last-*.json,
#              rendered crontab, env cron settings and release metadata).
# =========================================================

set -Eeuo pipefail

# shellcheck source=app/lib.sh
. /bin/lib.sh

CRONTAB_FILE="/var/spool/cron/crontabs/root"
JSON_MODE="OFF"

usage() {
	cat <<'EOF'
Usage: /bin/status [--json|-j]
       /bin/health-summary [--json|-j]

Fast daily operator health summary. Reads only local container state:
release, hostname, timezone, rendered crontab (or env preview), recent
last-*.json files and the ages / exit codes for scheduled backup, check,
forget, prune and replicate jobs.

Health rules:
  OK    All enabled core jobs have a successful recent JSON summary.
  WARN  Enabled core job is missing a last-*.json file, looks stale for a
        simple cron expression, or a non-scheduled helper JSON reports failure.
  FAIL  Enabled core job has a non-zero last exit code.

The command does not run restic, rclone, hooks, mail, webhooks or repository
probes. Use /bin/doctor when you need deeper diagnostics.

Modes:
  (default)      Compact human-readable summary.
  --json, -j     Emit a single JSON document on stdout
                 (schema "restic-backup-helper.status/1").

Exit code:
  0  Summary verdict is OK or WARN.
  1  Summary verdict is FAIL.
EOF
}

case "${1:-}" in
--json | -j)
	JSON_MODE="ON"
	shift
	;;
--help | -h)
	usage
	exit 0
	;;
"")
	;;
*)
	echo "❌ Unknown argument: $1" >&2
	echo "Run /bin/status --help for usage." >&2
	exit 2
	;;
esac

if [ "$#" -gt 0 ]; then
	echo "❌ Unexpected extra argument(s): $*" >&2
	echo "Run /bin/status --help for usage." >&2
	exit 2
fi

now_epoch="$(date +%s)"
release="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
hostname_value="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
generated_at="$(date +"%Y-%m-%dT%H:%M:%S%z")"
masked_repo=""
if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	masked_repo="$(mask_repository "${RESTIC_REPOSITORY}")"
fi

WARNINGS=0
FAILURES=0
FINDINGS=()
SCHEDULE_JSON=()
JOBS_JSON=()
RECENT_JSON=()

json_bool() {
	case "$1" in
	true | false) printf '%s' "$1" ;;
	*) printf 'false' ;;
	esac
}

add_finding() {
	local level="$1" message="$2"
	case "${level}" in
	WARN) WARNINGS=$((WARNINGS + 1)) ;;
	FAIL) FAILURES=$((FAILURES + 1)) ;;
	esac
	FINDINGS+=("{\"level\":\"$(json_escape "${level}")\",\"message\":\"$(json_escape "${message}")\"}")
}

mtime_epoch() {
	local file="$1"
	stat -c %Y "${file}" 2>/dev/null || stat -f %m "${file}" 2>/dev/null || printf '0'
}

json_get() {
	local file="$1" key="$2"
	sed -nE 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*"?([^",}]*)"?[,]?[[:space:]]*$/\1/p' "${file}" 2>/dev/null | head -n 1
}

iso_to_epoch() {
	local value="$1"
	[ -n "${value}" ] || return 0
	date -d "${value}" +%s 2>/dev/null || true
}

age_from_json_file() {
	local file="$1" finished epoch mtime
	finished="$(json_get "${file}" "finished_at")"
	epoch="$(iso_to_epoch "${finished}")"
	if [ -z "${epoch}" ]; then
		mtime="$(mtime_epoch "${file}")"
		epoch="${mtime}"
	fi
	if [ -n "${epoch}" ] && [ "${epoch}" -gt 0 ] && [ "${now_epoch}" -ge "${epoch}" ]; then
		printf '%s' "$((now_epoch - epoch))"
	else
		printf ''
	fi
}

human_age() {
	local seconds="${1:-}"
	local days hours minutes
	if [ -z "${seconds}" ]; then
		printf 'unknown'
		return 0
	fi
	days=$((seconds / 86400))
	hours=$(((seconds % 86400) / 3600))
	minutes=$(((seconds % 3600) / 60))
	if [ "${days}" -gt 0 ]; then
		printf '%dd %dh' "${days}" "${hours}"
	elif [ "${hours}" -gt 0 ]; then
		printf '%dh %dm' "${hours}" "${minutes}"
	else
		printf '%dm' "${minutes}"
	fi
}

cron_interval_minutes() {
	local expr="$1"
	local -a f
	read -r -a f <<<"${expr}"
	if [ "${#f[@]}" -ne 5 ]; then
		return 1
	fi

	# */N * * * *  -> every N minutes
	if [[ "${f[0]}" =~ ^\*/([0-9]+)$ && "${f[1]}" = "*" && "${f[2]}" = "*" && "${f[3]}" = "*" && "${f[4]}" = "*" ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi

	# M */N * * *  -> every N hours
	if [[ "${f[0]}" =~ ^[0-9]+$ && "${f[1]}" =~ ^\*/([0-9]+)$ && "${f[2]}" = "*" && "${f[3]}" = "*" && "${f[4]}" = "*" ]]; then
		printf '%s' "$((BASH_REMATCH[1] * 60))"
		return 0
	fi

	# M H * * *    -> daily
	if [[ "${f[0]}" =~ ^[0-9]+$ && "${f[1]}" =~ ^[0-9]+$ && "${f[2]}" = "*" && "${f[3]}" = "*" && "${f[4]}" = "*" ]]; then
		printf '1440'
		return 0
	fi

	# M H * * D    -> weekly-ish
	if [[ "${f[0]}" =~ ^[0-9]+$ && "${f[1]}" =~ ^[0-9]+$ && "${f[2]}" = "*" && "${f[3]}" = "*" && "${f[4]}" != "*" ]]; then
		printf '10080'
		return 0
	fi

	# M H D * *    -> monthly-ish (use 31 days as a conservative stale floor)
	if [[ "${f[0]}" =~ ^[0-9]+$ && "${f[1]}" =~ ^[0-9]+$ && "${f[2]}" != "*" && "${f[3]}" = "*" && "${f[4]}" = "*" ]]; then
		printf '44640'
		return 0
	fi

	return 1
}

stale_after_seconds() {
	local expr="$1"
	local interval_minutes
	if interval_minutes="$(cron_interval_minutes "${expr}")"; then
		# Allow three missed intervals plus ten minutes of scheduler / runtime
		# slack. This keeps a 6-hour backup from warning until roughly 18h10m.
		printf '%s' "$(((interval_minutes * 3 + 10) * 60))"
	else
		printf '0'
	fi
}

effective_replicate_cron() {
	if [ -n "${REPLICATE_CRON:-}" ]; then
		printf '%s' "${REPLICATE_CRON}"
	elif [ -n "${SYNC_CRON:-}" ]; then
		printf '%s' "${SYNC_CRON}"
	fi
}

schedule_command() {
	case "$1" in
	backup) printf '/bin/backup' ;;
	check) printf '/bin/check' ;;
	forget) printf '/bin/forget' ;;
	prune) printf '/bin/prune' ;;
	replicate) printf '/bin/replicate' ;;
	rotate_log) printf '/bin/rotate_log' ;;
	esac
}

add_schedule_json() {
	local job="$1" expr="$2" enabled="$3"
	SCHEDULE_JSON+=("{\"job\":\"$(json_escape "${job}")\",\"enabled\":$(json_bool "${enabled}"),\"cron\":\"$(json_escape "${expr}")\",\"command\":\"$(json_escape "$(schedule_command "${job}")")\"}")
}

render_crontab_lines() {
	if [ -r "${CRONTAB_FILE}" ]; then
		grep -v '^[[:space:]]*$' "${CRONTAB_FILE}" 2>/dev/null || true
	else
		[ -n "${BACKUP_CRON:-}" ] && printf '%s /bin/locked_run backup /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1\n' "${BACKUP_CRON}"
		[ -n "${CHECK_CRON:-}" ] && printf '%s /bin/locked_run check /var/run/check.lock /bin/check >> /var/log/cron.log 2>&1\n' "${CHECK_CRON}"
		[ -n "$(effective_replicate_cron)" ] && printf '%s /bin/locked_run replicate /var/run/replicate.lock /bin/replicate >> /var/log/cron.log 2>&1\n' "$(effective_replicate_cron)"
		[ -n "${FORGET_CRON:-}" ] && printf '%s /bin/locked_run forget /var/run/forget.lock /bin/forget >> /var/log/cron.log 2>&1\n' "${FORGET_CRON}"
		[ -n "${PRUNE_CRON:-}" ] && printf '%s /bin/locked_run prune /var/run/prune.lock /bin/prune >> /var/log/cron.log 2>&1\n' "${PRUNE_CRON}"
		[ -n "${ROTATE_LOG_CRON:-}" ] && printf '%s /bin/locked_run rotate_log /var/run/rotate_log.lock /bin/rotate_log >> /var/log/cron.log 2>&1\n' "${ROTATE_LOG_CRON}"
	fi
}

evaluate_job() {
	local job="$1" expr="$2" file="$3" core="$4"
	local enabled="false" status="disabled" exit_code="" age_seconds="" age_human="" stale_after="" detail="" finished_at=""

	if [ -n "${expr}" ]; then
		enabled="true"
	fi

	if [ "${enabled}" = "false" ]; then
		detail="disabled"
	elif [ ! -s "${file}" ]; then
		status="missing"
		detail="enabled but ${file} is missing or empty"
		if [ "${core}" = "true" ]; then
			add_finding "WARN" "${job}: enabled but ${file} is missing or empty"
		fi
	else
		exit_code="$(json_get "${file}" "exit_code")"
		finished_at="$(json_get "${file}" "finished_at")"
		age_seconds="$(age_from_json_file "${file}")"
		age_human="$(human_age "${age_seconds}")"
		stale_after="$(stale_after_seconds "${expr}")"
		if [ -n "${exit_code}" ] && [ "${exit_code}" != "0" ]; then
			status="fail"
			detail="last exit ${exit_code}, age ${age_human}"
			if [ "${core}" = "true" ]; then
				add_finding "FAIL" "${job}: last run failed with exit ${exit_code} (${file})"
			else
				add_finding "WARN" "${job}: helper JSON reports exit ${exit_code} (${file})"
			fi
		elif [ -n "${age_seconds}" ] && [ "${stale_after}" -gt 0 ] && [ "${age_seconds}" -gt "${stale_after}" ]; then
			status="stale"
			detail="last successful run age ${age_human}; expected < $(human_age "${stale_after}")"
			if [ "${core}" = "true" ]; then
				add_finding "WARN" "${job}: last successful run looks stale (${age_human}, cron '${expr}')"
			fi
		else
			status="ok"
			detail="last exit 0, age ${age_human}"
		fi
	fi

	JOBS_JSON+=("{\"job\":\"$(json_escape "${job}")\",\"enabled\":$(json_bool "${enabled}"),\"core\":$(json_bool "${core}"),\"status\":\"$(json_escape "${status}")\",\"cron\":\"$(json_escape "${expr}")\",\"path\":\"$(json_escape "${file}")\",\"present\":$(json_bool "$([ -s "${file}" ] && echo true || echo false)"),\"exit_code\":\"$(json_escape "${exit_code}")\",\"age_seconds\":\"$(json_escape "${age_seconds}")\",\"age_human\":\"$(json_escape "${age_human}")\",\"finished_at\":\"$(json_escape "${finished_at}")\",\"detail\":\"$(json_escape "${detail}")\"}")
}

collect_recent_json() {
	local file job exit_code age_seconds age_human present
	for file in \
		/var/log/last-backup.json \
		/var/log/last-check.json \
		/var/log/last-prune.json \
		/var/log/last-forget.json \
		/var/log/last-replicate.json \
		/var/log/last-restore.json \
		/var/log/last-snapshot-export.json \
		/var/log/last-forget-preview.json \
		/var/log/last-mount-snapshot.json \
		/var/log/last-unlock.json \
		/var/log/last-sources-report.json \
		/var/log/last-init-repo.json \
		/var/log/last-notify-test.json \
		/var/log/last-restore-test.json; do
		job="${file#/var/log/last-}"
		job="${job%.json}"
		present="false"
		exit_code=""
		age_seconds=""
		age_human=""
		if [ -s "${file}" ]; then
			present="true"
			exit_code="$(json_get "${file}" "exit_code")"
			age_seconds="$(age_from_json_file "${file}")"
			age_human="$(human_age "${age_seconds}")"
			case "${job}" in
			backup | check | forget | prune | replicate)
				:
				;;
			*)
				if [ -n "${exit_code}" ] && [ "${exit_code}" != "0" ]; then
					add_finding "WARN" "${job}: recent helper JSON reports exit ${exit_code}"
				fi
				;;
			esac
		fi
		RECENT_JSON+=("{\"job\":\"$(json_escape "${job}")\",\"path\":\"$(json_escape "${file}")\",\"present\":$(json_bool "${present}"),\"exit_code\":\"$(json_escape "${exit_code}")\",\"age_seconds\":\"$(json_escape "${age_seconds}")\",\"age_human\":\"$(json_escape "${age_human}")\"}")
	done
}

backup_cron="${BACKUP_CRON:-}"
check_cron="${CHECK_CRON:-}"
forget_cron="${FORGET_CRON:-}"
prune_cron="${PRUNE_CRON:-}"
replicate_cron="$(effective_replicate_cron)"
rotate_log_cron="${ROTATE_LOG_CRON:-}"

add_schedule_json "backup" "${backup_cron}" "$([ -n "${backup_cron}" ] && echo true || echo false)"
add_schedule_json "check" "${check_cron}" "$([ -n "${check_cron}" ] && echo true || echo false)"
add_schedule_json "forget" "${forget_cron}" "$([ -n "${forget_cron}" ] && echo true || echo false)"
add_schedule_json "prune" "${prune_cron}" "$([ -n "${prune_cron}" ] && echo true || echo false)"
add_schedule_json "replicate" "${replicate_cron}" "$([ -n "${replicate_cron}" ] && echo true || echo false)"
add_schedule_json "rotate_log" "${rotate_log_cron}" "$([ -n "${rotate_log_cron}" ] && echo true || echo false)"

evaluate_job "backup" "${backup_cron}" "/var/log/last-backup.json" "true"
evaluate_job "check" "${check_cron}" "/var/log/last-check.json" "true"
evaluate_job "forget" "${forget_cron}" "/var/log/last-forget.json" "true"
evaluate_job "prune" "${prune_cron}" "/var/log/last-prune.json" "true"
evaluate_job "replicate" "${replicate_cron}" "/var/log/last-replicate.json" "true"
collect_recent_json

verdict="OK"
exit_code=0
if [ "${FAILURES}" -gt 0 ]; then
	verdict="FAIL"
	exit_code=1
elif [ "${WARNINGS}" -gt 0 ]; then
	verdict="WARN"
fi

crontab_source="environment-preview"
if [ -r "${CRONTAB_FILE}" ]; then
	crontab_source="${CRONTAB_FILE}"
fi
crontab_lines="$(render_crontab_lines)"
crontab_count=0
if [ -n "${crontab_lines}" ]; then
	crontab_count="$(printf '%s\n' "${crontab_lines}" | grep -c . || true)"
fi

if [ "${JSON_MODE}" = "ON" ]; then
	printf '{\n'
	printf '  "schema": "restic-backup-helper.status/1",\n'
	printf '  "command": "status",\n'
	printf '  "release": "%s",\n' "$(json_escape "${release}")"
	printf '  "hostname": "%s",\n' "$(json_escape "${hostname_value}")"
	printf '  "generated_at": "%s",\n' "$(json_escape "${generated_at}")"
	printf '  "generated_epoch": %s,\n' "${now_epoch}"
	printf '  "verdict": "%s",\n' "${verdict}"
	printf '  "warnings": %d,\n' "${WARNINGS}"
	printf '  "failures": %d,\n' "${FAILURES}"
	printf '  "exit_code": %d,\n' "${exit_code}"
	printf '  "runtime": {"tz": "%s", "repository": "%s"},\n' "$(json_escape "${TZ:-}")" "$(json_escape "${masked_repo}")"
	printf '  "crontab": {"source": "%s", "path": "%s", "line_count": %d},\n' "$(json_escape "${crontab_source}")" "$(json_escape "${CRONTAB_FILE}")" "${crontab_count}"
	printf '  "schedules": [%s],\n' "$(
		IFS=,
		printf '%s' "${SCHEDULE_JSON[*]}"
	)"
	printf '  "jobs": [%s],\n' "$(
		IFS=,
		printf '%s' "${JOBS_JSON[*]}"
	)"
	printf '  "recent_json": [%s],\n' "$(
		IFS=,
		printf '%s' "${RECENT_JSON[*]}"
	)"
	printf '  "findings": [%s]\n' "$(
		IFS=,
		printf '%s' "${FINDINGS[*]}"
	)"
	printf '}\n'
	exit "${exit_code}"
fi

printf 'restic-backup-helper status: %s\n' "${verdict}"
printf 'release:            %s\n' "${release}"
printf 'hostname:           %s\n' "${hostname_value}"
printf 'time:               %s\n' "$(date +"%Y-%m-%d %a %H:%M:%S %Z")"
printf 'repository:         %s\n' "${masked_repo:-<empty>}"
printf 'warnings/failures:  %d/%d\n' "${WARNINGS}" "${FAILURES}"

printf '\n== Schedules ==\n'
printf 'crontab source:     %s (%s line(s))\n' "${crontab_source}" "${crontab_count}"
printf '  %-10s %-8s %s\n' "job" "state" "cron"
for row in \
	"backup|${backup_cron}" \
	"check|${check_cron}" \
	"forget|${forget_cron}" \
	"prune|${prune_cron}" \
	"replicate|${replicate_cron}" \
	"rotate_log|${rotate_log_cron}"; do
	job="${row%%|*}"
	expr="${row#*|}"
	if [ -n "${expr}" ]; then
		printf '  %-10s %-8s %s\n' "${job}" "enabled" "${expr}"
	else
		printf '  %-10s %-8s %s\n' "${job}" "disabled" "-"
	fi
done

printf '\n== Core Job Ages ==\n'
printf '  %-10s %-10s %-8s %-10s %s\n' "job" "status" "exit" "age" "detail"
for job in backup check forget prune replicate; do
	entry="$(printf '%s\n' "${JOBS_JSON[@]}" | sed -nE 's/.*"job":"'"${job}"'".*"status":"([^"]*)".*"exit_code":"([^"]*)".*"age_human":"([^"]*)".*"detail":"([^"]*)".*/\1|\2|\3|\4/p')"
	status="${entry%%|*}"
	rest="${entry#*|}"
	exit_v="${rest%%|*}"
	rest="${rest#*|}"
	age_v="${rest%%|*}"
	detail_v="${rest#*|}"
	printf '  %-10s %-10s %-8s %-10s %s\n' "${job}" "${status:-unknown}" "${exit_v:--}" "${age_v:--}" "${detail_v:-}"
done

printf '\n== Recent JSON ==\n'
printf '  %-22s %-8s %-8s %s\n' "file" "exit" "age" "path"
for file in /var/log/last-*.json; do
	[ -e "${file}" ] || {
		printf '  (no last-*.json files found)\n'
		break
	}
	[ -s "${file}" ] || continue
	job="${file#/var/log/last-}"
	exit_v="$(json_get "${file}" "exit_code")"
	age_v="$(human_age "$(age_from_json_file "${file}")")"
	printf '  %-22s %-8s %-8s %s\n' "${job}" "${exit_v:-?}" "${age_v}" "${file}"
done

if [ "${#FINDINGS[@]}" -gt 0 ]; then
	printf '\n== Findings ==\n'
	for finding in "${FINDINGS[@]}"; do
		level="$(printf '%s' "${finding}" | sed -nE 's/.*"level":"([^"]*)".*/\1/p')"
		message="$(printf '%s' "${finding}" | sed -nE 's/.*"message":"([^"]*)".*/\1/p')"
		printf '  [%s] %s\n' "${level}" "${message}"
	done
fi

exit "${exit_code}"
