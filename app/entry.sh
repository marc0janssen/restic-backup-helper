#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Helper
# Description: Container startup script for Restic Backup Helper
# =========================================================

set -Eeuo pipefail

# Source shared helpers before the dispatch case below so every entrypoint
# path (config-check, doctor, cron-list, sources-report, init-repo,
# notify-test, restore-test and the normal cron flow) observes the same
# masked-repository / RESTIC_REPOSITORY_FILE-resolution semantics. lib.sh runs
# resolve_restic_repository_file at the bottom of the file, so by the time
# any subcommand runs, RESTIC_REPOSITORY already reflects the value from
# RESTIC_REPOSITORY_FILE (when configured).
# shellcheck source=app/lib.sh
. /bin/lib.sh

# Machine-readable diagnostics: when run_config_check is called with mode="json",
# every check is captured into an accumulator and a single JSON document is
# emitted on stdout at the end (schema "restic-backup-helper.config-check/1").
# In text mode behaviour is unchanged: stdout gets the banner + final OK line,
# stderr gets the individual ERROR/WARN lines. The CONFIG_CHECK_* arrays are
# populated identically in both modes so the text path and JSON path stay in
# sync forever — the only difference is which sink renders them at the end.
run_config_check() {
	local mode="${1:-text}"
	local err=0
	local fails=0
	local warns=0
	local replicate_cron sjf rc_file
	# Parallel arrays: same index = same finding.
	CONFIG_CHECK_KEYS=()
	CONFIG_CHECK_STATUS=()
	CONFIG_CHECK_MSGS=()

	cc_add() {
		local key="$1" status="$2" msg="$3"
		CONFIG_CHECK_KEYS+=("${key}")
		CONFIG_CHECK_STATUS+=("${status}")
		CONFIG_CHECK_MSGS+=("${msg}")
		case "${status}" in
		fail)
			err=1
			fails=$((fails + 1))
			;;
		warn) warns=$((warns + 1)) ;;
		esac
		if [ "${mode}" != "json" ]; then
			case "${status}" in
			fail) echo "[config-check] ERROR: ${msg}" >&2 ;;
			warn) echo "[config-check] WARN: ${msg}" >&2 ;;
			esac
		fi
	}

	if [ "${mode}" != "json" ]; then
		echo "[config-check] Validating configuration..."
	fi

	if [ -n "${RESTIC_REPOSITORY_FILE:-}" ]; then
		# resolve_restic_repository_file kept RESTIC_REPOSITORY_FILE set, which
		# means the file is unreadable or empty/comments-only. Either way,
		# RESTIC_REPOSITORY did not get promoted and the configuration is
		# broken. Diagnose the specific failure so operators do not have to
		# guess.
		if [ ! -r "${RESTIC_REPOSITORY_FILE}" ]; then
			cc_add "RESTIC_REPOSITORY_FILE" "fail" "RESTIC_REPOSITORY_FILE is not readable: ${RESTIC_REPOSITORY_FILE}"
		else
			cc_add "RESTIC_REPOSITORY_FILE" "fail" "RESTIC_REPOSITORY_FILE '${RESTIC_REPOSITORY_FILE}' is empty or contains only comments."
		fi
	elif [ -z "${RESTIC_REPOSITORY:-}" ]; then
		cc_add "RESTIC_REPOSITORY" "fail" "RESTIC_REPOSITORY is empty (set RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE)."
	else
		cc_add "RESTIC_REPOSITORY" "ok" "RESTIC_REPOSITORY is set to $(mask_repository "${RESTIC_REPOSITORY}")."
	fi
	if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
		if [ ! -r "${RESTIC_PASSWORD_FILE}" ]; then
			cc_add "RESTIC_PASSWORD_FILE" "fail" "RESTIC_PASSWORD_FILE is not readable: ${RESTIC_PASSWORD_FILE}"
		else
			cc_add "RESTIC_PASSWORD_FILE" "ok" "RESTIC_PASSWORD_FILE is readable."
		fi
	elif [ -z "${RESTIC_PASSWORD:-}" ]; then
		cc_add "RESTIC_PASSWORD" "fail" "Set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE."
	else
		cc_add "RESTIC_PASSWORD" "ok" "RESTIC_PASSWORD is set (hidden)."
	fi
	if [ -z "${RESTIC_TAG:-}" ]; then
		cc_add "RESTIC_TAG" "fail" "RESTIC_TAG is empty."
	else
		cc_add "RESTIC_TAG" "ok" "RESTIC_TAG is set (${RESTIC_TAG})."
	fi
	if [ -z "${BACKUP_ROOT_DIR:-}" ] && [ -z "${RESTIC_JOB_ARGS:-}" ]; then
		cc_add "BACKUP_PATHS" "fail" "BACKUP_ROOT_DIR and RESTIC_JOB_ARGS are both empty (no backup paths)."
	else
		cc_add "BACKUP_PATHS" "ok" "Backup paths are configured."
	fi
	if [[ "${RESTIC_REPOSITORY:-}" == rclone:* ]]; then
		rc_file="${RCLONE_CONFIG:-/config/rclone.conf}"
		if [ ! -r "${rc_file}" ]; then
			cc_add "RCLONE_CONFIG" "fail" "Rclone repository configured but ${rc_file} is not readable."
		else
			cc_add "RCLONE_CONFIG" "ok" "Rclone config is readable (${rc_file})."
		fi
	fi
	replicate_cron="${REPLICATE_CRON:-${SYNC_CRON:-}}"
	if [ -n "${replicate_cron}" ]; then
		sjf="${REPLICATE_JOB_FILE:-/config/replicate_jobs.txt}"
		if [ -n "${SYNC_JOB_FILE:-}" ] && { [ -z "${REPLICATE_JOB_FILE:-}" ] || [ "${REPLICATE_JOB_FILE:-}" = "/config/replicate_jobs.txt" ]; }; then
			sjf="${SYNC_JOB_FILE}"
		fi
		if [ ! -s "${sjf}" ]; then
			cc_add "REPLICATE_JOB_FILE" "warn" "REPLICATE_CRON is set but ${sjf} is missing or empty."
		else
			cc_add "REPLICATE_JOB_FILE" "ok" "REPLICATE_CRON is set and ${sjf} exists."
		fi
	fi
	if [ -n "${RESTIC_CACERT:-}" ] && [ ! -r "${RESTIC_CACERT}" ]; then
		cc_add "RESTIC_CACERT" "fail" "RESTIC_CACERT is set but file is not readable: ${RESTIC_CACERT}"
	fi

	if [ "${mode}" = "json" ]; then
		emit_config_check_json "${err}" "${fails}" "${warns}"
	elif [ "${err}" -eq 0 ]; then
		echo "[config-check] OK."
	fi
	return "${err}"
}

