# Backup worker

`/bin/backup` is the heart of the image. It runs on every `BACKUP_CRON`
tick (and is always scheduled, even when no other workers are). The
script is `app/backup.sh`; it sources `app/lib.sh` for masking, logging,
JSON rendering and notifications.

## What it does, in order

```mermaid
flowchart TD
    A[locked_run backup] --> B[pre-backup hook]
    B --> C[restic backup BACKUP_ROOT_DIR RESTIC_JOB_ARGS]
    C -->|exit 0| D{RESTIC_FORGET_ARGS set?}
    C -->|non-zero| E{RESTIC_AUTO_UNLOCK=ON?}
    E -- yes --> E1[restic unlock]
    E -- no  --> E2[Log hint, keep lock]
    D -- yes --> F[restic forget]
    D -- no  --> G[Write last-backup.json]
    F -->|exit 0| G
    F -->|non-zero| E
    G --> H[Optional METRICS_DIR/.prom]
    H --> I{MAILX_RCPT? WEBHOOK_URL?}
    I --> J[mail / webhook with masked URL]
    J --> K[post-backup hook with "$rc"]
    K --> L[Exit with backup rc]
```

1. **`pre-backup` hook** (`/hooks/pre-backup.sh`) runs first when present
   and executable. Output is logged; exit code is logged but does **not**
   abort the worker. See [Hooks](../configuration/hooks.md).
2. **`restic backup`** is invoked with:

    - the required `--tag "$RESTIC_TAG"` (hard-failing on empty since 1.14.0),
    - `BACKUP_ROOT_DIR` as the trailing path argument when set,
    - `RESTIC_JOB_ARGS` whitespace-split for `--exclude-file`,
      `--files-from`, `--one-file-system`, `--skip-if-unchanged`,
      `--limit-upload`, etc.,
    - `--cacert "$RESTIC_CACERT"` when the file exists,
    - all output tee'd to `/var/log/backup-last.log`.

