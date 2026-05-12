#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Helper
# Description: Container startup script for Restic Backup Helper
# =========================================================

set -Eeuo pipefail

run_config_check() {
	local err=0
	local replicate_cron sjf rc_file

	echo "[config-check] Validating configuration..."
	if [ -z "${RESTIC_REPOSITORY:-}" ]; then
		echo "[config-check] ERROR: RESTIC_REPOSITORY is empty." >&2
		err=1
	fi
	if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
		if [ ! -r "${RESTIC_PASSWORD_FILE}" ]; then
			echo "[config-check] ERROR: RESTIC_PASSWORD_FILE is not readable: ${RESTIC_PASSWORD_FILE}" >&2
			err=1
		fi
	elif [ -z "${RESTIC_PASSWORD:-}" ]; then
		echo "[config-check] ERROR: Set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE." >&2
		err=1
	fi
	if [ -z "${RESTIC_TAG:-}" ]; then
		echo "[config-check] ERROR: RESTIC_TAG is empty." >&2
		err=1
	fi
	if [ -z "${BACKUP_ROOT_DIR:-}" ] && [ -z "${RESTIC_JOB_ARGS:-}" ]; then
		echo "[config-check] ERROR: BACKUP_ROOT_DIR and RESTIC_JOB_ARGS are both empty (no backup paths)." >&2
		err=1
	fi
	if [[ "${RESTIC_REPOSITORY:-}" == rclone:* ]]; then
		rc_file="${RCLONE_CONFIG:-/config/rclone.conf}"
		if [ ! -r "${rc_file}" ]; then
			echo "[config-check] ERROR: Rclone repository configured but ${rc_file} is not readable." >&2
			err=1
		fi
	fi
	replicate_cron="${REPLICATE_CRON:-${SYNC_CRON:-}}"
	if [ -n "${replicate_cron}" ]; then
		sjf="${REPLICATE_JOB_FILE:-/config/replicate_jobs.txt}"
		if [ -n "${SYNC_JOB_FILE:-}" ] && { [ -z "${REPLICATE_JOB_FILE:-}" ] || [ "${REPLICATE_JOB_FILE:-}" = "/config/replicate_jobs.txt" ]; }; then
			sjf="${SYNC_JOB_FILE}"
		fi
		if [ ! -s "${sjf}" ]; then
			echo "[config-check] WARN: REPLICATE_CRON is set but ${sjf} is missing or empty." >&2
		fi
	fi
	if [ -n "${RESTIC_CACERT:-}" ] && [ ! -r "${RESTIC_CACERT}" ]; then
		echo "[config-check] ERROR: RESTIC_CACERT is set but file is not readable: ${RESTIC_CACERT}" >&2
		err=1
	fi
	if [ "${err}" -eq 0 ]; then
		echo "[config-check] OK."
	fi
	return "${err}"
}

if [ "${1:-}" = "config-check" ]; then
	run_config_check
	exit $?
fi
if [ "${1:-}" = "doctor" ] || [ "${1:-}" = "/bin/doctor" ]; then
	exec /bin/doctor
fi
if [ "${1:-}" = "snapshot-export" ] || [ "${1:-}" = "/bin/snapshot-export" ]; then
	shift
	exec /bin/snapshot-export "$@"
fi

# shellcheck source=app/lib.sh
. /bin/lib.sh

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

# Setup standalone prune cron job if specified (decouples retention from
# the post-backup `restic forget` invocation in /bin/backup).
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
