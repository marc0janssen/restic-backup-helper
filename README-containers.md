# Restic Backup Helper

[![Quality Checks](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml)
[![Smoke Test](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml)
[![Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml)

Scheduled [Restic](https://restic.net) backups, optional `restic check`, optional [Rclone](https://rclone.org) **bisync**, cron automation, logs under `/var/log`, optional mail via **msmtp** + **mailx**. Based on **`restic/restic`** Alpine.

**GitHub (full manual, Compose, hooks, env matrix):** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper)

---

## Release

release: 1.11.3-0.18.1

**Stable**

```shell
docker pull marc0janssen/restic-backup-helper:latest
docker pull marc0janssen/restic-backup-helper:1.11.3-0.18.1
```

**Development (experimental)**

```shell
docker pull marc0janssen/restic-backup-helper:develop
docker pull marc0janssen/restic-backup-helper:1.11.4-0.18.1-dev
```

---

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | Current stable |
| `<semver>-<restic>` | Pinned stable (helper version + Restic base), e.g. `1.11.3-0.18.1` |
| `develop` | Latest testing build |
| `<semver>-<restic>-dev` | Pinned testing image |

---

## What runs inside

| Component | Trigger |
| --- | --- |
| **Backup** | `BACKUP_CRON` → `/bin/backup` |
| **Check** | `CHECK_CRON` (if set) → `/bin/check` |
| **Sync** | `SYNC_CRON` (if set) → `/bin/bisync` reading `SYNC_JOB_FILE` |
| **Log rotate** | `ROTATE_LOG_CRON` → `/bin/rotate_log` for `cron.log` |
| **Config check** | One-shot `docker run … config-check` (same env as prod) validates settings without cron |

Startup (`/entry.sh`) can verify/init the repo when `RESTIC_CHECK_REPOSITORY_STATUS=ON`. Jobs use **`flock`** locks (`/var/run/*.lock`).

---

## Mount points (typical)

| Path | Use |
| --- | --- |
| `/data` | Backup source (`BACKUP_ROOT_DIR` often `/data`) |
| `/config` | `rclone.conf`, excludes, `msmtprc`, sync job file |
| `/hooks` | Optional `pre-*` / `post-*` scripts |
| `/var/log` | Persist logs on the host |
| `/restore` | Common restore target volume |

---

## Environment essentials

**Always configure:** `RESTIC_REPOSITORY`, repository auth (`RESTIC_PASSWORD` or `RESTIC_PASSWORD_FILE`), **`RESTIC_TAG`** (required by backup), **`BACKUP_CRON`**, and either **`BACKUP_ROOT_DIR`** and/or paths via **`RESTIC_JOB_ARGS`**.

**Defaults from the image (see GitHub README for full table):** `RESTIC_CACHE_DIR=/.cache/restic`, `RESTIC_CHECK_REPOSITORY_STATUS=ON`, `RCLONE_CONFIG=/config/rclone.conf`, `SYNC_JOB_FILE=/config/sync_jobs.txt`, `SYNC_VERBOSE=ON`, `ROTATE_LOG_CRON=0 0 * * 6`, `CRON_LOG_MAX_SIZE=1048576`, `MAX_CRON_LOG_ARCHIVES=5`, `TZ=Europe/Amsterdam`.

**Forget policy:** set `RESTIC_FORGET_ARGS` (example: `--prune --keep-daily 7`) to run `restic forget` after a successful backup.

**Mail:** `MAILX_RCPT` + mounted **`/etc/msmtprc`**; `MAILX_ON_ERROR=ON` limits backup/check mail to failures. Sync mails only when errors occurred.

**Sync file format:** one line per job: `SOURCE;DESTINATION` (see [`config/sync_jobs.txt`](https://github.com/marc0janssen/restic-backup-helper/blob/master/config/sync_jobs.txt)).

---

## Hooks (`/hooks`)

`pre-backup.sh`, `post-backup.sh` (receives backup exit code), `pre-check.sh`, `post-check.sh` (check exit code), `pre-sync.sh`, `post-sync.sh` (aggregate sync exit code).

---

## Security

Do not embed secrets in image tags or public Hub descriptions. Use env files, secrets, or mounts excluded from git. Treat `rclone.conf` as sensitive.

---

## Links

- **Documentation:** [README.md on GitHub](https://github.com/marc0janssen/restic-backup-helper/blob/master/README.md)
- **Changelog:** [CHANGELOG.md](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)
- **Issues / source:** [GitHub repository](https://github.com/marc0janssen/restic-backup-helper)

---

_Image lineage: derived from [lobaro/restic-backup-docker](https://github.com/lobaro/restic-backup-docker)._