3. **Optional `restic forget`** runs only when the backup exited `0`,
   `RESTIC_FORGET_ARGS` is set **and** `FORGET_CRON` is empty (since
   2.5.0 — when `FORGET_CRON` is set retention is owned by the
   dedicated [Forget worker](forget.md) and the inline path is
   skipped). Words are whitespace-split and forwarded verbatim, e.g.
   `--keep-daily 7 --keep-weekly 5 --keep-monthly 12`. Add `--prune`
   to combine forget+prune in one cron tick if you do not schedule
   `PRUNE_CRON` separately. The forget exit code is recorded
   separately in `last-backup.json` as `forget_exit_code` so retention
   problems stay visible even when the backup itself is fine; see
   [Multi-host repositories and exit 11](#multi-host-repositories-and-exit-11)
   below.
4. **Optional auto-unlock**: when a non-zero exit was observed **and**
   `RESTIC_AUTO_UNLOCK=ON`, the worker runs `restic unlock`. Default is
   off — see [Restic auto-unlock](#restic-auto-unlock) for the safety
   argument.
5. **`last-backup.json`** is written with masked repository URL plus
   per-run stats parsed out of the restic stdout (`files_new`,
   `files_changed`, `bytes_added`, `snapshot_id`, …).
6. **Prometheus metrics**: when `METRICS_DIR` is set, `restic_backup.prom`
   is written.
7. **Mail / webhook**: `MAILX_RCPT` / `WEBHOOK_URL` plumbing is applied
   per the [Mail](../configuration/mail.md) and [Webhook](../configuration/webhooks.md)
   rules.
8. **`post-backup` hook** runs last, receiving the worker's exit code as
   `$1`.

## Configuration

### Required

| Variable | Why |
| --- | --- |
| `RESTIC_REPOSITORY` | Where to push the snapshot. |
| `RESTIC_PASSWORD_FILE` or `RESTIC_PASSWORD` | How to unlock the repository. |
| `RESTIC_TAG` | Hard-failing on empty since 1.14.0. Pick something meaningful. |
| `BACKUP_CRON` | When to run. |

### Backup scope

| Variable | What it controls |
| --- | --- |
| `BACKUP_ROOT_DIR` | Appended verbatim as the source path. Most users set this to `/data`. |
| `RESTIC_JOB_ARGS` | Extra restic words; supports `--exclude-file`, `--files-from`, `--one-file-system`, `--skip-if-unchanged`, `--limit-upload`, `--verbose`, etc. The value is whitespace-split, not parsed as full shell syntax, so keep paths/values free of spaces and put complex path lists in files. |

!!! tip "`--files-from` is the most flexible knob"

    Set `BACKUP_ROOT_DIR=` (empty) and pass
    `RESTIC_JOB_ARGS="--files-from /config/include_files.txt
    --exclude-file /config/exclude_files.txt --skip-if-unchanged"`
    when you want to back up multiple disjoint trees with one cron tick.

!!! tip "Verify your sources before the next tick"

    [`/bin/sources-report`](../operations/sources-report.md) is a
    read-only pre-flight inventory that re-uses the exact same
    `BACKUP_ROOT_DIR` + `RESTIC_JOB_ARGS` parsing as this worker.
    Run it after editing your env file or moving mounts; it reports
    readability, type, file count and (optional) size for each
    source plus the contents of every `--files-from` /
    `--exclude-file`.

### Retention

| Variable | What it controls |
| --- | --- |
| `RESTIC_FORGET_ARGS` | Whitespace-split arguments for `restic forget`; not full shell syntax. Examples: `--keep-daily 7`, `--keep-weekly 5`, `--keep-monthly 12`, `--keep-yearly 10`. Add `--prune` only if you do **not** run `PRUNE_CRON` separately. Add `--retry-lock=DURATION` (e.g. `5m`) on multi-host repositories so a forget that races against another host's exclusive lock waits instead of returning exit 11. |

Preview retention safely before relying on it:

```shell
docker exec -ti restic-backup-helper /bin/forget-preview
```

The preview uses `restic forget --dry-run`, `RESTIC_FORGET_ARGS`, and
the current host/tag scope by default. See
[Forget preview](../operations/forget-preview.md).

### Multi-host repositories and exit 11

See [Repository locks](../operations/repository-locks.md) for when Restic
uses exclusive locks, how that differs from stale locks, and a preventive
checklist beyond forget alone.

`restic forget` needs an **exclusive** repository lock. Two hosts that
finish their `backup` phase at roughly the same time will both attempt
forget; only one acquires the lock, the other returns exit code `11`
("failed to lock repository") almost immediately.

Since 2.4.1 the backup worker treats `forget` exit `11` as an
informational skip rather than a hard failure:

- The cron log records `⏭ Forget skipped: repository was locked by
  another host (exit 11). Retention will catch up on the next backup
  tick.`
- The backup itself still exits `0` and `last-backup.json` keeps
  `exit_code: 0`.
- The forget result is recorded separately as `forget_exit_code: 11`
  in `last-backup.json`, so monitoring can alert on persistent
  skipping without false-flagging the backup itself.
- **`restic unlock` is intentionally not invoked** on exit `11`,
  regardless of `RESTIC_AUTO_UNLOCK`: the lock that blocked this run
  is another host's legitimate exclusive lock, and clearing it would
  let two hosts mutate the repository concurrently.

Three increasingly thorough ways to make the skip rare or eliminate
it entirely:

1. **Move retention to a dedicated worker via `FORGET_CRON`** (since
   2.5.0; recommended for multi-host repos). When set, this inline
   path is automatically skipped — the standalone [Forget
   worker](forget.md) owns the exclusive lock window so backups
   never race for it:
   ```yaml
   FORGET_CRON: "30 1 * * *"
   RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
   ```
2. **Add `--retry-lock=DURATION` to `RESTIC_FORGET_ARGS`** (restic
   ≥ 0.16). Restic waits up to that duration for the lock instead of
   returning exit `11`:
   ```yaml
   RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
   ```
3. **Stagger `BACKUP_CRON` between hosts** so they do not converge on
   the same forget moment. A `5 */4 * * *` on host A and a
   `35 */4 * * *` on host B keeps both backups in the same four-hour
   cadence with 30 minutes between their forget attempts.

A `forget_exit_code: 11` that persists across many runs (visible in
`last-backup.json` history or Prometheus) suggests the two hosts
always converge — staggering the cron schedule fixes that without
touching restic flags.

## Sample configurations

=== "Single tree with retention"

    ```yaml
    environment:
      RESTIC_REPOSITORY: s3:https://s3.example.com/bucket/restic
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      RESTIC_TAG: ${HOSTNAME}-data
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_JOB_ARGS: "--exclude-file /config/exclude_files.txt --one-file-system"
      RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 5 --keep-monthly 12"
    ```

=== "Files-from list"

    ```yaml
    environment:
      RESTIC_REPOSITORY: rclone:jottacloud:backups
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      RESTIC_TAG: ${HOSTNAME}
      BACKUP_CRON: "5 6 * * *"
      BACKUP_ROOT_DIR: ""
      RESTIC_JOB_ARGS: "--exclude-file /config/exclude_files.txt --files-from /config/include_files.txt --skip-if-unchanged --verbose=2"
      RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
    ```

    `/config/include_files.txt` example:

    ```text
    /host/etc
    /host/home/admin
    /host/srv/databases
    ```

    Where `/host` is a read-only bind mount of `/`.

=== "S3 with bandwidth cap"

    ```yaml
    environment:
      RESTIC_REPOSITORY: s3:https://s3.us-east-005.backblazeb2.com/my-bucket/restic
      AWS_ACCESS_KEY_ID: ${B2_KEY_ID:?}
      AWS_SECRET_ACCESS_KEY: ${B2_APP_KEY:?}
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      RESTIC_TAG: ${HOSTNAME}-data
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_JOB_ARGS: "--exclude-file /config/exclude_files.txt --limit-upload 5000"
    ```

    `--limit-upload 5000` caps upstream at 5000 KiB/s.

## Restic auto-unlock

Before 1.12.0 the helper ran `restic unlock` after any non-zero
`restic backup` / `restic check` exit. That was convenient for
single-host setups, but **dangerous for multi-host repositories**: if
host A fails mid-snapshot while host B is happily writing, an auto-unlock
on host A removes host B's legitimate lock.

Default since 1.12.0:

- `RESTIC_AUTO_UNLOCK=OFF` — leave the lock alone, log a one-line hint
  pointing at `restic list locks` / [`/bin/unlock`](../operations/unlock.md).
- `RESTIC_AUTO_UNLOCK=ON` — opt back into the historical 1.11.x
  behaviour. Only safe when **exactly one host** writes to the
  repository.

The single hardcoded `restic unlock --remove-all` in `/entry.sh` after a
failed `restic init` is unaffected — that lock can only have been
created by the failing init attempt itself, so it is always safe to
clear.

## Failure modes

| Exit | What happened |
| --- | --- |
| `0` | Backup succeeded. |
| `2` | `RESTIC_TAG=""` explicitly empty (hard failure since 1.14.0). |
| `3` | Reserved for include/exclude zero-match in `restore` / `snapshot-export`; not produced by `backup`. |
| `12` | Restic password incorrect. |
| `>10`, other | Restic's own exit code; check `restic_<rc>` in the Restic docs. |
| `130` | Operator pressed `Ctrl-C` during manual run. |

The exit code is recorded in `last-backup.json` (`exit_code`),
`restic_backup.prom` (`restic_backup_last_exit_code`) and in the mail
subject (`[FAIL 12] Backup …`).

## Run on demand

```shell
docker exec -ti restic-backup-helper /bin/backup
```

Same code path as the cron job: hooks fire, `last-backup.json` is
updated, mail/webhook plumbing applies. Useful for end-to-end testing
after a config change. See [Manual runs](../operations/manual-runs.md).

## See also

- [Filesystem layout](../concepts/filesystem-layout.md) — where the
  per-run logs and JSON summaries land.
- [Cron and time zones](../concepts/cron-and-time-zones.md) — schedule
  syntax and `TZ`.
- [Check worker](check.md) and [Prune worker](prune.md) — the typical
  companions on a different cadence.
- [Forget preview](../operations/forget-preview.md) — validate retention
  before the real post-backup forget runs.
- [Mount snapshot](../operations/mount-snapshot.md) — read-only FUSE
  browse of any snapshot under `/fusemount`.
- [Multiple backup jobs](../deployment/multiple-jobs.md) — when one
  container is not enough.
