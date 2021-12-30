#!bin/sh

echo "*************************************************"
echo "*** Restic Backup Helper version 1.3.0-0.12.1 ***"
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
        sudo -E -u restic /home/restic/bin/restic unlock
        exit 1
    fi
else
    echo "Restic repository '${RESTIC_REPOSITORY}' attached and accessible."
fi

echo "Setup backup cron job with cron expression BACKUP_CRON: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /home/restic/cron.lock /bin/backup >> /home/restic/log/cron.log 2>&1" > /var/spool/cron/crontabs/restic
echo "Setup check cron job with cron expression CHECK_CRON: ${CHECK_CRON}"
echo "${CHECK_CRON} /usr/bin/flock -n /home/restic/cron.lock /bin/check >> /home/restic/log/cron.log 2>&1" >> /var/spool/cron/crontabs/restic

# Make sure the file exists before we start tail
touch /home/restic/log/cron.log
chmod -R a+rwx,u-x,g-x,o-wx /log/*
chown -R restic:users /log/*

# start the cron deamon
crond

echo "Container started."

exec "$@"