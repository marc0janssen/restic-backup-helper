#!/bin/bash

echo "*************************************************"
echo "*** Restic Backup Helper version 1.5.2-0.17.3 ***"
echo "*************************************************"
echo ""

echo "Starting container Restic Backup Helper '${HOSTNAME}'..."
echo ""

if [ -n "${NFS_TARGET}" ]; then
    echo "Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
    mount -o nolock -v "${NFS_TARGET}" /mnt/restic
fi

#sudo -E -u restic /home/restic/bin/restic snapshots &>/dev/null
restic snapshots &>/dev/null

status=$?
echo "Check Repo status $status"

if [ $status != 0 ]; then
    echo "Restic repository '${RESTIC_REPOSITORY}' does not exists. Running restic init."
#    sudo -E -u restic /home/restic/bin/restic init
    restic init

    init_status=$?
    echo "Repo init status $init_status"

    if [ $init_status != 0 ]; then
        echo "Failed to init the repository: '${RESTIC_REPOSITORY}'"
        echo "Unlocking the repository: '${RESTIC_REPOSITORY}'"
#        sudo -E -u restic /home/restic/bin/restic unlock --remove-all
        restic unlock --remove-all
        exit 1
    fi
else
    echo "Restic repository '${RESTIC_REPOSITORY}' attached and accessible."
fi

echo "Setup backup cron job with cron expression BACKUP_CRON: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/backup >> /var/log/cron.log 2>&1" > /var/spool/cron/crontabs/root
echo "Setup check cron job with cron expression CHECK_CRON: ${CHECK_CRON}"
echo "${CHECK_CRON} /usr/bin/flock -n /var/run/cron.lock /bin/check >> /var/log/cron.log 2>&1" >> /var/spool/cron/crontabs/root


# start the cron deamon
touch /var/log/cron.log
crond

echo "Container started."

exec "$@"