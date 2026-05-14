# Replicate worker

`/bin/replicate` runs Rclone jobs declared in `REPLICATE_JOB_FILE`. Each
job line is one of:

- **`bisync`** — bidirectional sync (default), with a recovery procedure
  on failure.
- **`sync`** — one-way mirror (destination matches source, deletes
  propagate).
- **`copy`** — one-way additive (destination receives new files,
  deletes do **not** propagate).

The legacy name was "sync"; since 2.0.0 the worker, env vars and logs
were renamed to "replicate". See the [`1.18.x → 2.0.0` section of Upgrading](../getting-started/upgrading.md) and [`2.x → 3.0.0`](../getting-started/upgrading.md#replicate-30-bridge) (removal of `SYNC_*` and `/bin/bisync`).

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `REPLICATE_CRON` | *(empty)* | Cron schedule. Empty disables replication. |
| `REPLICATE_JOB_FILE` | `/config/replicate_jobs.txt` | Path to the job file (semicolon-separated rows). |
| `REPLICATE_JOB_ARGS` | *(empty)* | Global rclone flags appended to every job. Shell-word split. `--resync` is stripped from routine runs. |
| `REPLICATE_VERBOSE` | `ON` | When `ON`, also echo to stdout. |
| `REPLICATE_BISYNC_CHECK_ACCESS` | `OFF` | When `ON`, append `--check-access` to every bisync run and the recovery resync. |
| `RCLONE_CONFIG` | `/config/rclone.conf` | Rclone configuration file. |

## Job file format

```text
# SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]
#   MODE       bisync (default) | sync | copy
#   EXTRA_ARGS rclone flags appended after the global REPLICATE_JOB_ARGS for THIS job only
#              (--resync is stripped from both for routine runs)

# Two-column legacy form; runs as bisync with global REPLICATE_JOB_ARGS:
/data/inbox;jottacloud:inbox

# Bisync with a per-job exclude file in addition to the global one:
/data/photos;jottacloud:photos;bisync;--exclude-from /config/photos-exclude.txt

# One-way push (rclone sync) — destination is made to mirror the source:
/data/site;s3:my-bucket/site;sync

# One-way copy (rclone copy) — additive, deletes are NOT propagated:
/data/archive;jottacloud:archive;copy;--immutable
```

| Column | Required | Notes |
| --- | --- | --- |
| `SOURCE` | yes | Local path or rclone remote path. |
| `DESTINATION` | yes | Local path or rclone remote path. |
| `MODE` | no (default `bisync`) | `bisync` keeps both sides in sync (recovery on failure). `sync` makes destination match source (deletions propagate). `copy` is additive, no deletes. |
| `EXTRA_ARGS` | no | Per-job rclone flags, whitespace-split and appended after `REPLICATE_JOB_ARGS`. This is not full shell syntax; keep values free of spaces or move complex settings into rclone config/files. `--resync` is filtered out so a routine run can never resync implicitly. |

## What it does

```mermaid
flowchart TD
    A[locked_run replicate] --> B[pre-replicate hook]
    B --> C[Parse REPLICATE_JOB_FILE]
    C -->|malformed line| F[Count as failed job]
    C --> D{For each job}
    D --> E{MODE}
    E -- bisync --> E1[rclone bisync ARGS]
    E -- sync   --> E2[rclone sync ARGS]
    E -- copy   --> E3[rclone copy ARGS]
    E1 -->|fail| E1R[Recovery: copy both → bisync --resync]
    E2 -->|fail| FailMail
    E3 -->|fail| FailMail
    E1R -->|still fail| FailMail
    D --> G[Aggregate exit code]
    G --> H[Write last-replicate.json]
    H --> I[Optional METRICS_DIR/.prom]
    I --> J{Any failures?}
    J -- yes --> FailMail[mail + webhook]
    J -- no  --> K[post-replicate hook with "$rc"]
    FailMail --> K
```

1. **`pre-replicate` hook** when present.
2. **Parse the job file**. Malformed lines (missing `SOURCE`/`DESTINATION`
   or unknown `MODE`) are counted as failed jobs, so a typo cannot
   produce a silently green run.
3. **For each job**, dispatch to `rclone bisync` / `sync` / `copy` with
   `REPLICATE_JOB_ARGS` + per-job `EXTRA_ARGS` appended.
4. **Bisync recovery** (only for `bisync` mode failures): copy both
   directions, then `bisync --resync` to re-establish baselines. See
   [Bisync recovery hardening](#bisync-recovery-hardening) below.
5. **Aggregate exit code**: `0` when every job succeeded (counting
   recoveries), otherwise the count of failed jobs.
6. **`last-replicate.json`** captures `replicate_jobs_processed` and
   `replicate_jobs_failed` plus the common fields.
7. **Mail / webhook**: replicate mails when at least one job recorded an
   unrecoverable error, regardless of `MAILX_ON_ERROR`. Webhook follows
   `WEBHOOK_ON_ERROR` rules.
8. **`post-replicate` hook** with the aggregate exit code.

## Bisync recovery hardening

The default bisync recovery (copy both → `bisync --resync`) is
convenient but can be **destructive** if one endpoint legitimately holds
deletes that you do not want propagated back. Two safety knobs:

### 1. `REPLICATE_BISYNC_CHECK_ACCESS=ON`

Appends `--check-access` to every routine bisync run and the recovery
resync. Rclone aborts loudly when the well-known marker file
(`RCLONE_TEST` by default) is missing on either side — so a remote that
has been wiped no longer looks like "everything got deleted
intentionally" and no one-way deletes propagate.

Seed the marker once on both endpoints before turning the flag on:

```shell
touch /data/inbox/RCLONE_TEST
rclone copyto /data/inbox/RCLONE_TEST jottacloud:inbox/RCLONE_TEST
```

### 2. One-way modes

`sync` and `copy` explicitly skip the destructive copy-both recovery.
If you do not need bidirectional behaviour, prefer `MODE=sync` /
`MODE=copy` so a remote glitch surfaces as a normal failed run instead
of triggering the recovery path.

## Credential masking

Inline credentials in source/destination URLs
(`https://user:pass@host/...`) are masked via `mask_endpoint` in
container logs, `last-replicate.json`, mail and webhook payloads.

Configured `rclone:` remotes (`rclone:jottacloud:inbox`) never had this
problem because credentials live in `rclone.conf` and the URL itself
does not carry them.

## Sample configurations

=== "Single bidirectional inbox"

    ```text
    /data/inbox;jottacloud:inbox
    ```

    ```yaml
    environment:
      REPLICATE_CRON: "*/30 * * * *"
      REPLICATE_BISYNC_CHECK_ACCESS: "ON"
    ```

=== "Mixed bisync / sync / copy"

    ```text
    /data/inbox;jottacloud:inbox;bisync
    /data/site;s3:my-bucket/site;sync
    /data/archive;jottacloud:archive;copy;--immutable
    ```

    ```yaml
    environment:
      REPLICATE_CRON: "0 */4 * * *"
      REPLICATE_JOB_ARGS: "--exclude-from /config/exclude_sync.txt"
    ```

=== "Replicate the restic repo to a second remote"

    ```text
    /mnt/restic;b2:second-remote/restic;sync
    ```

    Combine with `BACKUP_CRON` so the secondary remote always reflects
    the latest restic repository state. Less elegant than restic's
    native `restic copy` but works for any storage backend.

## Failure modes

The aggregate worker exit code is the count of unrecoverable jobs.
Inspect `replicate_jobs_processed` / `replicate_jobs_failed` in
`/var/log/last-replicate.json` for which jobs failed.

| Per-job exit | Meaning |
| --- | --- |
| `0` | Job succeeded (counting recovery). |
| `1` | Generic rclone failure; see `replicate-error-last.log`. |
| `2` | Bad job-line shape (missing column, unknown mode). |
| `7` (rclone) | Fatal directory not found — usually a missing `RCLONE_TEST` marker when `--check-access` is on. |
| `8`–`9` (rclone) | Bisync abort / max-deletes hit; rclone refused to make changes. |

## Run on demand

```shell
docker exec -ti restic-backup-helper /bin/replicate
docker exec -ti restic-backup-helper cat /var/log/last-replicate.json
```

Same code path as the cron job. Use `/bin/doctor` to validate the job
file format before the first scheduled run.

## See also

- [Hooks](../configuration/hooks.md) — `pre-replicate.sh` /
  `post-replicate.sh`.
- [Diagnostics](../operations/diagnostics.md) — replicate job-file
  validation with masked endpoints.
- [Mail notifications](../configuration/mail.md) — replicate mail
  subjects.
