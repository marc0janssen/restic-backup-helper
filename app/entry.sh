#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Helper
# Description: Container startup script for Restic Backup Helper
# =========================================================

run_config_check() {
	local err=0
	local sjf rc_file

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
	if [ -n "${SYNC_CRON:-}" ]; then
		sjf="${SYNC_JOB_FILE:-/config/sync_jobs.txt}"
		if [ ! -s "${sjf}" ]; then
			echo "[config-check] WARN: SYNC_CRON is set but ${sjf} is missing or empty." >&2
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

# shellcheck source=lib.sh
. /bin/lib.sh

if [ -n "${RESTIC_REPOSITORY}" ]; then
	MASKED_REPO="$(mask_repository "${RESTIC_REPOSITORY}")"
else
	MASKED_REPO="${RESTIC_REPOSITORY}"
fi

# Build --cacert flags from RESTIC_CACERT (no-op when unset).
build_restic_cacert_args

# Releasestring (ingesteld bij image build via build-arg, zie Dockerfile)
RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

echo "🌟 *************************************************"
echo "🌟 ***           Restic Backup Helper            ***"
echo "🌟 *************************************************"
echo ""

echo "🚀 Starting container Restic Backup Helper '${HOSTNAME}' on: $(date '+%Y-%m-%d %a %H:%M:%S')..."
echo "📦 Release: ${RELEASE}"
echo ""

# Mount NFS if target is specified
if [ -n "${NFS_TARGET}" ]; then
	echo "📂 Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
	if ! mount -o nolock -v "${NFS_TARGET}" /mnt/restic; then
		echo "❌ NFS mount failed for target '${NFS_TARGET}' on /mnt/restic; aborting startup."
		exit 1
	fi
fi

# Check if repository exists

if [ "${RESTIC_CHECK_REPOSITORY_STATUS}" == "ON" ]; then
	echo "🔍 Checking repository status..."

	restic "${RESTIC_CACERT_ARGS[@]}" snapshots &>/dev/null
	status=$?
	echo "ℹ️ Repository check status: $status"

	# Initialize repository if it doesn't exist
	if [ $status -ne 0 ]; then
		echo "🆕 Restic repository '${MASKED_REPO}' does not exist. Running restic init."
		restic "${RESTIC_CACERT_ARGS[@]}" init
		init_status=$?
		echo "ℹ️ Repository initialization status: $init_status"

		if [ $init_status -ne 0 ]; then
			echo "❌ Failed to initialize the repository: '${MASKED_REPO}'"
			echo "🔓 Unlocking the repository: '${MASKED_REPO}'"
			restic "${RESTIC_CACERT_ARGS[@]}" unlock --remove-all
			exit 1
		fi
	else
		echo "✅ Restic repository '${MASKED_REPO}' attached and accessible."
	fi
else
	echo "✅ Assuming repository '${MASKED_REPO}' is online..."
fi

echo "⏰ Setting up backup cron job with expression: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1" >/var/spool/cron/crontabs/root

# Setup check cron job if specified
if [ -n "${CHECK_CRON}" ]; then
	echo "⏰ Setting up check cron job with expression: ${CHECK_CRON}"
	echo "${CHECK_CRON} /usr/bin/flock -n /var/run/check.lock /bin/check >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
fi

# Setup check cron job if specified
if [ -n "${SYNC_CRON}" ]; then
	echo "⏰ Setting up sync cron job with expression: ${SYNC_CRON}"
	echo "${SYNC_CRON} /usr/bin/flock -n /var/run/bisync.lock /bin/bisync >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root
fi

echo "⏰ Setting up rotate log cron job with expression: ${ROTATE_LOG_CRON}"
echo "${ROTATE_LOG_CRON} /usr/bin/flock -n /var/run/rotate_log.lock /bin/rotate_log >> /var/log/cron.log 2>&1" >>/var/spool/cron/crontabs/root

# Start the cron daemon
touch /var/log/cron.log
crond

echo "✅ Container started successfully."

# Execute any additional commands passed to the script
exec "$@"
