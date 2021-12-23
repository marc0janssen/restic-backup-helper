#!bin/sh

echo "Starting container ..."

echo "Creating user: restic:users"
adduser -G users -S -s /sbin/nologin restic
echo "Adding restic to 'wheel''"
adduser restic wheel
echo "Adding 'wheel' to sudoers"
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel

if [ -n "${NFS_TARGET}" ]; then
    echo "Mounting NFS based on NFS_TARGET: ${NFS_TARGET}"
    mount -o nolock -v ${NFS_TARGET} /mnt/restic
fi

restic snapshots &>/dev/null
status=$?
echo "Check Repo status $status"

if [ $status != 0 ]; then
    echo "Restic repository '${RESTIC_REPOSITORY}' does not exists. Running restic init."
    restic init

    init_status=$?
    echo "Repo init status $init_status"

    if [ $init_status != 0 ]; then
        echo "Failed to init the repository: '${RESTIC_REPOSITORY}'"
        exit 1
    fi

    if [ -d "${RESTIC_REPOSITORY}" ]; then
        echo "Setting ownership for restic repository '${RESTIC_REPOSITORY}' to 'restic:users'."
        chown -R restic:users ${RESTIC_REPOSITORY}

        owner_status=$?
        echo "Repo ownership status $owner_status"

        if [ $owner_status != 0 ]; then
            echo "Failed to set ownership for repository: '${RESTIC_REPOSITORY}'"
            exit 1
        fi
    fi
fi



echo "Setup backup cron job with cron expression BACKUP_CRON: ${BACKUP_CRON}"
echo "${BACKUP_CRON} /usr/bin/flock -n /home/restic/backup.lock /bin/backup >> /home/restic/cron.log 2>&1" > /var/spool/cron/crontabs/restic

# Make sure the file exists before we start tail
touch /home/restic/cron.log
chown restic:users /home/restic/cron.log

# start the cron deamon
crond

# Extended attribute to the restic binary
mkdir ~restic/bin
cp /usr/bin/restic ~restic/bin/
chown root:wheel ~restic/bin/restic
chmod 750 ~restic/bin/restic
setcap cap_dac_read_search=+ep ~restic/bin/restic

echo "Container started."

exec "$@"