# Emit the config-check JSON document on stdout.
# Schema "restic-backup-helper.config-check/1" is part of the public API:
# adding fields is MINOR, renaming/removing fields is MAJOR.
emit_config_check_json() {
	local err="$1" fails="$2" warns="$3"
	local exit_code="${err}"
	local hostname release now_epoch now_iso
	hostname="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
	release="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
	now_epoch="$(date +%s)"
	now_iso="$(iso8601_local "${now_epoch}")"

	printf '{\n'
	printf '  "schema": "restic-backup-helper.config-check/1",\n'
	printf '  "command": "config-check",\n'
	printf '  "release": "%s",\n' "$(json_escape "${release}")"
	printf '  "hostname": "%s",\n' "$(json_escape "${hostname}")"
	printf '  "generated_at": "%s",\n' "$(json_escape "${now_iso}")"
	printf '  "generated_epoch": %d,\n' "${now_epoch}"
	printf '  "warnings": %d,\n' "${warns}"
	printf '  "errors": %d,\n' "${fails}"
	printf '  "exit_code": %d,\n' "${exit_code}"
	printf '  "checks": ['
	local i sep=""
	# Size-guard keeps `set -u` happy when the accumulator is empty and works
	# on every bash (3.2/4.x/5.x) — `${!arr[@]+...}` is buggy on Bash 3.2.
	if [ ${#CONFIG_CHECK_KEYS[@]} -gt 0 ]; then
		for i in "${!CONFIG_CHECK_KEYS[@]}"; do
			printf '%s\n    {"key": "%s", "status": "%s", "message": "%s"}' \
				"${sep}" \
				"$(json_escape "${CONFIG_CHECK_KEYS[$i]}")" \
				"${CONFIG_CHECK_STATUS[$i]}" \
				"$(json_escape "${CONFIG_CHECK_MSGS[$i]}")"
			sep=","
		done
		printf '\n  '
	fi
	printf ']\n}\n'
}

if [ "${1:-}" = "config-check" ]; then
	if [ "${2:-}" = "--json" ] || [ "${2:-}" = "-j" ]; then
		run_config_check "json"
	else
		run_config_check "text"
	fi
	exit $?
fi
if [ "${1:-}" = "doctor" ] || [ "${1:-}" = "/bin/doctor" ]; then
	exec /bin/doctor
fi
if [ "${1:-}" = "cron-list" ] || [ "${1:-}" = "/bin/cron-list" ]; then
	exec /bin/cron-list
fi
if [ "${1:-}" = "snapshot-export" ] || [ "${1:-}" = "/bin/snapshot-export" ]; then
	shift
	exec /bin/snapshot-export "$@"
fi
if [ "${1:-}" = "forget-preview" ] || [ "${1:-}" = "/bin/forget-preview" ]; then
	shift
	exec /bin/forget-preview "$@"
fi
if [ "${1:-}" = "mount-snapshot" ] || [ "${1:-}" = "/bin/mount-snapshot" ]; then
	shift
	exec /bin/mount-snapshot "$@"
fi
if [ "${1:-}" = "unlock" ] || [ "${1:-}" = "/bin/unlock" ]; then
	shift
	exec /bin/unlock "$@"
fi
if [ "${1:-}" = "sources-report" ] || [ "${1:-}" = "/bin/sources-report" ]; then
	shift
	exec /bin/sources-report "$@"
fi
if [ "${1:-}" = "init-repo" ] || [ "${1:-}" = "/bin/init-repo" ]; then
	shift
	exec /bin/init-repo "$@"
fi
if [ "${1:-}" = "notify-test" ] || [ "${1:-}" = "/bin/notify-test" ]; then
	shift
	exec /bin/notify-test "$@"
fi
if [ "${1:-}" = "restore-test" ] || [ "${1:-}" = "/bin/restore-test" ]; then
	shift
	exec /bin/restore-test "$@"
fi

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO="$(mask_repository "${RESTIC_REPOSITORY}")"
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

# Build --cacert flags from RESTIC_CACERT (no-op when unset).
build_restic_cacert_args

# Releasestring (ingesteld bij image build via build-arg, zie Dockerfile)
RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

# Replicate is the replacement name for the older "sync/bisync" surface.
# Keep legacy SYNC_* env vars working until 3.0.0, but prefer REPLICATE_* for
# new deployments and for all cron/log labels written by this entrypoint.
if [ -n "${SYNC_CRON:-}" ] && { [ -z "${REPLICATE_CRON:-}" ] || [ "${REPLICATE_CRON:-}" = "" ]; }; then
	REPLICATE_CRON="${SYNC_CRON}"
	export REPLICATE_CRON
	echo "⚠️ SYNC_CRON is deprecated; rename to REPLICATE_CRON (will be removed in 3.0.0)."
fi
if [ -n "${SYNC_JOB_FILE:-}" ] && { [ -z "${REPLICATE_JOB_FILE:-}" ] || [ "${REPLICATE_JOB_FILE:-}" = "/config/replicate_jobs.txt" ]; }; then
	REPLICATE_JOB_FILE="${SYNC_JOB_FILE}"
	export REPLICATE_JOB_FILE
	echo "⚠️ SYNC_JOB_FILE is deprecated; rename to REPLICATE_JOB_FILE (will be removed in 3.0.0)."
fi
if [ -n "${SYNC_JOB_ARGS:-}" ] && { [ -z "${REPLICATE_JOB_ARGS:-}" ] || [ "${REPLICATE_JOB_ARGS:-}" = "" ]; }; then
	REPLICATE_JOB_ARGS="${SYNC_JOB_ARGS}"
	export REPLICATE_JOB_ARGS
	echo "⚠️ SYNC_JOB_ARGS is deprecated; rename to REPLICATE_JOB_ARGS (will be removed in 3.0.0)."
fi
if [ -n "${SYNC_VERBOSE:-}" ] && { [ -z "${REPLICATE_VERBOSE:-}" ] || [ "${REPLICATE_VERBOSE:-}" = "ON" ]; }; then
	REPLICATE_VERBOSE="${SYNC_VERBOSE}"
	export REPLICATE_VERBOSE
	echo "⚠️ SYNC_VERBOSE is deprecated; rename to REPLICATE_VERBOSE (will be removed in 3.0.0)."
fi
if [ -n "${SYNC_BISYNC_CHECK_ACCESS:-}" ] && { [ -z "${REPLICATE_BISYNC_CHECK_ACCESS:-}" ] || [ "${REPLICATE_BISYNC_CHECK_ACCESS:-}" = "OFF" ]; }; then
	REPLICATE_BISYNC_CHECK_ACCESS="${SYNC_BISYNC_CHECK_ACCESS}"
	export REPLICATE_BISYNC_CHECK_ACCESS
	echo "⚠️ SYNC_BISYNC_CHECK_ACCESS is deprecated; rename to REPLICATE_BISYNC_CHECK_ACCESS (will be removed in 3.0.0)."
fi

echo "🌟 *************************************************"
echo "🌟 ***           Restic Backup Helper            ***"
echo "🌟 *************************************************"
echo ""

echo "🚀 Starting container Restic Backup Helper '${HOSTNAME:-}' on: $(date '+%Y-%m-%d %a %H:%M:%S')..."
echo "📦 Release: ${RELEASE}"
echo ""

# Mount NFS if target is specified
if [ -n "${NFS_TARGET:-}" ]; then
	echo "📂 Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
	if ! mount -o nolock -v "${NFS_TARGET}" /mnt/restic; then
		echo "❌ NFS mount failed for target '${NFS_TARGET}' on /mnt/restic; aborting startup."
		exit 1
	fi
fi

# Check if repository exists

if [ "${RESTIC_CHECK_REPOSITORY_STATUS:-}" == "ON" ]; then
	echo "🔍 Checking repository status..."

	# Use `restic cat config` for the probe: it returns exit code 10 when the
	# repository does not exist (a stable contract since restic 0.13). Other
	# non-zero codes (12 wrong password, 1 generic, network/DNS, etc.) must NOT
	# trigger a blind `restic init`, which would either fail loudly or, worse,
	# corrupt expectations on a healthy remote that is briefly unreachable.
	# if/else captures the rc safely under `set -e`.
	if probe_output="$(restic "${RESTIC_CACERT_ARGS[@]}" cat config 2>&1 >/dev/null)"; then
		probe_status=0
	else
		probe_status=$?
	fi
	echo "ℹ️ Repository probe status: ${probe_status}"

	case "${probe_status}" in
	0)
		echo "✅ Restic repository '${MASKED_REPO}' attached and accessible."
		;;
	10)
		echo "🆕 Restic repository '${MASKED_REPO}' does not exist (probe exit 10). Running restic init."
		if restic "${RESTIC_CACERT_ARGS[@]}" init; then
			init_status=0
		else
			init_status=$?
		fi
		echo "ℹ️ Repository initialization status: ${init_status}"

		if [ "${init_status}" -ne 0 ]; then
			echo "❌ Failed to initialize the repository: '${MASKED_REPO}'"
			echo "🔓 Unlocking the repository: '${MASKED_REPO}'"
			restic "${RESTIC_CACERT_ARGS[@]}" unlock --remove-all || true
			exit 1
		fi
		;;
	*)
		echo "❌ Repository probe failed for '${MASKED_REPO}' with exit code ${probe_status}; not running 'restic init' to avoid masking a transient failure (auth, network, DNS, TLS, ...)."
		if [ -n "${probe_output}" ]; then
			echo "ℹ️ Restic stderr from probe:"
			printf '%s\n' "${probe_output}"
		fi
		echo "ℹ️ Set RESTIC_CHECK_REPOSITORY_STATUS to anything other than ON to skip this probe (and the auto-init)."
		exit 1
		;;
	esac
