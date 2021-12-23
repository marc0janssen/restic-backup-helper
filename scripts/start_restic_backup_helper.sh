#!/bin/sh

# Name: Restic Backup Helper
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-12-20 17:40:49
# update: 2021-12-20 17:40:53

hostname="resticnode1"

docker run -d --cap-add DAC_READ_SEARCH \
	--hostname=${hostname} \
	--name=restic-backup-helper \
	--restart=always \
	-e RESTIC_PASSWORD_FILE="/config/password.txt" \
	-e RESTIC_TAG="${hostname}" \
	-e BACKUP_CRON="*/15 * * * *" \
	-e RESTIC_FORGET_ARGS="--prune --keep-hourly 24 --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10" \
	-v /etc/localtime:/etc/localtime:ro \
	-v ~/test-data:/data \
	-v ~/test-repo/:/mnt/restic \
	-v /path/to/config/:/config \
 	marc0janssen/restic-backup-helper:latest
