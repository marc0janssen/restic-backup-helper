#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Backup Helper
# Description: Container startup script for Restic Backup Helper
# =========================================================

# Masked variables with ******
MASKED_REPO=$(echo "${RESTIC_REPOSITORY}" | sed -E 's#(https://[^:]+:)[^@]+(@)#\1***\2#')

# Get releasenumber from file
RELEASE=$(cat /.release)

echo "🌟 *************************************************"
echo "🌟 ***           Restic Backup Helper            ***"
echo "🌟 *************************************************"
echo ""

echo "🚀 Starting container Restic Backup Helper '${HOSTNAME}' on: $(date '+%Y-%m-%d %a %H:%M:%S')..."
echo "📦 Release: ${RELEASE}"
echo ""

# If the RESTIC_PUBLICKEY variable is set, add the --cacert option with its value; otherwise, leave it empty.
#[ -n "${RESTIC_PUBLICKEY}" ] && CACERT_OPTION="--cacert ${RESTIC_PUBLICKEY}" || CACERT_OPTION=""

# Mount NFS if target is specified
if [ -n "${NFS_TARGET}" ]; then
    echo "📂 Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
    mount -o nolock -v "${NFS_TARGET}" /mnt/restic
fi

# Check if repository exists

if [ "${RESTIC_CHECK_REPOSITORY_STATUS}" == "ON" ]; then
    echo "🔍 Checking repository status..."

    restic snapshots &>/dev/null
    status=$?
    echo "ℹ️ Repository check status: $status"

    # Initialize repository if it doesn't exist
    if [ $status -ne 0 ]; then
        echo "🆕 Restic repository '${MASKED_REPO}' does not exist. Running restic init."
        restic init
        init_status=$?
        echo "ℹ️ Repository initialization status: $init_status"

        if [ $init_status -ne 0 ]; then
            echo "❌ Failed to initialize the repository: '${MASKED_REPO}'"
            echo "🔓 Unlocking the repository: '${MASKED_REPO}'"
            restic unlock --remove-all
            exit 1
        fi
    else
        echo "✅ Restic repository '${MASKED_REPO}' attached and accessible."
    fi
else
    echo "✅ Assuming repository '${MASKED_REPO}' is online..."
fi

echo "⏰ Setting up backup cron job with expression: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1" > /var/spool/cron/crontabs/root

# Setup check cron job if specified
if [ -n "${CHECK_CRON}" ]; then
    echo "⏰ Setting up check cron job with expression: ${CHECK_CRON}"
    echo "${CHECK_CRON} /usr/bin/flock -n /var/run/check.lock /bin/check >> /var/log/cron.log 2>&1" >> /var/spool/cron/crontabs/root
fi

# Setup check cron job if specified
if [ -n "${SYNC_CRON}" ]; then
    echo "⏰ Setting up sync cron job with expression: ${SYNC_CRON}"
    echo "${SYNC_CRON} /usr/bin/flock -n /var/run/bisync.lock /bin/bisync >> /var/log/cron.log 2>&1" >> /var/spool/cron/crontabs/root
fi

echo "⏰ Setting up rotate log cron job with expression: ${ROTATE_LOG_CRON}"
echo "${ROTATE_LOG_CRON} /usr/bin/flock -n /var/run/rotate_log.lock /bin/rotate_log >> /var/log/cron.log 2>&1" >> /var/spool/cron/crontabs/root

# Start the cron daemon
touch /var/log/cron.log
crond

echo "✅ Container started successfully."

# Execute any additional commands passed to the script
exec "$@"
