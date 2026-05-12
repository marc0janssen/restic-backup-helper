# Restore

`/bin/restore` is a wrapper around `restic restore` that handles the
nitty-gritty (snapshot selection, empty-target check, dry-run preview,
ownership fix-up, mail/webhook/JSON/metrics) so a real restore stays a
one-liner instead of a panic-driven cheat-sheet exercise.

It is **not cron-driven by design** — restores are always
operator-initiated.

## Two modes

=== "Interactive"

    Invoked from a TTY (`docker exec -ti …`) **without** `--yes`. Lists
    matching snapshots, prompts for index/target/dry-run, and confirms
    with a final `Proceed? [y/N/q]` before mutating anything.

    Flags suppress individual prompts whose answer is already known:

    - `--id` skips the snapshot picker.
    - `--target` skips the target prompt.
    - `--dry-run` skips the dry-run prompt.

    Modifier flags (`--verbose`, `--force`, `--verify`, `--tag`,
    `--host`, `--since`, `--include`, `--exclude`, `--owner`) leave the
    interactive flow fully intact — they are pure behaviour / filter
    overrides.

=== "Non-interactive"

    Invoked without a TTY (cron, CI, `docker exec` without `-t`) **or**
    with `--yes` / `-y` from inside an interactive container shell.
    Skips every prompt; falls back on:

    - `latest` when `--id` is not provided,
    - `/restore` when `--target` is not provided,
    - no dry-run.

    Suitable for cron-jobs, CI smoke tests, runbooks and one-shot
    operator-driven restores.

## Quick start

```shell
docker exec -ti restic-backup-helper /bin/restore --list                          # last 20 snapshots
docker exec -ti restic-backup-helper /bin/restore --list --all                    # every matching snapshot
docker exec -ti restic-backup-helper /bin/restore                                 # interactive
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore # specific snapshot
docker exec -ti restic-backup-helper /bin/restore --dry-run                       # preview latest
docker exec -ti restic-backup-helper /bin/restore --since 2026-05-01 --include /data/documents
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --verbose
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore --yes
```

The container needs a writable `/restore` target. The reference
`scripts/docker-compose.yml` mounts the `restic-restore` named volume
there; bind-mount a host path instead if you want the restored data
directly on disk.

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--id HEX` | *latest* | Restore a specific snapshot by short or long ID. |
| `--tag TAG` | `$RESTIC_TAG` | Filter snapshots by tag. Use `--tag ""` to disable the filter. |
| `--host HOST` | container `$HOSTNAME` | Filter snapshots by host. Use `--host ""` to disable. |
| `--since DATE` | *(off)* | Pick the oldest snapshot newer than `YYYY-MM-DD` or ISO 8601 timestamp. |
| `--target PATH` | `/restore` | Restore destination; must be writable. Refuses non-empty target unless `--force`. |
| `--include PATH` | *(none)* | Repeatable; only restore these paths inside the snapshot tree. Zero matches exit `3`. |
| `--exclude PATH` | *(none)* | Repeatable; skip these paths during restore. |
| `--owner UID:GID` | *(off)* | `chown -R UID:GID TARGET` after a successful (non-dry-run) restore. |
| `--dry-run` | off | Pass restic's own `--dry-run`; nothing is written. Skips ownership change. |
| `--verify` | off | Pass restic's `--verify` so hashes are verified during restore. |
| `--verbose`, `-v` | off | Stream restic's output to stdout while the restore is running. |
| `--yes`, `-y` | off | Skip every prompt; fall back on defaults. |
| `--force` | off | Allow restoring into a non-empty target, **or** into `BACKUP_ROOT_DIR` / `/data`. |
| `--list` | off | List matching snapshots and exit (no restore, no mail/webhook). |
| `--all` | off | With `--list`, show all matching snapshots; without it, show the last 20. |
| `--help` | – | Print the usage banner and exit. |

## Verbose mode internals

`--verbose` is the only knob that needs explanation. Two things happen
when it is on:

- **`--verbose=2` is passed to restic** so each file emits a
  `restored /path/...` line. `--verbose=1` is essentially a no-op for
  `restic restore`.
- **Restic is wrapped in `script(1)`** (from `util-linux`) which
  allocates a pseudo-TTY for it, so its native in-place progress bar
  (`[time] X%, MiB/s, ETA …`) renders instead of being suppressed by
  the `tee` pipe.

Combined output is tee'd to `/var/log/restore-last.log`. That file
therefore contains ANSI escape codes and `\r` overwrites — view with
`cat` on a terminal, or strip with `col -bp`. The structured
`last-restore.json` summary is unaffected: `lib.sh::parse_restic_restore_stats`
normalises `\r → \n` before grepping out the `Summary: …` line.

## Interactive walkthrough

```text
$ docker exec -ti restic-backup-helper /bin/restore
📋 Matching snapshots in s3:s3.example.com/bucket (tag='larak-docs' host='larak'):
  #   SNAPSHOT  TIME                 HOST          TAGS           PATHS
  --- --------  -------------------  ------------  -------------  ----------------------------------
  1   7a4d2f9c  2026-05-09T03:00:11  larak         larak-docs     /data/documents
  2   abc0123d  2026-05-08T03:00:09  larak         larak-docs     /data/documents
  ...

