# Restic Backup Helper

A docker container to automate [restic backups](https://restic.github.io/)

This container runs restic backups in regular intervals.

* Easy setup and maintanance
* Support for different targets (tested with: Local, NFS, SFTP, AWS)
* Support `restic mount` inside the container to browse the backup files
* DOES NOT run as ROOT in the container so resulting backup is NOT OWNED by ROOT anymore
* Backup source PATH can be set by environment var BACKUP_ROOT_DIR (will default to /data if not set)
* Updated to Restic latest version
* Only email the logs if the backup is not successful if MAILX_ON_ERROR holds "ON" else the logs are emailed every time
* Logs are exposed in /log, setup your container accordingly
* `restic check` CRON available

**Docker Image**: [marc0janssen/restic-backup-helper](https://hub.docker.com/repository/docker/marc0janssen/restic-backup-helper/)

**versions**: Codebase: 1.4.2 - Restic: 0.12.1

Stable

```shell
docker pull marc0janssen/restic-backup-helper:stable
```

```shell
docker pull marc0janssen/restic-backup-helper:1.4.2-0.12.1
```

Latest (experimental)

```shell
docker pull marc0janssen/restic-backup-helper:latest
```

## Changelog

See changelog at [Github](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)

## Example container init

This init backups up to directory "/docker/" as set with BACKUP_ROOT_DIR and "-v /docker/:/docker \".
The point of BACKUP_ROOT_DIR is the attach your own directory and not only "/data".
Now your repository will not only have "/data" entries but meaningful name like in the example "/docker".

```shell
#!/bin/sh

hostname="sumer"
repository="sumer"

docker run -d --cap-add DAC_READ_SEARCH \
    --hostname=${hostname} \
    --name=restic-local \
    --restart=always \
    -e RESTIC_PASSWORD="[your repository password]" \
    -e RESTIC_TAG="${hostname}" \
    -e BACKUP_CRON="20 0-1,7-23 * * *" \
    -e RESTIC_FORGET_ARGS="--prune --keep-hourly 24 --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10" \
    -e RESTIC_REPOSITORY="/backup/${repository}" \
    -e BACKUP_ROOT_DIR="/docker/" \
    -e RESTIC_JOB_ARGS="--exclude-file /config/exclude_files.txt" \
    -e MAILX_ARGS="-r 'from@mail.tld' -S smtp='mail.server.tld:587' -S smtp-use-starttls -S smtp-auth=login -S smtp-auth-user='login@mail.tld' -S smtp-auth-password='[password]' 'to@mail.tld'" \
    -e MAILX_ON_ERROR="ON" \
    -v /etc/localtime:/etc/localtime:ro \
    -v /docker/restic-backup-helper/hooks:/hooks \
    -v /docker/restic-backup-helper/data:/data \
    -v /docker/restic-backup-helper/log:/log \
    -v /docker/restic-backup-helper/config/:/config \
    -v /mnt/backup/:/backup \
    -v /docker/:/docker \
    marc0janssen/restic-backup-helper:latest
```

## Hooks

If you need to execute a script before or after each backup,
you need to add your hook script in the container folder `/hooks`:

```shell
-v ~/home/user/hooks:/hooks
```

Call your pre backup script `pre-backup.sh` and post backup script `post-backup.sh`

Please don't hesitate to report any issue you find. **Thanks.**

## Test the container

Clone this repository

```shell
git clone https://github.com/marc0janssen/restic-backup-helper.git
cd restic-backup-helper
```

Build the container. The container is named `backup-test`

```shell
./build.sh
```

Run the container.

```shell
./run.sh
```

This will run the container `backup-test` with the name  `backup-test`. Existing containers with that names are completly removed automatically.

The container will backup `~/test-data` to a repository with password `test` at `~/test-repo` every minute. The repository is initialized automatically by the container.

To enter your container execute

```shell
docker exec -ti backup-test /bin/sh
```

Now you can use restic [as documented](https://restic.readthedocs.io/en/stable/), e.g. try to run `restic snapshots` to list all your snapshots.

## Logfiles

Logfiles are inside the container. If needed you can create volumes for them.

```shell
docker logs [container]
```

Since Restic runs not under root, you need to set the access-rights to the directory on the host accordingly. This mean +w on the group and the group should be set to "users" or "wheel". If you don't want every user to access them, choose "wheel".

```shell
chmod -R g+w ./log/
chgrp -R wheel ./log/
```

Shows `/home/restic/log/cron.log`

Additionally you can see the the full log, including restic output, of the last execution in `/home/restic/log/backup-last.log`. When the backup fails the log is copied to `/home/restic/log/restic-error-last.log`. If configured, you can find the full output of the mail notification in `/home/restic/log/mail-last.log`.

## Use the running container

Assuming the container name is `restic-backup-var`

You can execute restic with `docker exec -ti restic-backup-var restic`

## Backup

To execute a backup manually independent of the CRON run:

```shell
docker exec -ti restic-backup-var /bin/backup
```

Backup a single file or directory

```shell
docker exec -ti restic-backup-var restic backup /data/path/to/dir --tag my-tag
```

## Restore

You might want to mount a separate hostvolume at e.g. `/restore` to not override existing data while restoring.

Get your snapshot ID with

```shell
docker exec -ti restic-backup-var restic snapshots
```

e.g. `abcdef12`

```shell
docker exec -ti restic-backup-var restic restore --include /data/path/to/files --target / abcdef12
```

The target is `/` since all data backed up should be inside the host mounted `/data` dir. If you mount `/restore` you should set `--target /restore` and data will end up in `/restore/data/path/to/files`.

## Mount

In order to use `restic mount /mnt/restic` add `--privileged --cap-add=SYS_ADMIN --device /dev/fuse` to your container init.

## Customize the Container

The container is setup by setting [environment variables](https://docs.docker.com/engine/reference/run/#/env-environment-variables) and [volumes](https://docs.docker.com/engine/reference/run/#volume-shared-filesystems).

## Environment variables

* `RESTIC_REPOSITORY` - the location of the restic repository. Default `/mnt/restic`. For S3: `s3:https://s3.amazonaws.com/BUCKET_NAME`
* `RESTIC_PASSWORD` - the password for the restic repository. Will also be used for restic init during first start when the repository is not initialized.
* `RESTIC_TAG` - Optional. To tag the images created by the container.
* `NFS_TARGET` - Optional. If set the given NFS is mounted, i.e. `mount -o nolock -v ${NFS_TARGET} /mnt/restic`. `RESTIC_REPOSITORY` must remain it's default value!
* `BACKUP_CRON` - A cron expression to run the backup. Note: cron daemon uses UTC time zone. Default: `0 */6 * * *` aka every 6 hours.
* `CHECK_CRON` - A cron expression to run the repository check. Note: cron daemon uses UTC time zone. Default: `0 */6 * * *` aka every 6 hours.
* `BACKUP_ROOT_DIR` - The source path you like to backup. If not specified '/data' is assumed.
* `RESTIC_FORGET_ARGS` - Optional. Only if specified `restic forget` is run with the given arguments after each backup. Example value: `-e "RESTIC_FORGET_ARGS=--prune --keep-last 10 --keep-hourly 24 --keep-daily 7 --keep-weekly 52 --keep-monthly 120 --keep-yearly 100"`
* `RESTIC_JOB_ARGS` - Optional. Allows to specify extra arguments to the backup job such as limiting bandwith with `--limit-upload` or excluding file masks with `--exclude`.
* `RESTIC_CHECK_ARGS` - Optional. Allows to specify extra arguments to the check job such as --check-unused, --read-data, --read-data-subset
* `AWS_ACCESS_KEY_ID` - Optional. When using restic with AWS S3 storage.
* `AWS_SECRET_ACCESS_KEY` - Optional. When using restic with AWS S3 storage.
* `MAILX_ARGS` - Optional. If specified, the content of `/var/log/backup-last.log` is sent via mail after each backup using an *external SMTP*. To have maximum flexibility, you have to specify the mail/smtp parameters by your own. Have a look at the [mailx manpage](https://linux.die.net/man/1/mailx) for further information. Example value: `-e "MAILX_ARGS=-r 'from@example.de' -S smtp='smtp.example.com:587' -S smtp-use-starttls -S smtp-auth=login -S smtp-auth-user='username' -S smtp-auth-password='password' 'to@example.com'"`.
* `MAILX_ON_ERROR` - Optional. If set to "ON" the MAILX_ON_ERROR will only email the backuplogs if the backup is unsuccessful, e.g. the exitcode of backup is not equal zero. When MAILX_ON_ERROR is set to any other value than "ON", the logs will always be mailed to you.
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

* `/data` - This is the data that gets backed up. Just [mount](https://docs.docker.com/engine/reference/run/#volume-shared-filesystems) it to wherever you want.
* `/log` - This holds the logfiles of the ran backups. Just [mount](https://docs.docker.com/engine/reference/run/#volume-shared-filesystems) it to wherever you want.

## Set the hostname

Since restic saves the hostname with each snapshot and the hostname of a docker container is derived from it's id you might want to customize this by setting the hostname of the container to another value.

Set `--hostname` in the [network settings](https://docs.docker.com/engine/reference/run/#network-settings)

## Backup via SFTP

Since restic needs a **password less login** to the SFTP server make sure you can do `sftp user@host` from inside the container. If you can do so from your host system, the easiest way is to just mount your `.ssh` folder conaining the authorized cert into the container by specifying `-v ~/.ssh:/root/.ssh` as argument for `docker run`.

Now you can simply specify the restic repository to be an [SFTP repository](https://restic.readthedocs.io/en/stable/Manual/#create-an-sftp-repository).

```shell
-e "RESTIC_REPOSITORY=sftp:user@host:/tmp/backup"
```

## Backup via OpenStack Swift

Restic can backup data to an OpenStack Swift container. Because Swift supports various authentication methods, credentials are passed through environment variables. In order to help integration with existing OpenStack installations, the naming convention of those variables follows the official Python Swift client.  
Now you can simply specify the restic repository to be an [Swift repository](https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html#openstack-swift).

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

## Backup via rclone

To use rclone as a backend for restic, simply add the rclone config file as a volume with `-v /absolute/path/to/rclone.conf:/root/.config/rclone/rclone.conf`.

Note that for some backends (Among them Google Drive and Microsoft OneDrive), rclone writes data back to the `rclone.conf` file. In this case it needs to be writable by Docker.

If the the container fails to write the new `rclone.conf` file with the error message `Failed to save config after 10 tries: Failed to move previous config to backup location`, add the entire `rclone` directory as volume: `-v /absolute/path/to/rclone-dir:/root/.config/rclone`.

## Versioning & Changelog

Starting from v1.0.0 versioning follows [Semantic versioning](http://semver.org/)

Build metadata is used to declare the Restic version.

**Example:** 1.0.0+0.12.1 (includes Restic 0.12.1)

For changelog see: [https://github.com/marc0janssen/restic-backup-helper/releases](https://github.com/marc0janssen/restic-backup-helper/releases)

**Notice: This image is a changed clone from [Restic Backup Docker:1.2-0.9.4]( https://github.com/lobaro/restic-backup-docker)**
