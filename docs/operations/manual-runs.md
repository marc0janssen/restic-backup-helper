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
```

Recognised entrypoint subcommands:

| Subcommand | Effect |
| --- | --- |
| `config-check` | Validate env and critical paths; exits `0` or `1`. Does not run backups. |
| `doctor` or `/bin/doctor` | Read-only diagnostics bundle. Does not run backups. |
| `snapshot-export` or `/bin/snapshot-export` | Pass remaining args to `/bin/snapshot-export`. |

Anything else falls through to the normal cron startup.

## FUSE mount (browse snapshots)

```shell
docker run --rm -it \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --entrypoint /bin/sh \
  -e RESTIC_REPOSITORY \
  -e RESTIC_PASSWORD \
  marc0janssen/restic-backup-helper:latest \
  -c "mkdir -p /mnt/browse && restic mount /mnt/browse"
```

Inside the container, `cd /mnt/browse/snapshots/<id>/<path>/` and use
normal shell tooling (`ls`, `cat`, `tar`, `rsync`) to extract specific
files without a full restore. `Ctrl+C` unmounts.

!!! warning "FUSE needs the cap and the device"

    `restic mount` will silently fail without **both** `--cap-add
    SYS_ADMIN` **and** `--device /dev/fuse`. On Kubernetes you need the
    same `securityContext.capabilities.add: [SYS_ADMIN]` plus a
    `/dev/fuse` host-path device.

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
- [Troubleshooting](troubleshooting.md) — common manual-run hiccups.
