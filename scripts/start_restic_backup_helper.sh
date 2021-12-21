#!/bin/sh

# Name: Restic Backup Helper
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-12-20 17:40:49
# update: 2021-12-20 17:40:53

hostname="resticnode1"

docker run -d \
	--hostname=${hostname} \
	--name=restic-backup-helper \
	--restart=always \
	-e RESTIC_PASSWORD="test" \
	-e RESTIC_TAG="${hostname}" \
	-e BACKUP_CRON="*/15 * * * *" \
	-e RESTIC_FORGET_ARGS="--prune --keep-hourly 24 --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10" \
	-v /etc/localtime:/etc/localtime:ro \
	-v ~/test-data:/data \
	-v ~/test-repo/:/mnt/restic \
 	marc0janssen/restic-backup-helper:latest
