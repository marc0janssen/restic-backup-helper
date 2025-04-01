# Changelog

## Restic Backup Helper

### 1.7.71-0.18.0 (2025-04-01)

#### Changed
- CRON backup is always started
- Revised build scripts
- Change Restic to version 0.18.0

### 1.7.68-0.17.3 (2025-03-27)

#### Added
- Unified the date in the scripts
- Rotate cron.log
- Healthcheck in container

#### Changed
- Healthcheck CMD changed to a non-locking command
- Typo in backup log text corrected


### 1.6.49-0.17.3 (2025-03-24)

#### Changed
- Automatic versioning when buidling the container

### 1.6.3-0.17.3 (2025-03-23)

#### Bugfix
- Backup script fixed

### 1.6.2-0.17.3 (2025-03-23)

#### Added
- Rclone bisync script added to enable a sync folder if you like

### 1.5.6-0.17.3 (2025-03-21)

#### Changed
- Updated Restic to version 0.17.3
- Revamped the code
- Restic running as root again
- Fixed mail with msmtp
- Reduced number of layers in Docker image
- switched to Rclone from Alpine Linux Repository

### 1.4.2-0.12.1 (2022-01-17)

#### Changed
- EXITCODE check MAILX

### 1.4.1-0.12.1

#### Added
- "bash" as shell

#### Changed
- Changed logpaths
- Removed the Microsoft Teams WEBHOOKS

#### Fixed
- checkRC missing

### 1.3.4-0.12.1

#### Fixed
- Fixed arguments for mail

### 1.3.3-0.12.1 (2021-12-31)

#### Added
- 'restic check' for repo can be setup now with CHECK_CRON and RESTIC_CHECK_ARGS

#### Changed
- Removed Openshift "Fix"
- mailsubject is a fixed text in backup and check script

#### Fixed
- .cache directory now within the context of user 'restic:users'

### 1.2.2-0.12.1

#### Changed
- Changed filepermission on /log directory

### 1.2.1-0.12.1

#### Fixed
- Fixed Dockerfile

### 1.2.0-0.12.1

#### Changed
- Log directory is now a volume and logs are exposed

### 1.1.2-0.12.1

#### Added
- Email only when the backup fails. Controlled by MAILX_ON_ERROR.

#### Changed
- Moved account creating and modified restic binary to the Dockerfile

#### Fixed
- Fixed typo in text
- Fixed calling the restic binary with extra file capabilities

### 1.0.0-0.12.1

#### Changed
- DOES NOT run as ROOT in the container so resulting backup is NOT OWNED by ROOT anymore
- Backup source PATH can be set by environment var BACKUP_ROOT_DIR (will default to /data if not set)
- Updated to Restic version 0.12.1

## Restic Backup Docker

### 1.3.1-0.9.6

#### Changed
- Update to Restic v0.9.5
- Reduced the number of layers in the Docker image

#### Fixed
- Check if a repo already exists works now for all repository types

#### Added
- ssh added to container
- fuse added to container
- support to send mails using external SMTP server after backups

### 1.2-0.9.4

#### Added
- AWS Support

### 1.1

#### Fixed
- `--prune` must be passed to `RESTIC_FORGET_ARGS` to execute prune after forget.

#### Changed
- Switch to base Docker container to `golang:1.7-alpine` to support latest restic build.

### 1.0

Initial release.

- The container has proper logs now and was running for over a month in production.
- There are still some features missing. Sticking to semantic versioning we do not expect any breaking changes in the 1.x releases.
