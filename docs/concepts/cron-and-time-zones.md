# Cron and time zones

The image is fundamentally a busybox `crond` running a handful of curated
job lines. This page covers the cron expressions, locking semantics, the
`TZ` variable and what each cron tick actually does.

## Crontab generation

At container boot, `/entry.sh` renders **root's crontab** based on the
five cron env vars and writes it to `/var/spool/cron/crontabs/root`. Each
line wraps the worker in `/bin/locked_run`:

```cron
# Always present
${BACKUP_CRON} /bin/locked_run backup    /bin/backup     >> /var/log/cron.log 2>&1
${ROTATE_LOG_CRON} /bin/locked_run rotate_log /bin/rotate_log >> /var/log/cron.log 2>&1

# Only appended when their env vars are non-empty
${CHECK_CRON}     /bin/locked_run check     /bin/check     >> /var/log/cron.log 2>&1
${PRUNE_CRON}     /bin/locked_run prune     /bin/prune     >> /var/log/cron.log 2>&1
${REPLICATE_CRON} /bin/locked_run replicate /bin/replicate >> /var/log/cron.log 2>&1
```

## Cron expression rules

The image uses the standard five-field busybox cron syntax:

```text
┌───────────── minute        (0 - 59)
│ ┌───────────── hour          (0 - 23)
│ │ ┌───────────── day-of-month (1 - 31)
│ │ │ ┌───────────── month       (1 - 12)
│ │ │ │ ┌───────────── day-of-week (0 - 6, 0 = Sunday)
│ │ │ │ │
0 2 * * *   # every day at 02:00
```

Useful patterns:

| Expression | Fires |
| --- | --- |
| `0 */6 * * *` | Every 6 hours on the hour (default `BACKUP_CRON`). |
| `0 2 * * *` | Daily at 02:00. |
| `37 3 * * 0` | Sundays at 03:37. |
| `0 0 * * 6` | Saturdays at 00:00 (default `ROTATE_LOG_CRON`). |
| `*/30 * * * *` | Every 30 minutes. |

!!! tip "Stagger heavy jobs"

    Run `PRUNE_CRON` and `CHECK_CRON` on different days/hours than your
    primary backup. Both grab the Restic repository lock; an unfortunate
    overlap will cause one job to bail out with a lock error rather than
    queue.

## `TZ` and where it matters

`TZ` (default `Europe/Amsterdam`) is exported into the cron environment
and consumed by the workers when they print timestamps. Set it explicitly
so log timestamps and cron firings line up with your expectations:

```yaml
environment:
  TZ: UTC
```

Notes:

- busybox `crond` respects `TZ` from the process environment. The
  entrypoint starts `crond` after the environment is resolved and then
  execs the foreground `CMD` (`tail -fn0 /var/log/cron.log` by default).
- Restic itself does not care about `TZ`; snapshot timestamps are stored
  in UTC and displayed in the operator's locale.
- Mail subjects, `last-*.json` `started_at`/`finished_at` and webhook
  payloads use the container's `TZ` for human-readable timestamps and
  Unix epoch seconds for machine-readable timestamps.

## Locked runs

Every cron entry runs through `/bin/locked_run <name> /bin/<worker>`. That
wrapper acquires `/var/run/<name>.lock` with `flock -n` (non-blocking).
Behaviour:

| Situation | Outcome |
| --- | --- |
| Lock acquired. | The worker runs normally; its exit code propagates. |
| Lock held by previous tick. | The wrapper logs `⏭ <name> skipped: previous run still active` to `/var/log/cron.log` and exits `0`. |
| Worker crashes. | Lock is released by the kernel when the process dies; next tick acquires normally. |

Locks are **per worker**, so a long-running `prune` never blocks `backup`,
`replicate` or `check`. They are also independent from Restic's own
repository lock — that one lives on the backend (S3 object, SFTP file,
local file under `/mnt/restic/locks/…`) and prevents two concurrent
writers regardless of which container starts them.

## Skip lines in cron.log

When a cron tick is skipped you'll see lines like:

```text
2026-05-11 09:30:00 ⏭ backup skipped: previous run still active (locked by PID 1357)
```

If you see these frequently:

- **Backup interval is shorter than the average run.** Either widen the
  interval, exclude more data, or split a single large source into
  multiple smaller jobs (see [Multiple backup jobs](../deployment/multiple-jobs.md)).
- **A stuck process is holding the lock.** Inspect with `docker exec …
  ps -ef` and either wait or kill the offending PID.
- **Repository lock from another host.** The local `flock` releases the
  moment the worker exits, but Restic's own repository lock may still be
  held remotely. See [Troubleshooting](../operations/troubleshooting.md).

## See also

- [Backup worker](../workers/backup.md) — what `/bin/backup` actually
  does once `BACKUP_CRON` fires.
- [Architecture](architecture.md) — the bigger picture of entrypoint,
  cron, and workers.
- [Hardening](../deployment/hardening.md) — why
  `tmpfs: /var/spool/cron` is required for read-only roots.