Snapshot to restore [index 1-10 or short-id, default=latest, q=quit]: 1
Restore target [/restore, q=quit]:
Dry-run first? [Y/n/q]:
About to run: restic restore 7a4d2f9c --target /restore --tag larak-docs --host larak --dry-run
(dry-run; no files will be written)
Proceed? [y/N/q]: y
... restic output streamed to /var/log/restore-last.log ...
✅ Restore Successful
🏁 Finished restore at 2026-05-11 Mon 09:42:18 after 0m 4s
```

After the dry-run completes successfully, re-run `/bin/restore` without
`--dry-run` to do the real one (or answer `n` to "Dry-run first?" up
front). Type `q` (or `quit`) at any prompt to abort cleanly — the
helper records `exit_code=130` + `cancelled=true` in `last-restore.json`
(and posts the same payload via the webhook / mail stack) so monitoring
can tell "operator backed out" apart from "restore actually failed".

## Notifications

Mail and webhook notifications fire for every restore by default. They
share the same `MAILX_RCPT`, `WEBHOOK_URL`, `WEBHOOK_HEADER_AUTH`,
`WEBHOOK_ON_ERROR` and `MAILX_ON_ERROR` plumbing as the cron-driven
workers.

Example mail subjects:

```text
Subject: [OK] Restore larak · 1m12s · 4523 files (567.89 MiB) → /restore
Subject: [OK] Restore larak · 4s · DRY-RUN · 4523 files (567.89 MiB) → /restore
Subject: [FAIL 1] Restore larak · 0s · /restore
```

`last-restore.json` contains `snapshot`, `target`, `dry_run`,
`files_restored`, `bytes_restored` and `elapsed_human` when restic
printed them. When the operator types `q` / `quit` at any interactive
prompt — or answers anything other than `y` / `yes` to the final
`Proceed?` prompt — `exit_code` is `130` and `cancelled` is `true`.

When one or more `--include` filters are configured and restic reports
`0` restored files/dirs, the helper treats that as a failed restore
(`exit_code=3`, `include_zero_match=true`). This catches the common
mistake where the snapshot contains `/host/home/admin/docker/...` but
the operator typed `--include /home/admin/docker/...`.

## Hooks

```text
/hooks/pre-restore.sh                # informational; failure does not abort
/hooks/post-restore.sh "$exit_code"  # always called with the restic exit code as $1
```

Useful for unmounting source filesystems before the restore, sending
channel-specific notifications, or chowning the restore target in a way
`--owner` does not cover.

## Safety rails

- Refuses to restore into a non-empty target unless `--force` or
  `--dry-run` is passed.
- Refuses to restore directly into `BACKUP_ROOT_DIR` or `/data` (the
  conventional backup source) unless `--force` is passed — protects
  against the classic "I'll just restore over my source" foot-gun.
- `--owner` is skipped on `--dry-run` so nothing on disk is touched.
- A `chown -R` failure after a successful restore is logged but does
  not turn the run's `exit_code` non-zero (the data is already on disk;
  ownership is a follow-up concern).

## Restore exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Restore succeeded. |
| `1` | Generic restic failure. |
| `2` | Operator-side validation error (bad flags, non-existent snapshot, …). |
| `3` | `--include` filter(s) matched 0 files/dirs. `include_zero_match=true` in JSON. |
| `12` | Wrong password. |
| `130` | Operator cancelled via `Ctrl+C` or typed `q` at a prompt. `cancelled=true` in JSON. |

## See also

- [Snapshot export](snapshot-export.md) — package a snapshot/subtree as a
  `tar.gz` instead of restoring into a target.
- [Mount snapshot](mount-snapshot.md) — browse snapshots read-only over
  FUSE without copying anything to disk first.
- [Manual runs](manual-runs.md) — running `/bin/restore` from `docker
  run` instead of `docker exec`.
- [Hooks](../configuration/hooks.md) — `pre-restore.sh` /
  `post-restore.sh`.
