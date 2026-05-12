# Prune worker

`/bin/prune` runs a standalone `restic prune` on its own cadence,
decoupled from the per-backup `restic forget`. Optional: scheduled only
when `PRUNE_CRON` is non-empty.

## Why a separate worker

Restic's typical retention pattern combines two operations:

| Operation | What it does | Cost |
| --- | --- | --- |
| `restic forget` | Drops references to snapshots that don't match the retention policy. | Cheap: rewrites index, no data pack rewriting. |
| `restic prune` | Reclaims storage by repacking partially-used pack files. | Expensive: re-downloads, repacks, re-uploads pack files. |

You typically want **`forget` after every backup** (cheap, keeps the
snapshot list trimmed) but **`prune` only weekly or monthly** (so the
bandwidth cost only hits one cron tick per week). That is exactly the
shape the helper exposes:

- `RESTIC_FORGET_ARGS` runs *after* `/bin/backup` succeeds.
- `PRUNE_CRON` + `RESTIC_PRUNE_ARGS` runs a separate `/bin/prune` on its
  own schedule.

You can still pass `--prune` inside `RESTIC_FORGET_ARGS` if you prefer
the combined cheap-or-expensive-on-the-same-cron pattern; the
standalone prune then has nothing to do and exits `0` quickly.

## What it does

```mermaid
flowchart TD
    A[locked_run prune] --> B[pre-prune hook]
    B --> C[restic prune RESTIC_PRUNE_ARGS]
    C -->|exit 0| D[Write last-prune.json]
    C -->|non-zero| E{RESTIC_AUTO_UNLOCK=ON?}
    E -- yes --> E1[restic unlock]
    E -- no  --> E2[Log hint, keep lock]
    D --> F[Optional METRICS_DIR/.prom]
    F --> G{MAILX_RCPT? WEBHOOK_URL?}
    G --> H[mail / webhook]
    H --> I[post-prune hook with "$rc"]
```

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `PRUNE_CRON` | *(empty)* | If non-empty, schedules `/bin/prune`. Typical value `0 4 * * 0` (Sundays at 04:00, after the weekly check). |
| `RESTIC_PRUNE_ARGS` | *(empty)* | Extra words for `restic prune`. Examples: `--max-unused 10%`, `--max-repack-size 5G`. |

## Sample configurations

=== "Weekly prune with sensible defaults"

    ```yaml
    environment:
      PRUNE_CRON: "0 4 * * 0"
      RESTIC_PRUNE_ARGS: "--max-unused 10%"
    ```

    `--max-unused 10%` tells restic to stop when at most 10% of stored
    bytes are "unused" (referenced only by forgotten snapshots). Trades
    a bit of bloat for a much shorter prune.

=== "Bandwidth-capped weekly prune"

    ```yaml
    environment:
      PRUNE_CRON: "0 4 * * 0"
      RESTIC_PRUNE_ARGS: "--max-unused 10% --max-repack-size 5G"
    ```

    `--max-repack-size 5G` caps how much data prune is allowed to
    rewrite per run. Useful on slow cloud links where an unbounded
    prune could run for hours.

=== "Combined forget+prune on backup"

    ```yaml
    environment:
      RESTIC_FORGET_ARGS: "--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune"
      PRUNE_CRON: ""
    ```

    Skip the standalone prune entirely. Each successful backup runs
    `restic forget --prune` so the repository is always tidy at the
    cost of a more expensive nightly run.

## When to schedule

- **After** the weekly `CHECK_CRON` (e.g. check at `37 3 * * 0`, prune
  at `0 4 * * 0`). A failed check tells you the repo is unhealthy; a
  prune over an unhealthy repo can make recovery harder.
- **Outside** the daily backup window. Prune holds Restic's exclusive
  write lock and will block (or be blocked by) any concurrent backup.
- **On only one host** for multi-host repositories. Otherwise N hosts
  each schedule a heavy prune against the same repository on the same
  cadence and trip the lock.

## Long-running prunes

A first-ever prune on a large repository can take hours. Some practical
tips:

- Set `--max-repack-size <bytes>` to bound the per-run cost.
- Schedule via `PRUNE_CRON` rather than `RESTIC_FORGET_ARGS --prune` so
  a stuck prune does not block the daily backup.
- Consider running the first prune **manually** via
  `docker exec -ti … /bin/prune` so you can watch its output and pick
  the right `--max-*` knobs for your repo size.
- Use `--cleanup-cache` only when restic itself suggests it; the helper
  does not enable it by default because it makes the next backup
  noticeably slower.

## Failure modes

| Exit | What it likely means |
| --- | --- |
| `0` | Prune succeeded (or had nothing to do). |
| `1` | Generic restic failure — see `prune-error-last.log`. |
| `12` | Wrong password. |
| Other | Repository unhealthy. Run `/bin/check` first to confirm. |

## Run on demand

```shell
docker exec -ti restic-backup-helper /bin/prune
docker exec -ti restic-backup-helper cat /var/log/last-prune.json
```

Watch out for the runtime on first run on a large repository. Same code
path as the cron job, including hooks, mail and webhook.

## See also

- [Backup worker](backup.md) — `RESTIC_FORGET_ARGS` is the cheap
  per-run counterpart.
- [Check worker](check.md) — run weekly *before* prune.
- [Multiple backup jobs](../deployment/multiple-jobs.md) — `PRUNE_CRON`
  must run on only one of N containers sharing a repository.