else
	echo "✅ Assuming repository '${MASKED_REPO}' is online..."
fi

echo "⏰ Setting up backup cron job with expression: ${BACKUP_CRON:-}"
echo "${BACKUP_CRON:-} /bin/locked_run backup /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1" >/var/spool/cron/crontabs/root

# Setup check cron job if specified; otherwise log explicitly that the
# optional schedule is disabled so operators can confirm what is (and isn't)
# scheduled at a glance instead of discovering the silent skip later.
if [ -n "${CHECK_CRON:-}" ]; then
	echo "⏰ Setting up check cron job with expression: ${CHECK_CRON}"
	echo "${CHECK_CRON} /bin/locked_run check /var/run/check.lock /bin/check >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
else
	echo "ℹ️ Check cron disabled (CHECK_CRON empty)"
fi

# Setup replicate cron job if specified
if [ -n "${REPLICATE_CRON:-}" ]; then
	echo "⏰ Setting up replicate cron job with expression: ${REPLICATE_CRON}"
	echo "${REPLICATE_CRON} /bin/locked_run replicate /var/run/replicate.lock /bin/replicate >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
else
	echo "ℹ️ Replicate cron disabled (REPLICATE_CRON empty)"
fi

# Setup standalone forget cron job if specified. When set, /bin/backup
# detects FORGET_CRON and skips its inline post-backup `restic forget`
# so the repository's exclusive forget-lock is only ever taken by this
# dedicated maintenance window (key win on multi-host repositories,
# where two parallel backups otherwise race for the same lock and one
# returns exit 11). RESTIC_FORGET_ARGS is reused verbatim.
if [ -n "${FORGET_CRON:-}" ]; then
	echo "⏰ Setting up forget cron job with expression: ${FORGET_CRON}"
	echo "${FORGET_CRON} /bin/locked_run forget /var/run/forget.lock /bin/forget >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
else
	echo "ℹ️ Forget cron disabled (FORGET_CRON empty); post-backup forget still runs inline in /bin/backup when RESTIC_FORGET_ARGS is set."
fi

# Setup standalone prune cron job if specified (decouples pack reclaim
# from the cheaper retention metadata work).
if [ -n "${PRUNE_CRON:-}" ]; then
	echo "⏰ Setting up prune cron job with expression: ${PRUNE_CRON}"
	echo "${PRUNE_CRON} /bin/locked_run prune /var/run/prune.lock /bin/prune >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
else
	echo "ℹ️ Prune cron disabled (PRUNE_CRON empty)"
fi

echo "⏰ Setting up rotate log cron job with expression: ${ROTATE_LOG_CRON:-}"
echo "${ROTATE_LOG_CRON:-} /bin/locked_run rotate_log /var/run/rotate_log.lock /bin/rotate_log >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root

# Start the cron daemon
touch /var/log/cron.log
crond

echo "✅ Container started successfully."

# Execute any additional commands passed to the script
exec "$@"
