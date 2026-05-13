# Forget worker

`/bin/forget` runs a standalone `restic forget` on its own cadence,
decoupled from the inline post-backup forget in `/bin/backup`. Optional:
scheduled only when `FORGET_CRON` is non-empty.

## Why a separate worker

On a repository shared by multiple hosts, every host's `/bin/backup`
finishes around the same time and immediately tries to take the
**exclusive** lock that `restic forget` requires. Only one host wins;
the others get exit `11` ("failed to lock repository"). The 2.4.1
soft-skip ([Backup worker → Multi-host repositories and exit 11](backup.md#multi-host-repositories-and-exit-11))
makes that benign — but retention then depends on which host happens
to win the race, and is invisible in `last-backup.json` aside from a
`forget_exit_code` field.

`FORGET_CRON` solves the underlying problem: instead of "every host
attempts forget after every backup", retention becomes a **first-class
worker** with its own schedule, its own lock window, its own log,
JSON summary, Prometheus metric, mail subject, webhook payload and
hook pair.

| Operation | Default home | Cost | Exclusive lock |
| --- | --- | --- | --- |
| `restic backup` | `/bin/backup` (per-host `BACKUP_CRON`) | Network + cache | No (shared lock) |
| `restic forget` | Inline in `/bin/backup`, or `/bin/forget` when `FORGET_CRON` is set | Cheap (metadata only) | **Yes** |
| `restic prune` | `/bin/prune` (`PRUNE_CRON`, weekly/monthly) | Expensive (data repack) | **Yes** |

When `FORGET_CRON` is non-empty the inline post-backup forget in
`/bin/backup` is automatically skipped (cron log records
`⏭ Skipping inline forget: FORGET_CRON is set …`) so the exclusive
lock is only ever taken inside this dedicated maintenance window.

## What it does

```mermaid
flowchart TD
    A[locked_run forget] --> B[pre-forget hook]
    B --> C{RESTIC_FORGET_ARGS set?}
    C -- no  --> Z[Exit 2: nothing to do]
    C -- yes --> D[restic forget RESTIC_FORGET_ARGS]
    D -->|exit 0| E[Write last-forget.json]
    D -->|exit 11| F[⏭ Skip: locked by another host]
    D -->|other| G{RESTIC_AUTO_UNLOCK=ON?}
    G -- yes --> G1[restic unlock]
    G -- no  --> G2[Log hint, keep lock]
    F --> E
    E --> H[Optional METRICS_DIR/restic_forget.prom]
    H --> I{MAILX_RCPT? WEBHOOK_URL?}
    I --> J[mail / webhook]
    J --> K[post-forget hook with "$rc"]
```

Notes on the flow:

- **Exit `11`** (failed to lock repository) is treated as an
  informational skip — same rationale as the inline path. `restic
  unlock` is **never** auto-run on exit `11`, regardless of
  `RESTIC_AUTO_UNLOCK`: the lock that blocked us is another host's
  legitimate lock. Retention is cumulative; the next `FORGET_CRON`
  tick catches up. If you have independently confirmed a lock is
  stale (the holding container is gone), use the audited
  [`/bin/unlock`](../operations/unlock.md) helper to clear it.
- **Empty `RESTIC_FORGET_ARGS`** exits with `2` and a `❌ No
  retention policy configured` error message so the misconfiguration
  is loud rather than silently "succeeding" with nothing to do.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `FORGET_CRON` | *(empty)* | If non-empty, schedules `/bin/forget` and **disables** the inline post-backup forget in `/bin/backup`. Typical value `30 1 * * *` (daily at 01:30, well outside the backup window) or `0 5 * * *` (after the nightly backups finished). |
| `RESTIC_FORGET_ARGS` | *(empty)* | Shared with the inline path. Words are whitespace-split and passed to `restic forget` verbatim; this is not full shell syntax, so keep values free of spaces. Add `--retry-lock=DURATION` (e.g. `5m`) on multi-host repositories so a `FORGET_CRON` tick that races against another host's exclusive lock waits instead of returning exit `11`. |

## Sample configurations

=== "Multi-host repository, dedicated forget window"

    ```yaml
    environment:
      RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
      FORGET_CRON: "30 1 * * *"     # host A
      PRUNE_CRON: "0 4 * * 0"
    ```

    Each host's `/bin/backup` writes its snapshot, exits, and never
    touches the exclusive forget-lock. At 01:30 the dedicated forget
    worker runs against the global retention policy. Stagger
    `FORGET_CRON` between hosts (e.g. host A `30 1 * * *`, host B
    `45 1 * * *`) so even the dedicated windows do not converge.

=== "Single-host repository (no behaviour change)"

    ```yaml
    environment:
      RESTIC_FORGET_ARGS: "--keep-daily 7 --keep-weekly 5 --keep-monthly 12"
      FORGET_CRON: ""               # default
    ```

    `FORGET_CRON` empty = legacy behaviour: `/bin/backup` runs forget
    inline after every successful backup. Nothing to change when you
    upgrade.

=== "Centralised retention, multiple backup containers"

    ```yaml
    services:
      backup-node-1:
        environment:
          BACKUP_CRON: "5 2 * * *"
          # No FORGET_CRON / RESTIC_FORGET_ARGS — backup-only host.
      backup-node-2:
        environment:
          BACKUP_CRON: "35 2 * * *"
          # No FORGET_CRON / RESTIC_FORGET_ARGS — backup-only host.
      forget-owner:
        environment:
          BACKUP_CRON: ""
          FORGET_CRON: "0 4 * * *"
          RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
          PRUNE_CRON: "0 5 * * 0"
    ```

    One "maintenance owner" container handles forget + prune for the
    whole repository; the backup nodes only write data and never take
    an exclusive lock. Same pattern as the
    [Multiple backup jobs](../deployment/multiple-jobs.md) split for
    `CHECK_CRON` / `PRUNE_CRON`.

## When to schedule

- **Outside** every host's `BACKUP_CRON` window. Forget is cheap but
  it still takes the exclusive lock; while it runs, no host can
  start a fresh backup.
- **Staggered between hosts** if more than one container runs the
  forget worker (otherwise you have re-created the original race
  inside the dedicated window).
- **Before** `PRUNE_CRON`. Prune over an out-of-date retention set
  just reclaims fewer bytes; running forget right before prune
  maximises what the weekly prune can reclaim.

## Output

| Artifact | Path |
| --- | --- |
| Per-run log | `/var/log/forget-last.log` |
| Per-run error log (only on failure) | `/var/log/forget-error-last.log` |
| Per-run mail body | `/var/log/forget-mail-last.log` |
| JSON summary | `/var/log/last-forget.json` |
| Prometheus textfile | `${METRICS_DIR}/restic_forget.prom` (when `METRICS_DIR` is set) |
| Hooks | `/hooks/pre-forget.sh`, `/hooks/post-forget.sh "$rc"` |

The JSON document follows the common envelope ([JSON
summaries](../reference/json-summaries.md)) plus the masked
`repository` URL.

## Failure modes

| Exit | What it likely means |
| --- | --- |
| `0` | Forget succeeded (or had nothing to do). |
| `2` | `RESTIC_FORGET_ARGS` is empty — set a policy or unset `FORGET_CRON`. |
| `11` | Repository was locked by another host. Logged as `⏭ Forget skipped …`; retention catches up on the next tick. Add `--retry-lock=DURATION` to `RESTIC_FORGET_ARGS` or stagger `FORGET_CRON` between hosts. |
| `12` | Wrong password. |
| Other | Generic restic failure — see `forget-error-last.log`. |

## Run on demand

```shell
docker exec -ti restic-backup-helper /bin/forget
docker exec -ti restic-backup-helper cat /var/log/last-forget.json
```

Same code path as the cron tick, including pre/post hooks, mail and
webhook. Combine with `/bin/forget-preview` ([Forget
preview](../operations/forget-preview.md)) when validating a new
retention policy: `forget-preview` is the `--dry-run` companion that
prints the snapshot list without mutating the repository.

## See also

- [Backup worker → Multi-host repositories and exit 11](backup.md#multi-host-repositories-and-exit-11)
  — the inline path that `FORGET_CRON` opts you out of, and the
  exit-11 soft-skip semantics that both paths share.
- [Prune worker](prune.md) — the expensive sibling that reclaims the
  storage forget marked for collection.
- [Forget preview](../operations/forget-preview.md) — validate
  retention with `restic forget --dry-run` before relying on it.
- [Multiple backup jobs](../deployment/multiple-jobs.md) — the
  one-owner pattern for repository-wide cron jobs.
