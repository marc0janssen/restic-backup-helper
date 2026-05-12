# Manual runs

Every worker is a normal `/bin/<name>` executable inside the container,
so you can trigger it on demand via `docker exec` or pass it as the
entrypoint command via `docker run`. Manual runs go through the **same
code path** as cron — hooks fire, `last-<job>.json` updates, mail /
webhook / metrics plumbing applies.

## Quick reference

```shell
# Run scheduled workers immediately.
docker exec -ti restic-backup-helper /bin/backup
docker exec -ti restic-backup-helper /bin/check
docker exec -ti restic-backup-helper /bin/prune
docker exec -ti restic-backup-helper /bin/replicate
docker exec -ti restic-backup-helper /bin/rotate_log

# Operator-driven helpers.
docker exec -ti restic-backup-helper /bin/restore --list
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore
docker exec -ti restic-backup-helper /bin/snapshot-export --id latest
docker exec -ti restic-backup-helper /bin/forget-preview
docker exec -ti restic-backup-helper /bin/mount-snapshot
docker exec -ti restic-backup-helper /bin/doctor

# Raw restic / rclone for the rare case where you need to peek under the hood.
docker exec -ti restic-backup-helper restic snapshots
docker exec -ti restic-backup-helper restic list locks
docker exec -ti restic-backup-helper rclone listremotes
```

## Inspecting state without running anything

```shell
docker exec restic-backup-helper cat /var/log/cron.log         # full cron log
docker exec restic-backup-helper cat /var/log/last-backup.json # most recent backup summary
docker exec restic-backup-helper ls -la /var/log
docker exec restic-backup-helper printenv | grep -E '^(RESTIC|REPLICATE|MAILX|WEBHOOK)'
```

`/bin/doctor` rolls all of this up into a single command — see
[Diagnostics](diagnostics.md).

## Running a one-shot via `docker run`

The image's `/entry.sh` dispatches known subcommands directly instead of
starting cron, so you can use a single-purpose ephemeral container:

```shell
# Configuration sanity check.
docker run --rm \
  --env-file restic.env \
  -v /srv/documents:/data:ro \
  -v ./config:/config:ro \
  marc0janssen/restic-backup-helper:latest \
  config-check

# Diagnostics bundle.
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  doctor

# Snapshot export.
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  -v ./restore:/restore \
  marc0janssen/restic-backup-helper:latest \
  snapshot-export --id latest --include /data/documents

# Retention preview.
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  forget-preview --policy "--keep-daily 7 --keep-weekly 4"

# Mount snapshots read-only under /fusemount (Ctrl+C to unmount).
# No host bind-mount on /fusemount needed: browse via `docker exec` /
# `docker cp` from another terminal while this stays running.
docker run --rm -it \
  --cap-add SYS_ADMIN --device /dev/fuse \
  --security-opt apparmor=unconfined \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  mount-snapshot
```

Recognised entrypoint subcommands:

| Subcommand | Effect |
| --- | --- |
| `config-check` | Validate env and critical paths; exits `0` or `1`. Does not run backups. |
| `doctor` or `/bin/doctor` | Read-only diagnostics bundle. Does not run backups. |
| `snapshot-export` or `/bin/snapshot-export` | Pass remaining args to `/bin/snapshot-export`. |
| `forget-preview` or `/bin/forget-preview` | Pass remaining args to `/bin/forget-preview`; always uses `restic forget --dry-run`. |
| `mount-snapshot` or `/bin/mount-snapshot` | Pass remaining args to `/bin/mount-snapshot`; blocks until you unmount (Ctrl+C / SIGTERM). |

Anything else falls through to the normal cron startup.

## FUSE mount (browse snapshots)

Prefer `/bin/mount-snapshot`: it wraps `restic mount` with safe target
validation, host/tag scope defaults, observability (JSON / hooks /
mail / webhook / metrics) and an `EXIT` trap that always unmounts
cleanly. See the dedicated [Mount snapshot](mount-snapshot.md) page for
the full flag reference and audit trail.

```shell
# Terminal 1 - mount this host's snapshots read-only under /fusemount.
# Keep this running; Ctrl+C unmounts cleanly.
docker exec -ti restic-backup-helper /bin/mount-snapshot

# Terminal 2 - browse and extract while terminal 1 is alive.
docker exec restic-backup-helper ls /fusemount/snapshots/latest
docker exec restic-backup-helper cat /fusemount/snapshots/latest/data/etc/hostname > ./hostname
```

!!! danger "Don't use `docker cp` on `/fusemount/...`"

    `docker cp` bypasses the container's mount namespace, so it does
    not see FUSE mounts established inside the container; it fails
    with `Could not find the file` even when `docker exec ls` works.
    Use `docker exec ... cat > host_file` or
    `docker exec ... tar -cf - | tar -xf -` instead.

See [Mount snapshot → Common recipes](mount-snapshot.md#common-recipes)
for the full pattern catalogue (single file, whole tree,
between-snapshot diff, in-place tar streams).

!!! warning "FUSE needs four things in place"

    `restic mount` will fail with `fusermount: mount failed: Permission
    denied` unless **all** of the following are true:

    1. `--cap-add SYS_ADMIN` (compose: `cap_add: [SYS_ADMIN]`).
    2. `--device /dev/fuse` (compose: `devices: [/dev/fuse:/dev/fuse]`).
    3. `security_opt: [no-new-privileges:true]` is **not** set.
    4. AppArmor profile is `unconfined`, **not** `docker-default
       (enforce)` (Ubuntu/Debian hosts ship the latter by default;
       add `security_opt: [apparmor:unconfined]`).

    The helper pre-flights all four and aborts early with a precise
    error message — see
    [Mount snapshot → Troubleshooting](mount-snapshot.md#troubleshooting).

## When **not** to run manually

- **During the scheduled backup window**: a manual `/bin/backup` started
  inside a running container will collide with the cron-fired one via
  `locked_run`. Either wait for the cron tick or stop the cron daemon
  first (`docker stop restic-backup-helper && docker run --rm …
  /bin/backup`).
- **Right before a planned reboot**: if you run `/bin/prune` and the
  container is killed mid-prune, you may need a manual `restic unlock`
  to clear the repository lock.
- **Across multiple hosts simultaneously**: Restic's repository lock is
  exclusive for writers. Two concurrent `/bin/backup` invocations from
  different hosts will race, and one will fail with "repository is
  already locked".

## See also

- [Diagnostics](diagnostics.md) — `/bin/doctor` for a structured
  inspection.
- [Restore](restore.md) — the operator-driven restore wrapper.
- [Snapshot export](snapshot-export.md) — package a snapshot as a
  `tar.gz`.
- [Forget preview](forget-preview.md) — preview `RESTIC_FORGET_ARGS`
  safely with host/tag scope by default.
- [Mount snapshot](mount-snapshot.md) — browse snapshots read-only over
  FUSE with safe target validation and clean unmount.
- [Troubleshooting](troubleshooting.md) — common manual-run hiccups.
