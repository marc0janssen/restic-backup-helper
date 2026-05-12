# Filesystem layout

Every path the container cares about and what you typically mount over the
top of it. Paths marked **VOLUME** are declared in the `Dockerfile` and get
automatically created if you do not mount them; the rest are conventions.

## Container paths at a glance

| Path | Purpose | Typical mount | Notes |
| --- | --- | --- | --- |
| `/data` | Declared `VOLUME`; typical backup source when `BACKUP_ROOT_DIR=/data`. | `-v /srv/documents:/data:ro` | Use `:ro` so hooks cannot mutate sources. |
| `/config` | Recommended mount for `rclone.conf`, exclude/include files, msmtprc, replicate job file. | `-v ./config:/config` | Bind-mount; some backends update `rclone.conf` (token refresh) so it may need write access. |
| `/hooks` | Optional mount for `/hooks/{pre,post}-<job>.sh`. | `-v ./hooks:/hooks:ro` | Hooks must be executable inside the container. |
| `/restore` | Convention for `restic restore --target /restore` and `/bin/snapshot-export --output`. | `-v ./restore:/restore` | Refuses non-empty target unless `--force` (restore wrapper). |
| `/mnt/restic` | Default `RESTIC_REPOSITORY` location for local disk / NFS. | `-v restic-repo:/mnt/restic` *or* `NFS_TARGET=…` | Mount target of `NFS_TARGET` when set. |
| `/var/log` | Cron log, per-run JSON summaries, Prometheus textfiles. | `-v backup-logs:/var/log` | Persist if you scrape `last-*.json` or compressed `cron_log_*.tar.gz`. |
| `/.cache/restic` | Restic cache directory. | `-v restic-cache:/.cache/restic` | Persist to speed up subsequent backups; safe to throw away. |
| `/etc/msmtprc` | msmtp SMTP relay config; sendmail symlink → msmtp. | `-v ./config/msmtprc:/etc/msmtprc:ro` | Required only when `MAILX_RCPT` is set. |
| `/run/secrets/restic_password` | Conventional Docker secret mount. | `secrets:` in Compose | Point `RESTIC_PASSWORD_FILE` here. |
| `/var/log/textfile_collector` | Recommended `METRICS_DIR` target. | `-v ./metrics:/var/log/textfile_collector` | Mount when scraping Prometheus textfiles. |
| `/var/spool/cron/crontabs/root` | Rendered crontab written by `/entry.sh`. | tmpfs if read-only root | Required writable; needs `tmpfs: /var/spool/cron` with `read_only: true`. |
| `/tmp`, `/run`, `/var/run` | scratch dirs (lock files, restic temp). | tmpfs if read-only root | Required writable. |

## Logs written by the workers

Each worker maintains a small set of `*-last.log` files under `/var/log`,
plus a structured `last-<job>.json` summary and (when `METRICS_DIR` is set)
a `restic_<job>.prom` Prometheus textfile.

```text
/var/log/
├── cron.log                              # everything cron-related
├── cron_log_<timestamp>.tar.gz           # rotated archives (rotate_log)
│
├── backup-last.log                       # /bin/backup, per-run log
├── backup-error-last.log                 # snapshot of backup-last.log on failure
├── backup-mail-last.log                  # mail body used by the backup mail
├── last-backup.json                      # structured summary, JSON
│
├── check-last.log
├── check-error-last.log
├── check-mail-last.log
├── last-check.json
│
├── prune-last.log
├── prune-error-last.log
├── prune-mail-last.log
├── last-prune.json
│
├── replicate-last.log
├── replicate-error-last.log
├── replicate-mail-last.log
├── last-replicate.json
│
├── restore-last.log                      # /bin/restore, per-run log
├── restore-error-last.log
├── restore-mail-last.log
├── last-restore.json
│
├── snapshot-export-last.log              # /bin/snapshot-export, per-run log
├── snapshot-export-error-last.log
├── snapshot-export-mail-last.log
├── last-snapshot-export.json
│
├── forget-preview-last.log               # /bin/forget-preview, per-run log
├── forget-preview-error-last.log
├── forget-preview-mail-last.log
├── last-forget-preview.json
│
└── textfile_collector/                   # only when METRICS_DIR is set
    ├── restic_backup.prom
    ├── restic_check.prom
    ├── restic_prune.prom
    ├── restic_replicate.prom
    ├── restic_restore.prom
    ├── restic_snapshot_export.prom
    └── restic_forget_preview.prom
```

`*-last.log` files are overwritten every run (no rolling). `last-*.json`
files are written via `*.tmp` + `mv` so an external scrape never sees a
partial document. Compressed archives `cron_log_<timestamp>.tar.gz` are
created by `/bin/rotate_log`; tune retention via `MAX_CRON_LOG_ARCHIVES`.

## Lock files

`/bin/locked_run` writes one `/var/run/<name>.lock` per worker. They are
not safe to mount as volumes (they need to be local to the container's
PID namespace) and are intentionally created in tmpfs when you run with
`read_only: true`.

```text
/var/run/
├── backup.lock
├── check.lock
├── prune.lock
├── replicate.lock
└── rotate_log.lock
```

## Read-only root recipe

When tightening with `read_only: true`, you need tmpfs / volume mounts for
exactly the paths the workers touch. Minimal recipe:

```yaml
read_only: true
tmpfs:
  - /tmp
  - /run
  - /var/run
  - /var/spool/cron        # crond writes the rendered crontab here
volumes:
  - backup-logs:/var/log   # persists last-*.json + archives
  - restic-cache:/.cache/restic   # speeds up subsequent backups
```

See [Hardening](../deployment/hardening.md) for the full discussion of
trade-offs (losing `last-*.json` on restart if you tmpfs `/var/log`, etc.).
