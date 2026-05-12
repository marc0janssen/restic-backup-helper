# Check worker

`/bin/check` runs `restic check` to verify repository integrity. It is
optional: scheduled only when `CHECK_CRON` is non-empty. Most users run
it weekly.

## What it does

```mermaid
flowchart TD
    A[locked_run check] --> B[pre-check hook]
    B --> C[restic check RESTIC_CHECK_ARGS]
    C -->|exit 0| D[Write last-check.json]
    C -->|non-zero| E{RESTIC_AUTO_UNLOCK=ON?}
    E -- yes --> E1[restic unlock]
    E -- no  --> E2[Log hint, keep lock]
    D --> F[Optional METRICS_DIR/.prom]
    F --> G{MAILX_RCPT? WEBHOOK_URL?}
    G --> H[mail / webhook]
    H --> I[post-check hook with "$rc"]
```

1. Run `pre-check` hook when present.
2. Invoke `restic check` with `RESTIC_CHECK_ARGS` shell-split (typical
   `--read-data-subset 5%`), the `--cacert` flag when configured, and
   output tee'd to `/var/log/check-last.log`.
3. Apply `RESTIC_AUTO_UNLOCK` policy on non-zero exit (same rules as
   [Backup worker](backup.md#restic-auto-unlock)).
4. Write `/var/log/last-check.json`, `restic_check.prom`.
5. Send mail/webhook per `MAILX_*` / `WEBHOOK_*` rules.
6. Run `post-check` hook with the exit code.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `CHECK_CRON` | *(empty)* | If non-empty, schedules `/bin/check`. Typical value `37 3 * * 0` (Sundays at 03:37). |
| `RESTIC_CHECK_ARGS` | *(empty)* | Extra arguments. `--read-data-subset 5%` is a popular middle ground between cheap structural checks and full re-downloads. |

## Sample configurations

=== "Weekly structural check"

    ```yaml
    environment:
      CHECK_CRON: "37 3 * * 0"
      RESTIC_CHECK_ARGS: ""
    ```

    `restic check` without flags verifies pack metadata and tree
    structure — fast and cheap, catches corruption inside the
    metadata pack files.

=== "Weekly with 5% data subset"

    ```yaml
    environment:
      CHECK_CRON: "37 3 * * 0"
      RESTIC_CHECK_ARGS: "--read-data-subset 5%"
    ```

    Adds a random 5% read of actual data pack files — catches silent
    bit-rot at storage rest. Over ~20 weeks every pack file gets
    sampled at least once.

=== "Monthly full read"

    ```yaml
    environment:
      CHECK_CRON: "0 4 1 * *"
      RESTIC_CHECK_ARGS: "--read-data"
    ```

    Full read of every pack file — strongest assurance, slowest and
    most bandwidth-hungry. Use sparingly on cloud-backed repos.

## When to schedule

- **Frequency**: weekly is plenty for cloud-backed repos. Daily check is
  rarely worth the bandwidth.
- **Time of day**: run it well *after* the backup window so they do not
  fight for the Restic repository lock. The check holds a *shared* read
  lock, so it does not block other reads but blocks writers.
- **Avoid replicate overlap**: if `REPLICATE_CRON` runs from the same
  container, stagger it so a replicate failure does not coincide with a
  long-running check.

!!! info "Check holds a read lock"

    `restic check` acquires Restic's *shared* lock, so a concurrent
    `restic backup` from another host will queue (Restic blocks writers
    behind any reader). On multi-host repositories, **schedule
    `CHECK_CRON` from only one of the hosts** to avoid serialising your
    other hosts' backups.

## Failure modes

| Exit | What it likely means |
| --- | --- |
| `0` | Repository is healthy. |
| `1` | Repository contains errors. Run `restic check --read-data` to confirm and `restic rebuild-index` to fix index issues. Restore-critical errors require careful triage. |
| `10` | Repository does not exist. Should be impossible if the entrypoint probe passed; investigate. |
| `12` | Wrong password — check `RESTIC_PASSWORD_FILE`. |

Mail subjects include the exit code (`[FAIL 1] Check larak · …`) so
filter rules can escalate any non-zero check separately.

## Run on demand

```shell
docker exec -ti restic-backup-helper /bin/check
docker exec -ti restic-backup-helper cat /var/log/last-check.json
```

Same code path as the cron job.

## See also

- [Prune worker](prune.md) — companion for periodic compaction.
- [Backup worker](backup.md) — the worker check verifies.
- [Troubleshooting](../operations/troubleshooting.md) — what to do when
  `restic check` returns errors.
