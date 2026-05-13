---
title: Restic Backup Helper
description: >-
  Docker image for scheduled Restic backups, integrity checks, prune,
  optional Rclone replication, structured logs/metrics and operator helpers.
hide:
  - navigation
  - toc
---

# Restic Backup Helper

A batteries-included Docker image built on top of [`restic/restic`](https://hub.docker.com/r/restic/restic)
that wraps **Restic** in a cron-driven pipeline with optional
[**Rclone**](https://rclone.org) replication, **structured logs**, **mail and
webhook notifications**, **Prometheus textfile metrics** and
**operator-grade helpers** for restoring, exporting and diagnosing.

[Get started :material-rocket-launch:](getting-started/quick-start.md){ .md-button .md-button--primary }
[Docker Hub :material-docker:](https://hub.docker.com/r/marc0janssen/restic-backup-helper){ .md-button }
[GitHub :material-github:](https://github.com/marc0janssen/restic-backup-helper){ .md-button }

---

## What you get

<div class="grid cards" markdown>

- :material-database-clock-outline: __Scheduled backup__

    ---

    `/bin/backup` runs on `BACKUP_CRON`, with optional `restic forget` after
    each successful run via `RESTIC_FORGET_ARGS`.

    [:octicons-arrow-right-24: Backup worker](workers/backup.md)

- :material-check-decagram-outline: __Integrity check & prune__

    ---

    Decoupled `CHECK_CRON` and `PRUNE_CRON` so weekly verification and
    monthly compaction can run on their own cadence.

    [:octicons-arrow-right-24: Check & prune](workers/check.md)

- :material-cloud-sync-outline: __Rclone replicate__

    ---

    Push snapshots (or any source path) to a second remote using
    `bisync`, `sync` or `copy`, with credential masking in logs.

    [:octicons-arrow-right-24: Replicate](workers/replicate.md)

- :material-restore: __Operator restore__

    ---

    `/bin/restore` — interactive on a TTY, flag-driven elsewhere — with
    safety rails, snapshot picker, mail/webhook notifications and a
    structured `last-restore.json`.

    [:octicons-arrow-right-24: Restore](operations/restore.md)

- :material-package-variant-closed: __Snapshot export__

    ---

    `/bin/snapshot-export` packages a snapshot or subtree as a `tar.gz`
    archive for offline transfer or support handoff.

    [:octicons-arrow-right-24: Snapshot export](operations/snapshot-export.md)

- :material-eye-check-outline: __Forget preview__

    ---

    `/bin/forget-preview` runs `restic forget --dry-run` with your
    configured retention policy, host/tag-scoped by default.

    [:octicons-arrow-right-24: Forget preview](operations/forget-preview.md)

- :material-folder-eye-outline: __Mount snapshot__

    ---

    `/bin/mount-snapshot` exposes every matching snapshot read-only over
    FUSE under `/fusemount`, with safe target validation and a clean
    unmount on Ctrl+C / SIGTERM.

    [:octicons-arrow-right-24: Mount snapshot](operations/mount-snapshot.md)

- :material-lock-open-outline: __Manual unlock__

    ---

    `/bin/unlock` is the audited counterpart to `RESTIC_AUTO_UNLOCK=OFF`:
    explicit `restic unlock` with masked logging, `last-unlock.json`,
    `pre-unlock` / `post-unlock` hooks and the same mail / webhook
    plumbing as the cron-driven workers.

    [:octicons-arrow-right-24: Unlock](operations/unlock.md)

- :material-clipboard-text-search-outline: __Sources report__

    ---

    `/bin/sources-report` is the pre-flight inventory: readability,
    type, file count and (optional) size for `BACKUP_ROOT_DIR` plus
    every `--files-from` / `--exclude-file` reference in
    `RESTIC_JOB_ARGS`. Catches missing mounts, stale `--files-from`
    entries and silently-empty exclude files before the next backup.

    [:octicons-arrow-right-24: Sources report](operations/sources-report.md)

- :material-database-plus-outline: __Init repo__

    ---

    `/bin/init-repo` is the audited operator counterpart to the
    entrypoint auto-init probe: `--dry-run` reports the planned
    `restic init` command without mutation; without it a typed
    confirmation (`init`) or explicit `--yes` is required, so a
    container restart can never re-initialise a repository
    unattended.

    [:octicons-arrow-right-24: Init repo](operations/init-repo.md)

- :material-stethoscope: __Doctor diagnostics__

    ---

    `/bin/doctor` prints a read-only support bundle; `/bin/cron-list`
    answers "what will run and when?" with timezone, rendered crontab
    and schedule summary.

    [:octicons-arrow-right-24: Diagnostics](operations/diagnostics.md)

- :material-chart-line: __Observability__

    ---

    Per-run JSON summary (`/var/log/last-<job>.json`), optional
    Prometheus textfile collector (`restic_<job>.prom`), webhooks and
    mail with informative subjects.

    [:octicons-arrow-right-24: JSON summaries](reference/json-summaries.md)

- :material-shield-lock-outline: __Security by default__

    ---

    Inline credentials in repository URLs, replicate endpoints and
    webhook URLs are masked in logs and notifications. Secrets stay in
    `RESTIC_PASSWORD_FILE` / Docker secrets / orchestrator secrets.

    [:octicons-arrow-right-24: Security](security.md)

</div>

---

## Quick example

The shortest "it backs up every night and yells when it breaks" setup:

=== "Docker run"

    ```shell
    docker run -d \
      --name restic-backup-helper \
      -e RESTIC_REPOSITORY='s3:https://s3.amazonaws.com/my-bucket/restic' \
      -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
      -e RESTIC_TAG=daily \
      -e BACKUP_CRON='0 2 * * *' \
      -e BACKUP_ROOT_DIR=/data \
      -v /srv/backup-src:/data:ro \
      -v restic-config:/config \
      marc0janssen/restic-backup-helper:latest
    ```

=== "Docker Compose"

    ```yaml
    services:
      restic-backup:
        image: marc0janssen/restic-backup-helper:latest
        environment:
          RESTIC_REPOSITORY: s3:https://s3.amazonaws.com/my-bucket/restic
          RESTIC_PASSWORD_FILE: /run/secrets/restic_password
          RESTIC_TAG: daily
          BACKUP_CRON: "0 2 * * *"
          BACKUP_ROOT_DIR: /data
          MAILX_RCPT: ops@example.com
          MAILX_ON_ERROR: "ON"
          WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
        secrets:
          - restic_password
        volumes:
          - /srv/documents:/data:ro
          - ./config:/config:ro
          - backup-logs:/var/log
    secrets:
      restic_password:
        file: ./restic.password
    volumes:
      backup-logs:
    ```

=== "Kubernetes"

    See the full single-Pod manifest at
    [`examples/kubernetes/restic-backup-helper.yaml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/kubernetes/restic-backup-helper.yaml).

!!! tip "Pin your tags"

    Tagged images use the schema `<helper-semver>-<restic-version>`, e.g.
    `2.9.0-0.18.1`. Pinning both protects you from surprise upstream
    behaviour changes. See [Image tags](reference/image-tags.md).

---

## How the documentation is organised

| Tab | Use it when… |
| --- | --- |
| [Getting started](getting-started/quick-start.md) | You want to install, pull the right tag, or upgrade between minor/major versions. |
| [Concepts](concepts/architecture.md) | You want to understand how cron, workers, locking and the filesystem layout fit together before changing config. |
| [Configuration](configuration/environment-variables.md) | You're looking up an environment variable, hook name, mail/webhook flag or metric. |
| [Workers](workers/backup.md) | You want to know exactly what `/bin/backup`, `/bin/check`, `/bin/prune`, `/bin/replicate` or `/bin/rotate_log` actually does. |
| [Operations](operations/manual-runs.md) | You are an operator running things by hand: restore, snapshot export, forget preview, diagnostics, troubleshooting. |
| [Deployment](deployment/docker-compose.md) | You're writing the Compose / Kubernetes manifest, or hardening the orchestration layer. |
| [Reference](reference/json-summaries.md) | You're integrating with monitoring: JSON schema, Prometheus metric names, image tags, SBOM. |

---

## License & credits

Licensed under the [MIT License](https://github.com/marc0janssen/restic-backup-helper/blob/develop/LICENSE).

Built on top of [`restic/restic`](https://restic.net) and
[`rclone`](https://rclone.org); originally evolved from
[`lobaro/restic-backup-docker`](https://github.com/lobaro/restic-backup-docker).
