# Log rotation

`/bin/rotate_log` compresses oversized `cron.log` into a timestamped
`tar.gz` and trims old archives. It runs on `ROTATE_LOG_CRON` (default
weekly on Saturday at midnight).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `ROTATE_LOG_CRON` | `0 0 * * 6` | Cron schedule for `/bin/rotate_log`. |
| `CRON_LOG_MAX_SIZE` | `1048576` | Rotate when `/var/log/cron.log` exceeds this size (bytes). |
| `MAX_CRON_LOG_ARCHIVES` | `5` | Keep this many compressed archives `cron_log_<timestamp>.tar.gz`. |

The job is wrapped in `/bin/locked_run rotate_log` like every other cron
entry, so it cannot run concurrently with a previous rotation tick.

## What it does

```mermaid
flowchart LR
    A[/bin/rotate_log] --> B{cron.log > CRON_LOG_MAX_SIZE?}
    B -- no --> Z[Exit 0]
    B -- yes --> C[Rename cron.log → cron_log_YYYYMMDD-HHMMSS]
    C --> D[gzip into tar.gz]
    D --> E[Create empty cron.log]
    E --> F{Archives > MAX_CRON_LOG_ARCHIVES?}
    F -- no --> Z
    F -- yes --> G[Delete oldest extras]
    G --> Z
```

`/var/log/cron.log` is the only file rotated. Per-worker `*-last.log`
files are overwritten on each run, and the structured `last-*.json` is
overwritten via `*.tmp` + `mv`; neither needs rotation.

## Disabling rotation

The image deliberately does **not** support an empty `ROTATE_LOG_CRON`
(it is a required schedule). To effectively disable rotation, raise
`CRON_LOG_MAX_SIZE` to a value the log will never reach (e.g.
`1099511627776` = 1 TiB) — the cron tick still fires but does nothing.

If you ship cron logs externally (Loki, ELK, Datadog), the simplest
pattern is:

1. Mount `/var/log` somewhere you can scrape.
2. Set `CRON_LOG_MAX_SIZE=10485760` (10 MiB) so even a misbehaving
   scrape cannot leave you log-less.
3. Set `MAX_CRON_LOG_ARCHIVES=20` for a small forensic tail.

## Manual rotation

```shell
docker exec -ti restic-backup-helper /bin/rotate_log
docker exec -ti restic-backup-helper ls -la /var/log/cron_log_*.tar.gz
```

Run on demand before triaging a logspam incident so the archive
preserves the relevant tail before the next tick.

## Why a custom rotator

`logrotate` is not in the upstream `restic/restic` Alpine base. The
helper rolls its own minimal rotator to avoid pulling a heavier package
just for one file, and to keep the cron syntax consistent (`*_CRON` for
every scheduled thing). If you want a different policy (size-based
rolling, daily forced rotation, …), wrap the host `cron.log` with
`logrotate` outside the container.
