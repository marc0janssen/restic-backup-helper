# Repository locks (Restic)

Restic stores **lock files in the repository** (under `locks/` on most backends)
so incompatible operations do not run at the same time. This page explains
**when** you see locks, **why** they sometimes remain, and what this image does
to keep you safe — especially on **multi-host** repositories.

For symptom-driven fixes, see [Troubleshooting → Locking](troubleshooting.md#locking-and-overlapping-ticks).
For the audited unlock helper, see [Unlock](unlock.md).

## How Restic uses locks

- **Non-exclusive locks** — used for work that can overlap with other readers
  or writers in a controlled way (typical `restic backup` traffic).
- **Exclusive locks** — required for operations that must not race with others
  (for example `restic forget`, `restic prune`, and `restic check` in common
  setups). Only one holder at a time.

Which command you run therefore determines whether you see contention,
immediate exit `11` ("failed to lock repository"), or long waits.

Upstream background and interrupted runs:

- Restic may leave a lock behind if a process is **killed** (OOM, `SIGKILL`,
  host reboot) or loses connectivity before it can clean up. Official
  troubleshooting describes interrupted commands and manual recovery with
  `restic unlock` when appropriate:
  [Restic troubleshooting](https://restic.readthedocs.io/en/stable/077_troubleshooting.html).

## Stale lock vs legitimate lock

| Situation | What it means | What to do |
| --- | --- | --- |
| **Stale** | The process that created the lock is gone; no other job should be using the repo. | Inspect with `restic list locks`, then clear with [`/bin/unlock`](unlock.md) (or raw `restic unlock` if you accept unmasked logs). |
| **Legitimate** | Another host or container still holds the lock, or a long job is in flight. | **Do not** `unlock`: wait, reschedule, or use `--retry-lock` / dedicated cron windows (below). |
| **Exit `11` on `forget`** | Another client holds the exclusive forget lock, or forget raced with another forget. | Not a reason to unlock blindly — see [Backup worker → Multi-host](../workers/backup.md#multi-host-repositories-and-exit-11) and [Forget worker](../workers/forget.md). |

## What this image does for you

### Safer default: `RESTIC_AUTO_UNLOCK=OFF`

Since 1.12.0, `/bin/backup` and `/bin/check` **do not** automatically run
`restic unlock` after a failure. That avoids deleting **another host's valid
lock** on a shared repository. Opt in with `RESTIC_AUTO_UNLOCK=ON` only when
**one** machine ever uses the repository.

See [Environment variables → `RESTIC_AUTO_UNLOCK`](../configuration/environment-variables.md).

### Never auto-unlock on forget exit `11`

Inline `restic forget` and the standalone `/bin/forget` worker **never** invoke
`restic unlock` when Restic returns `11`: the lock you lost is almost always
someone else's exclusive lock. Clearing it would allow concurrent mutations.

### Dedicated forget window: `FORGET_CRON`

When `FORGET_CRON` is set, `/bin/backup` **skips** inline post-backup forget and
the standalone `/bin/forget` worker owns the exclusive lock window. That removes
the classic multi-host race where two backups finish together and both try to
forget.

### Local overlap: `/bin/locked_run`

Cron jobs are wrapped with `flock` so the **same container** does not start a
second backup (or check, …) while the previous tick is still running. That is
**independent** of Restic's repository locks but reduces self-inflicted overlap.

### Explicit operator unlock: `/bin/unlock`

When you have **confirmed** a lock is stale, use [`/bin/unlock`](unlock.md) for
masked logging, `last-unlock.json`, hooks, mail and webhooks — same audit
surface as other helpers.

## Preventive checklist

1. **Shared repository** — keep `RESTIC_AUTO_UNLOCK=OFF`; use `/bin/unlock` only
   after `restic list locks` shows no legitimate holder.
2. **Retention** — set `FORGET_CRON` on multi-host repos; reuse
   `RESTIC_FORGET_ARGS` and stagger schedules between hosts (or run forget from a
   single "owner" deployment).
3. **`--retry-lock=DURATION`** — add to `RESTIC_FORGET_ARGS` (Restic ≥ 0.16) so
   forget waits for the exclusive lock instead of returning `11` immediately.
4. **Heavy maintenance** — run `PRUNE_CRON` and `CHECK_CRON` on **one** owner
   container per repository where possible, so N replicas do not all schedule the
   same exclusive work.
5. **Graceful shutdown** — give the container **SIGTERM** and enough stop grace
   time so Restic can exit cleanly; hard kills correlate with stale locks.
6. **Monitoring** — alert on repeated non-zero exits and on
   `restic_backup_last_forget_exit_code` / forget worker metrics when `11`
   persists (schedule collision, not a one-off skip). See
   [Prometheus metrics](../reference/prometheus-metrics.md).

## Further reading

- [Unlock](unlock.md) — operator helper and `--dry-run` / `--remove-all`.
- [Backup worker → Multi-host and exit 11](../workers/backup.md#multi-host-repositories-and-exit-11).
- [Check worker](../workers/check.md) — scheduling checks on multi-host repos.
- [Forget worker](../workers/forget.md) — `FORGET_CRON` and exit `11` handling.
