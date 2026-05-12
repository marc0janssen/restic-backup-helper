# Multiple backup jobs

When one host needs to back up several distinct trees on different
schedules (or with different tags / forget policies), the recommended
pattern is **multiple containers** sharing one Restic repository,
password and cache volume — not a single container with multi-job env.

## Why multiple containers

- One container = one cron daemon = one set of `BACKUP_CRON` /
  `RESTIC_TAG` / `BACKUP_ROOT_DIR`. Adding
  `BACKUP_CRON_documents` / `BACKUP_CRON_media` inside one container
  would require a private DSL or invite cron-collisions and
  ambiguous notifications.
- Multiple containers compose naturally with healthchecks, restart
  policies, log aggregation and `docker compose ps`.
- Lock contention is repository-level (Restic's own lock); per-container
  `flock` is independent and never blocks across jobs.
- Notifications (`MAILX_RCPT`, `WEBHOOK_URL`, `last-<job>.json`, mail
  subjects) are per-container, so each job tells you which dataset it
  was about without extra plumbing.

## Reference: YAML anchors

A complete reference for the pattern lives at
[`examples/compose/multi-job.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/compose/multi-job.yml).

The idea is to use a YAML anchor (`&restic_base`) to share repository
env, the password secret and the cache volume, then declare one service
per dataset with its own `BACKUP_CRON`, `BACKUP_ROOT_DIR`, `RESTIC_TAG`,
`RESTIC_FORGET_ARGS` and `hostname:`:

```yaml
x-restic-env: &restic_env
  RESTIC_REPOSITORY: s3:https://s3.example.com/bucket/restic
  RESTIC_PASSWORD_FILE: /run/secrets/restic_password
  RESTIC_CHECK_REPOSITORY_STATUS: "ON"
  TZ: Europe/Amsterdam
  WEBHOOK_URL: ${HC_PING_URL}
  MAILX_RCPT: ops@example.com
  MAILX_ON_ERROR: "ON"

x-restic-base: &restic_base
  image: marc0janssen/restic-backup-helper:latest
  restart: unless-stopped
  cap_add: [DAC_READ_SEARCH, SYS_ADMIN]
  devices: ["/dev/fuse"]
  secrets: [restic_password]
  volumes:
    - ./config:/config:ro
    - ./config/msmtprc:/etc/msmtprc:ro
    - restic-cache:/.cache/restic
  healthcheck:
    test: ["CMD-SHELL", "restic cat config >/dev/null 2>&1 || exit 1"]
    interval: 30m
    timeout: 30s
    start_period: 1m

services:
  restic-documents:
    <<: *restic_base
    container_name: restic-documents
    hostname: backup-documents
    environment:
      <<: *restic_env
      RESTIC_TAG: documents
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_FORGET_ARGS: "--keep-daily 14 --keep-weekly 8 --keep-monthly 12"
      CHECK_CRON: "37 3 * * 0"       # only this container runs the check
      PRUNE_CRON: "0 4 * * 0"        # only this container runs the prune
    volumes:
      - ./config:/config:ro
      - ./config/msmtprc:/etc/msmtprc:ro
      - restic-cache:/.cache/restic
      - documents-logs:/var/log
      - /srv/documents:/data:ro

  restic-media:
    <<: *restic_base
    container_name: restic-media
    hostname: backup-media
    environment:
      <<: *restic_env
      RESTIC_TAG: media
      BACKUP_CRON: "0 3 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_FORGET_ARGS: "--keep-weekly 12 --keep-monthly 24"
    volumes:
      - ./config:/config:ro
      - ./config/msmtprc:/etc/msmtprc:ro
      - restic-cache:/.cache/restic
      - media-logs:/var/log
      - /srv/media:/data:ro

  restic-vmstore:
    <<: *restic_base
    container_name: restic-vmstore
    hostname: backup-vmstore
    environment:
      <<: *restic_env
      RESTIC_TAG: vmstore
      BACKUP_CRON: "0 5 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_FORGET_ARGS: "--keep-daily 3 --keep-weekly 4"
      RESTIC_JOB_ARGS: "--one-file-system"
    volumes:
      - ./config:/config:ro
      - ./config/msmtprc:/etc/msmtprc:ro
      - restic-cache:/.cache/restic
      - vmstore-logs:/var/log
      - /srv/vmstore:/data:ro

secrets:
  restic_password:
    file: ./restic.password

volumes:
  restic-cache:
  documents-logs:
  media-logs:
  vmstore-logs:
```

## Hard rules

These ground the multi-job pattern in Restic semantics:

!!! danger "`PRUNE_CRON` and `CHECK_CRON` go on exactly **one** container"

    Otherwise N containers each schedule a heavy `restic prune` /
    `restic check` against the same repository on the same cadence and
    trip Restic's repository lock. The convention in the reference
    file is to put both schedules on the **"owner" container** (the
    first one alphabetically, or the one whose dataset is largest).

!!! danger "Keep `RESTIC_AUTO_UNLOCK=OFF`"

    With multiple containers (or worse, multiple hosts) writing to one
    repository, an auto-unlock on container A's failed run can clear
    container B's legitimate lock and corrupt B's snapshot. The 1.12.0
    default (`OFF`) is correct for this pattern.

## Trade-offs

| Pattern | When it fits |
| --- | --- |
| **Many containers, shared repo** | ≥ 2 datasets on different schedules / retention. Maximum isolation. Lowest copy-paste with YAML anchors. Easy to disable one job with `docker compose stop restic-media`. **Recommended for ≥ 2 jobs.** |
| **One container, one repo** | Keep the single-container Compose example, schedule a single `BACKUP_CRON`, and use `RESTIC_JOB_ARGS="--exclude-file /config/excludes.txt"` plus `BACKUP_ROOT_DIR=/data` covering all datasets via separate bind mounts under `/data/`. Simpler when both datasets follow the same retention and timing. |
| **Many containers, many repos** | When the datasets have *very* different retention or one is so sensitive that you want a separate password / encryption boundary. More expensive (more storage, more credentials, more `restic check` runs) so think carefully. |

## Naming conventions

- **`container_name`**: `restic-<dataset>`. Short, unique, easy to refer
  to from `docker logs` / `docker exec`.
- **`hostname`**: `backup-<dataset>`. Appears in mail subjects, JSON
  summaries and webhook payloads.
- **`RESTIC_TAG`**: same as the dataset, e.g. `documents`, `media`,
  `vmstore`. Snapshots can be filtered by tag, so this is what the
  restore wrapper picks up by default.

The combination lets a `restic snapshots --tag documents --host
backup-documents` query the dataset you actually care about, without
needing to remember exact short IDs.

## See also

- [Backup worker](../workers/backup.md) — per-container configuration
  surface.
- [Prune worker](../workers/prune.md) — why prune needs to run on only
  one container.
- [Restore](../operations/restore.md) — picking the right snapshot
  when there are many tags.
