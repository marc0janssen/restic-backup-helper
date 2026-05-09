# Restic Backup Helper

Docker image for scheduled [Restic](https://restic.net) backups, repository checks, optional [Rclone](https://rclone.org) sync, cron scheduling and mail notifications. Configuration is environment-driven; see the GitHub repository for the full variable matrix and examples.

**Repository:** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper)

## Release

release: 1.10.1-0.18.1

**Stable**

```shell
docker pull marc0janssen/restic-backup-helper:latest
docker pull marc0janssen/restic-backup-helper:1.10.1-0.18.1
```

**Development (experimental)**

```shell
docker pull marc0janssen/restic-backup-helper:develop
docker pull marc0janssen/restic-backup-helper:1.10.1-0.18.1-dev
```

## Tags

| Tag | Description |
| --- | --- |
| `latest` | Current stable image |
| `<semver>-<restic>` | Pinned stable (e.g. `1.10.1-0.18.1`) |
| `develop` | Current testing / development image |
| `<semver>-<restic>-dev` | Pinned testing build |

## Core ideas

- **Backups** on a cron schedule (`BACKUP_CRON`, `BACKUP_ROOT_DIR`, `RESTIC_*`).
- **Checks** on a schedule (`CHECK_CRON`, `RESTIC_CHECK_*`).
- Optional **bidirectional sync** via Rclone (`SYNC_CRON`, `SYNC_JOB_FILE`).
- **Hooks** under `/hooks` for pre/post backup, check and sync.
- Logs under `/var/log`; optional mail via `MAILX_*` and mounted msmtp config.

## Documentation

- Full guide, Compose samples and hook details: [README.md on GitHub](https://github.com/marc0janssen/restic-backup-helper/blob/master/README.md).
- Changelog: [CHANGELOG.md](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md).

Keep sensitive values (repository passwords, API keys, `rclone.conf`) out of image tags and public descriptions — use env vars and mounted secrets at runtime.
