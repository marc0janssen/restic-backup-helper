#!bin/sh

echo "*************************************************"
echo "*** Restic Backup Helper version 1.1.2-0.12.1 ***"
echo "*************************************************"
echo ""


echo "Starting container Restic Backup Helper '${HOSTNAME}'..."
echo ""

if [ -n "${NFS_TARGET}" ]; then
    echo "Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
    mount -o nolock -v ${NFS_TARGET} /mnt/restic
fi

restic snapshots &>/dev/null
status=$?
echo "Check Repo status $status"

if [ $status != 0 ]; then
    echo "Restic repository '${RESTIC_REPOSITORY}' does not exists. Running restic init."
    sudo -E -u restic /home/restic/bin/restic init

    init_status=$?
    echo "Repo init status $init_status"

    if [ $init_status != 0 ]; then
        echo "Failed to init the repository: '${RESTIC_REPOSITORY}'"
        exit 1
    fi
else
    echo "Restic repository '${RESTIC_REPOSITORY}' attached and accessible."
fi

echo "Setup backup cron job with cron expression BACKUP_CRON: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /home/restic/backup.lock /bin/backup >> /home/restic/cron.log 2>&1" > /var/spool/cron/crontabs/restic

# Make sure the file exists before we start tail
touch /home/restic/cron.log
chown restic:users /home/restic/cron.log

# start the cron deamon
crond

echo "Container started."

exec "$@"