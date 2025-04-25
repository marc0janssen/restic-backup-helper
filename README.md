# Restic Backup Helper

A Docker container designed to automate [Restic backups](https://restic.net).

For a more detailed configuration guide, check [📟 Escaping USA Tech, Bye Bye Dropbox, Hello! Jottacloud](https://micro.mjanssen.nl/2025/03/25/escaping-usa-tech-bye-bye.html)

This solution offers scheduled Restic backups with extensive configuration options. Additionally, it provides a seamless syncing solution for cloud provider folders, enhancing data protection and integration.

## Key Features

- **Simple Setup & Maintenance**: Streamlined configuration for quick deployment
- **Versatile Target Support**: Compatible with Local, NFS, SFTP, AWS S3, and Rclone repositories
- **Built-in Mounting**: Support for `restic mount` within the container to browse backup archives
- **Flexible Source Configuration**: Define backup sources via `BACKUP_ROOT_DIR` (defaults to `/data`)
- **Selective Email Notifications**: Option to receive logs only when backups fail
- **Comprehensive Logging**: All logs exposed in `/var/log` for external monitoring
- **Repository Integrity Checks**: Scheduled `restic check` operations via cron
- **Bidirectional Sync**: Support for synchronising between local directories and remote targets

## Docker Image

Available at [marc0janssen/restic-backup-helper](https://hub.docker.com/repository/docker/marc0janssen/restic-backup-helper/)

### Release

release: 1.8.89-0.18.0

**Stable**
```shell
docker pull marc0janssen/restic-backup-helper:latest
docker pull marc0janssen/restic-backup-helper:1.8.89-0.18.0
```

**Development (Experimental)**
```shell
docker pull marc0janssen/restic-backup-helper:develop
docker pull marc0janssen/restic-backup-helper:1.8.88-0.18.0-dev
```

## Changelog

For the latest updates, please see the [Changelog on GitHub](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)

## Hooks

The container supports hooks for its three primary functions:

* **Backup**: Creates backups of your data to a repository
* **Check**: Verifies the consistency of a repository
* **Sync**: Performs bidirectional syncing between a local directory and a Rclone target

Each function has pre- and post-execution hooks:

* `/hooks/pre-backup.sh` and `/hooks/post-backup.sh`
* `/hooks/pre-check.sh` and `/hooks/post-check.sh`
* `/hooks/pre-sync.sh` and `/hooks/post-sync.sh`

To implement hooks, mount your scripts to the container's `/hooks` directory:

```shell
-v ~/path/to/your/hooks:/hooks
```

## Container Configuration

### Docker Compose Example

```yaml
version: '3'

services:
  restic-remote:
    container_name: restic-backup-helper
    image: marc0janssen/restic-backup-helper:latest
    healthcheck:
      test: ["CMD", "restic", "-r", "rclone:jottacloud:backups", "cat", "config"]
      interval: 15m
      timeout: 10s
      start_period: 1m
      start_interval: 10s
    restart: always
    hostname: supernode
    cap_add:
      - DAC_READ_SEARCH
      - SYS_ADMIN
    devices:
      - /dev/fuse
    environment:
      - RESTIC_PASSWORD=Pa55w0rd
      - RESTIC_TAG=your_tags_here
      - RESTIC_FORGET_ARGS=--prune --keep-hourly 24 --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10
      - RESTIC_REPOSITORY=rclone:jottacloud:backups
      - RESTIC_JOB_ARGS=--exclude-file /config/exclude_files.txt
      - BACKUP_CRON=0 1,13 * * *
      - BACKUP_ROOT_DIR=/volume1/data
      - MAILX_RCPT=your_email@example.com
      - MAILX_ON_ERROR=OFF
      - CHECK_CRON=37 1 1 * *
      - RCLONE_CONFIG=/config/rclone.conf
      - SYNC_JOB_FILE=/config/sync_jobs.txt
      - SYNC_JOB_ARGS=--exclude-from exclude_sync.txt
      - SYNC_CRON=*/10 * * * *
      - TZ=Europe/London
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /path/to/your/hooks:/hooks
      - /path/to/your/log:/var/log
      - /path/to/your/data:/data
      - /path/to/your/config/:/config
      - /path/to/your/config/msmtprc:/etc/msmtprc
      - /volume1/data:/volume1/data
```

To access the container shell:

```shell
sudo docker exec -ti restic-backup-helper /bin/sh
```

## Log Files

Logs are stored in `/var/log` and can be mounted to the host:

```shell
-v /path/to/your/log:/var/log
```

Available log files include:

* `backup-error-last.log` - Most recent backup error log
* `backup-last.log` - Most recent backup log
* `check-error-last.log` - Most recent repository check error log
* `check-last.log` - Most recent repository check log
* `cron.log` - Active cron log
* `sync-error-last.log` - Most recent sync error log
* `sync-last.log` - Most recent sync log
* `rotate-last.log` - Most recent rotate log

## Container Usage Examples

Assuming the container name is `restic-backup-helper`:

```shell
# Execute the internal backup function
sudo docker exec -ti restic-backup-helper /bin/backup

# Execute the internal check function
sudo docker exec -ti restic-backup-helper /bin/check

# List snapshots in your repository
sudo docker exec -ti restic-backup-helper restic snapshots

# Create a backup of a specific directory
sudo docker exec -ti restic-backup-helper restic backup /mnt/data

# Restore from a specific snapshot
sudo docker exec -ti restic-backup-helper restic restore  --target /mnt/data
```

## Backup Operations

### Manual Backup Execution

To run a backup manually, independent of the scheduled cron job:

```shell
docker exec -ti restic-backup-helper /bin/backup
```

### Backup Specific Paths

```shell
docker exec -ti restic-backup-helper restic backup /data/path/to/dir --tag my-tag
```

## Repository Verification

To manually verify backup integrity and consistency:

```shell
docker exec -ti restic-backup-helper /bin/check
```

## Data Restoration

For data restoration, you might want to mount a separate volume at `/restore` to prevent overwriting existing data.

First, identify your snapshot ID:

```shell
docker exec -ti restic-backup-helper restic snapshots
```

Example output:
```
09e7818a  2025-03-23 20:05:01  supernode       tag       /home/admin/data      238.157 MiB
```

Then restore using:

```shell
docker exec -ti restic-backup-helper restic restore --include /home/admin/data --target / 09e7818a
```

## Mount Functionality

To use `restic mount /mnt/restic`, add these parameters when starting the container:
```
--privileged --cap-add=SYS_ADMIN --device /dev/fuse
```

## Environment variables

* `RESTIC_REPOSITORY` - the location of the restic repository. Default `/mnt/restic`. For S3: `s3:https://s3.amazonaws.com/BUCKET_NAME`

* `RESTIC_PASSWORD` - the password for the restic repository. Will also be used for restic init during first start when the repository is not initialized.

* `RESTIC_TAG` - Optional. To tag the images created by the container.

* `NFS_TARGET` - Optional. If set the given NFS is mounted, i.e. `mount -o nolock -v ${NFS_TARGET} /mnt/restic`. `RESTIC_REPOSITORY` must remain it's default value!

* `BACKUP_CRON` - A cron expression to run the backup. Note: cron daemon uses UTC time zone. Default: `0 */6 * * *` aka every 6 hours.

* `CHECK_CRON` - A cron expression to run the repository check. Note: cron daemon uses UTC time zone.

* `BACKUP_ROOT_DIR` - The source path you like to backup. If not specified '/data' is assumed.

* `RESTIC_FORGET_ARGS` - Optional. Only if specified `restic forget` is run with the given arguments after each backup. Example value: `-e "RESTIC_FORGET_ARGS=--prune --keep-last 10 --keep-hourly 24 --keep-daily 7 --keep-weekly 52 --keep-monthly 120 --keep-yearly 100"`

* `RESTIC_JOB_ARGS` - Optional. Allows to specify extra arguments to the backup job such as limiting bandwith with `--limit-upload` or excluding file masks with `--exclude`.

* `RESTIC_CHECK_ARGS` - Optional. Allows to specify extra arguments to the check job such as --check-unused, --read-data, --read-data-subset

* `RESTIC_CHECK_REPOSITORY_STATUS` - Optional. Check if repository is online on container startup. Default: `ON`

* `AWS_ACCESS_KEY_ID` - Optional. When using restic with AWS S3 storage.

* `AWS_SECRET_ACCESS_KEY` - Optional. When using restic with AWS S3 storage.

* `MAILX_RCPT` - Optional. If a mailadrress is specified, the content of `/var/log/backup-last.log` is sent via mail after each a backup. A valid msmtprc file is needed in the `/config/` directory.

* `MAILX_ON_ERROR` - Optional. If set to "ON" the MAILX_ON_ERROR will only email the backuplogs if the backup is unsuccessful, e.g. the exitcode of backup is not equal zero. When MAILX_ON_ERROR is set to any other value than "ON", the logs will always be mailed to you.

* `RCLONE_CONFIG` - Optional. Needed when useing RCLONE to access your repository. `/config/rclone.conf` is needed to be setup with `rclone config`. 

* `SYNC_JOB_FILE` - Optional. Needed when setting up a sync folder from your local device to a remote location.  An example is shown below.

* `SYNC_JOB_ARGS` - Optional.  Arguments needed for bisyncing with Rclone. For example `--exclude-from exclude_sync.txt`

* `SYNC_CRON` - Optional.  A cron expression to run the sync. Note: cron daemon uses UTC time zone. Default: `*/5 * * * *` aka every 5 minutes.

* `SYNC_VERBOSE` - Optinal. Determines if the sync logs all in the cron.log. Default: `ON`

* `ROTATE_LOG_CRON` - A cron expression to run the cron.log rotation. Note: cron daemon uses UTC time zone. Default: `0 */6 * * *` aka every 6 hours.

* `CRON_LOG_MAX_SIZE` - The max size of the cron.log before it rotates.

* `MAX_CRON_LOG_ARCHIVES` - The max amount of kept archives.

* `OS_AUTH_URL` - Optional. When using restic with OpenStack Swift container.

* `OS_PROJECT_ID` - Optional. When using restic with OpenStack Swift container.

* `OS_PROJECT_NAME` - Optional. When using restic with OpenStack Swift container.

* `OS_USER_DOMAIN_NAME` - Optional. When using restic with OpenStack Swift container.

* `OS_PROJECT_DOMAIN_ID` - Optional. When using restic with OpenStack Swift container.

* `OS_USERNAME` - Optional. When using restic with OpenStack Swift container.

* `OS_PASSWORD` - Optional. When using restic with OpenStack Swift container.

* `OS_REGION_NAME` - Optional. When using restic with OpenStack Swift container.

* `OS_INTERFACE` - Optional. When using restic with OpenStack Swift container.

* `OS_IDENTITY_API_VERSION` - Optional. When using restic with OpenStack Swift container.


## Volumes

* `/data` - Default backup source directory
* `/log` - Log directory

## Hostname Configuration

Since Restic records the hostname with each snapshot, you may want to set a custom hostname rather than using the Docker container ID:

```
--hostname your-custom-hostname
```

## SFTP Repository Setup

For SFTP repositories, Restic requires password-less SSH login. Mount your `.ssh` directory containing authorized certificates:

```shell
-v ~/.ssh:/root/.ssh
```

Then configure the repository:

```shell
-e "RESTIC_REPOSITORY=sftp:user@host:/tmp/backup"
```

## OpenStack Swift Repository

For Swift repositories, specify the repository and required authentication variables:

```shell
-e "RESTIC_REPOSITORY=swift:backup:/"
-e "RESTIC_PASSWORD=password"
-e "OS_AUTH_URL=https://auth.cloud.ovh.net/v3"
-e "OS_PROJECT_ID=xxxx"
-e "OS_PROJECT_NAME=xxxx"
-e "OS_USER_DOMAIN_NAME=Default"
-e "OS_PROJECT_DOMAIN_ID=default"
-e "OS_USERNAME=username"
-e "OS_PASSWORD=password"
-e "OS_REGION_NAME=SBG"
-e "OS_INTERFACE=public"
-e "OS_IDENTITY_API_VERSION=3"
```

## Rclone Configuration

To use Rclone as a backend, provide the configuration file path:

```shell
-e "RCLONE_CONFIG=/config/rclone.conf"
```

Note: For certain backends (including Jottacloud, Google Drive, and Microsoft OneDrive), Rclone writes data back to the configuration file. Ensure the file is writable by Docker, or the authentication token may become invalid.

## Sync Job Configuration

Example sync job file:

```
# SYNC JOBS
# SOURCE;DESTINATION

/volume1/inbox;jottasync:/inbox
/volume1/photo;jottasync:/photo
```

## Backlog & Changelog
For releases, see: [GitHub Releases](https://github.com/marc0janssen/restic-backup-helper/releases)
For backlog, see: [Github Backlog](https://github.com/marc0janssen/restic-backup-helper/blob/master/BACKLOG.md)
For changelog, see: [Github Changelog](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)

---

*Note: This repository is a fork of [Restic Backup Docker:1.2-0.9.4](https://github.com/lobaro/restic-backup-docker)*
