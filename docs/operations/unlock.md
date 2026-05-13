# Unlock

`/bin/unlock` is an explicit, audited wrapper around `restic unlock`. It
pairs with the safer **`RESTIC_AUTO_UNLOCK=OFF`** default (the workers
have not auto-cleared repository locks since 1.12.0): when a job fails
because the repository is locked, the helper logs a hint and lets *you*
decide whether the lock is stale or legitimate before clearing it.

`/bin/unlock` is the operator-driven companion: once you have confirmed
the lock is stale (the holding container is gone, the host is rebooted,
no concurrent backup or check is in flight), run this helper to remove
it. Same audit surface as the other operator wrappers — masked log,
`last-unlock.json`, optional Prometheus textfile, mail / webhook,
`pre-unlock` / `post-unlock` hooks.

It is **operator-initiated** and never cron-driven by itself.

## Why it exists

Pre-1.12.0 the backup, check, forget and prune workers automatically
called `restic unlock` after every failure. On a single-host repository
that "just worked", but on repositories shared by multiple hosts it
silently cleared another host's *legitimate* lock and let two
concurrent mutations race.

Since 1.12.0 the safer default is to **leave the lock alone** and log
a clear hint instead. That means stale locks no longer self-heal — and
they shouldn't, automatically. `/bin/unlock` makes the manual clear
explicit, audited, and gated behind a hook surface and notification
plumbing so the action is visible in the same dashboards as everything
else.

## Quick start

```shell
# Remove stale EXCLUSIVE locks (the safe default; same as `restic unlock`).
docker exec -ti restic-backup-helper /bin/unlock

# Only list current locks; do NOT remove anything.
docker exec -ti restic-backup-helper /bin/unlock --dry-run

# Also remove non-exclusive locks (use only when no concurrent reader is in
# flight: check, prune dry-run, mount, list, snapshot-export, forget-preview).
docker exec -ti restic-backup-helper /bin/unlock --remove-all

# One-shot via docker run (no need for cron startup).
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  unlock --dry-run
```

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--remove-all` | off | Pass `--remove-all` to `restic unlock`; also removes non-exclusive locks. Use only when no concurrent reader (check, prune dry-run, mount, list, snapshot-export, forget-preview) is in flight. |
| `--dry-run` | off | Run `restic list locks` only. **Does not invoke `restic unlock`.** JSON / metrics / mail / webhook are still produced so the audit trail is consistent. |
| `--help` | – | Print usage and exit. |

## What it does

```mermaid
flowchart TD
    A[unlock] --> B[pre-unlock hook]
    B --> C{Validate repo auth}
    C --> D[restic list locks → locks_before]
    D --> E{--dry-run?}
    E -- yes --> F[Skip restic unlock<br/>locks_after = locks_before]
    E -- no --> G{--remove-all?}
    G -- no --> H[restic unlock]
    G -- yes --> I[restic unlock --remove-all]
    H --> J[restic list locks → locks_after]
    I --> J
    F --> K[Write last-unlock.json]
    J --> K
    K --> L[Optional restic_unlock.prom]
    L --> M{MAILX_RCPT? WEBHOOK_URL?}
    M --> N[mail + webhook]
    N --> O[post-unlock hook with "$rc"]
```

## When to use it

Symptoms that suggest a stale lock:

- A worker logs `❌ … Failed with Status 11` (= "failed to lock
  repository") on a repository where no other host or container is
  currently running.
- `restic list locks` still shows a lock ID after the holding process
  has clearly gone (container removed, host rebooted, network mount
  evicted mid-write).
- `RESTIC_AUTO_UNLOCK=OFF` is in effect (the default since 1.12.0) and
  the cron log line `ℹ️ Skipping automatic 'restic unlock'
  (RESTIC_AUTO_UNLOCK!=ON)` recommended manual inspection.

What `/bin/unlock` is **not** for:

- Clearing a lock you have not confirmed is stale. On a repository
  shared by multiple hosts that lock is probably another host's
  legitimate exclusive lock — clearing it lets two backups mutate the
  same repository concurrently. Prefer `--retry-lock=DURATION` in
  `RESTIC_FORGET_ARGS` / `RESTIC_BACKUP_ARGS`, or stagger
  `BACKUP_CRON` / `FORGET_CRON` between hosts, before reaching for
  manual unlock.
- Routine maintenance. Stale locks should be the rare exception, not a
  recurring chore. If you find yourself running `/bin/unlock`
  repeatedly, fix the underlying cause (network flake, OOM-kill,
  missing `--retry-lock`).

## Audit trail

The helper writes:

- `/var/log/unlock-last.log`
- `/var/log/unlock-error-last.log` on failure
- `/var/log/last-unlock.json`
- `restic_unlock.prom` when `METRICS_DIR` is configured

Hooks:

```text
/hooks/pre-unlock.sh                # informational; failure does not abort the unlock
/hooks/post-unlock.sh "$exit_code"  # always called with the restic exit code as $1
```

Mail and webhook notifications use the same `MAILX_*` and `WEBHOOK_*`
settings as the cron-driven workers.

## JSON summary

`/var/log/last-unlock.json` records (in addition to the standard
release / repository / timing fields):

| Field | Type | Meaning |
| --- | --- | --- |
| `remove_all` | string | `ON` when `--remove-all` was used, otherwise `OFF`. |
| `dry_run` | string | `ON` when `--dry-run` was used, otherwise `OFF`. |
| `locks_before` | string | Lock count from `restic list locks` before the unlock call. `"unknown"` when the listing itself failed. |
| `locks_after` | string | Lock count after the unlock call. Equals `locks_before` when `--dry-run` was set. |

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Unlock completed successfully (or `--dry-run` finished). |
| `2` | Configuration error: missing repository credentials. |
| other | Restic returned a failure. Inspect `/var/log/unlock-error-last.log`. |

## See also

- [Backup worker → multi-host repositories and exit 11](../workers/backup.md) — explains
  the auto-unlock default and the multi-host race that `RESTIC_AUTO_UNLOCK=OFF` protects against.
- [Forget worker](../workers/forget.md) — same exit-11 soft-skip semantics; recommends
  `--retry-lock=DURATION` and `FORGET_CRON` staggering as the preferred fix.
- [Forget preview](forget-preview.md) — operator-driven retention preview without taking
  any lock.
- [Diagnostics (doctor)](diagnostics.md) — also surfaces `/var/log/last-unlock.json`.
- [JSON summaries](../reference/json-summaries.md) — schema for `last-unlock.json`.
- [Troubleshooting](troubleshooting.md) — runbook for exit-code-11 and stale-lock
  situations.
