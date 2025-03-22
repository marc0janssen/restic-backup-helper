#!/bin/bash
# =========================================================
# Restic Backup Helper
# Description: Container startup script for Restic Backup Helper
# =========================================================

echo "🌟 *************************************************"
echo "🌟 *** Restic Backup Helper version 1.5.6-0.17.3 ***"
echo "🌟 *************************************************"
echo ""

echo "🚀 Starting container Restic Backup Helper '${HOSTNAME}'..."
echo ""

# Mount NFS if target is specified
if [ -n "${NFS_TARGET}" ]; then
    echo "📂 Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
    mount -o nolock -v "${NFS_TARGET}" /mnt/restic
fi

# Check if repository exists
echo "🔍 Checking repository status..."
restic snapshots &>/dev/null
status=$?
echo "ℹ️ Repository check status: $status"

# Initialize repository if it doesn't exist
if [ $status -ne 0 ]; then
    echo "🆕 Restic repository '${RESTIC_REPOSITORY}' does not exist. Running restic init."
    restic init
    init_status=$?
    echo "ℹ️ Repository initialization status: $init_status"

    if [ $init_status -ne 0 ]; then
        echo "❌ Failed to initialize the repository: '${RESTIC_REPOSITORY}'"
        echo "🔓 Unlocking the repository: '${RESTIC_REPOSITORY}'"
        restic unlock --remove-all
        exit 1
    fi
else
    echo "✅ Restic repository '${RESTIC_REPOSITORY}' attached and accessible."
fi

# Setup backup cron job if specified
if [ -n "${BACKUP_CRON}" ]; then
    echo "⏰ Setting up backup cron job with expression: ${BACKUP_CRON}"
    echo "${BACKUP_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1" > /var/spool/cron/crontabs/root
fi

# Setup check cron job if specified
if [ -n "${CHECK_CRON}" ]; then
    echo "⏰ Setting up check cron job with expression: ${CHECK_CRON}"
    echo "${CHECK_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/check >> /var/log/cron.log 2>&1" >> /var/spool/cron/crontabs/root
fi

# Start the cron daemon
touch /var/log/cron.log
crond

echo "✅ Container started successfully."

# Execute any additional commands passed to the script
exec "$@"
