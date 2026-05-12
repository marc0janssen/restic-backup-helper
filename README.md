# Restic Backup Helper

[![Quality Checks](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml)
[![Smoke Test](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml)
[![Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml)
[![Docs](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/docs.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/docs.yml)

Docker image for scheduled [Restic](https://restic.net) backups, optional scheduled `restic check`, optional [Rclone](https://rclone.org) bidirectional sync (`bisync`), cron-driven automation, structured logs under `/var/log`, and optional mail notifications via `mailx` and [msmtp](https://marlam.de/msmtp/).

**Docker Hub:** [marc0janssen/restic-backup-helper](https://hub.docker.com/r/marc0janssen/restic-backup-helper) · **Source:** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper) · **Docs:** [marc0janssen.github.io/restic-backup-helper](https://marc0janssen.github.io/restic-backup-helper/)

---

## Support this project

If this image saves you time, you can [leave a tip on Ko-fi](https://ko-fi.com/marc0janssen).

**Walkthrough (Jottacloud example):** [Escaping USA Tech, Bye Bye Dropbox, Hello! Jottacloud](https://micro.mjanssen.nl/2025/03/25/escaping-usa-tech-bye-bye.html)

---

## Table of contents

1. [What you get](#what-you-get)
2. [Image tags and release](#image-tags-and-release)
3. [Quick start](#quick-start)
4. [How it works](#how-it-works)
5. [Volumes and filesystem layout](#volumes-and-filesystem-layout)
6. [Environment variables](#environment-variables)
7. [Cron and time zones](#cron-and-time-zones)
8. [Hooks](#hooks)
9. [Examples: Docker Compose](#examples-docker-compose)
10. [Backup backends](#backup-backends)
11. [Optional Rclone replicate jobs](#optional-rclone-replicate-jobs)
12. [Mail notifications](#mail-notifications)
13. [Log rotation](#log-rotation)
14. [Webhook notifications](#webhook-notifications)
15. [Per-run JSON summaries](#per-run-json-summaries)
16. [Logging & privacy](#logging--privacy)
17. [Supply chain (SBOM, Trivy)](#supply-chain-sbom-trivy)
18. [Hardening (read-only root, capabilities, non-root)](#hardening-read-only-root-capabilities-non-root)
19. [Multiple backup jobs](#multiple-backup-jobs)
20. [Operator diagnostics](#operator-diagnostics)
21. [Snapshot export](#snapshot-export)
22. [Forget preview](#forget-preview)
23. [Manual operations](#manual-operations)
24. [Restore (operator-friendly)](#restore-operator-friendly)
25. [Security](#security)
26. [Troubleshooting](#troubleshooting)
27. [Contributing](#contributing)
28. [Documentation site (Material for MkDocs)](#documentation-site-material-for-mkdocs)
29. [Further reading](#further-reading)

---

## What you get

- **Scheduled backup** via `/bin/backup` (cron expression `BACKUP_CRON`), with optional **snapshot policy** (`RESTIC_FORGET_ARGS` runs `restic forget` after a successful backup).
- **Scheduled integrity check** via `/bin/check` when `CHECK_CRON` is non-empty.
- **Scheduled standalone prune** via `/bin/prune` when `PRUNE_CRON` is non-empty (decouples the heavy `restic prune` from per-backup `restic forget`).
- **Scheduled Rclone replication** via `/bin/replicate` when `REPLICATE_CRON` and a valid `REPLICATE_JOB_FILE` are configured. Jobs can run rclone `bisync` (default), `sync` or `copy`.
- **Repository probe on startup**: when `RESTIC_CHECK_REPOSITORY_STATUS=ON`, the entrypoint probes with `restic cat config` and only auto-runs `restic init` when the probe exits **10** (repository does not exist). Other non-zero exits (wrong password, network, DNS, TLS, auth) log restic stderr and abort startup so a transient failure cannot accidentally re-init a healthy remote.
- **Configuration check**: run `docker run … config-check` with the same env as production to validate credentials, backup paths, `RCLONE_CONFIG` and `RESTIC_CACERT` readability without starting cron (CI-friendly).
- **Operator diagnostics**: run `/bin/doctor` for a read-only support bundle: masked effective env, config/path checks, repository probe, replicate job-file validation, hook executable status and recent `/var/log` summaries.
- **Snapshot export**: run `/bin/snapshot-export` to restore a snapshot/subtree into a temporary work directory and package it as a `.tar.gz` archive under `/restore` (or `--output`) for offline transfer / support handoff.
- **Forget preview**: run `/bin/forget-preview` to preview `RESTIC_FORGET_ARGS` with `restic forget --dry-run`, host/tag-scoped by default and repository-wide only with `--repo-wide`.
- **Concurrency**: each job is wrapped in **`/bin/locked_run`** which acquires a dedicated `flock` and, on contention, logs `⏭ <job> skipped: previous run still active` to `/var/log/cron.log` instead of failing silently.
- **Observability**: each run writes `/var/log/last-{backup,check,prune,replicate,restore,snapshot-export,forget-preview}.json` and, when `WEBHOOK_URL` is set, POSTs the same JSON document to your monitoring endpoint (healthchecks.io, Slack, Discord, Gotify, ntfy, …).
- **Hooks**: optional `/hooks/{pre,post}-{backup,check,prune,replicate,restore,snapshot-export,forget-preview}.sh` scripts run before/after each job, with consistent start/exit-code/duration logging and an optional `HOOK_TIMEOUT`.
- **Based on** [`restic/restic`](https://hub.docker.com/r/restic/restic) Alpine image; Restic version follows the `FROM restic/restic:<tag>` line in this repo’s `Dockerfile`.

---

## Image tags and release

release: 2.3.0-0.18.1

| Train | When to use | Example pull |
| --- | --- | --- |
| **Stable** | Production | `docker pull marc0janssen/restic-backup-helper:latest` or pinned `marc0janssen/restic-backup-helper:2.3.0-0.18.1` |
| **Testing** | Pre-release / CI | `docker pull marc0janssen/restic-backup-helper:develop` or `marc0janssen/restic-backup-helper:2.3.0-0.18.1-dev` |

> **Upgrading?**
>
> - **From 2.2.x → 2.3.0:** purely additive. New `/bin/forget-preview` helper runs `restic forget --dry-run` with `RESTIC_FORGET_ARGS`, host/tag-scoped by default (`HOSTNAME` + `RESTIC_TAG`) and repository-wide only with `--repo-wide`. It writes logs, JSON, webhooks/mail and Prometheus metrics like the other helpers.
> - **From 2.2.1 → 2.2.2:** patch / docs release. Adds a full Material for MkDocs documentation site under `docs/` (navigable Getting started / Concepts / Configuration / Workers / Operations / Deployment / Reference tabs, search, dark mode, mermaid diagrams) and a `.github/workflows/docs.yml` GitHub Pages deploy. No runtime / env-var changes. Hosted site: <https://marc0janssen.github.io/restic-backup-helper/>.
> - **From 2.2.0 → 2.2.1:** patch release. CI-only fix in `app/snapshot_export.sh`: combined `# shellcheck disable=SC2317,SC2329` on the EXIT-trap `cleanup()` function and an explicit `copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"` call to satisfy SC2119. No runtime behaviour change, no env-var change.
> - **From 2.1.x → 2.2.0:** purely additive. New `/bin/snapshot-export` helper restores a selected snapshot (or include-filtered subtree) into a temporary workdir and packages it as a `.tar.gz` archive under `/restore` by default. It supports `--id`, `--include`, `--exclude`, `--output`, `--dry-run`, `--verify`, hooks, JSON, webhook, mail and Prometheus metrics.
> - **From 2.0.x → 2.1.0:** purely additive. New `/bin/doctor` read-only diagnostics command for support/triage: prints release/tool versions, masked effective env, path checks, `restic cat config` probe, replicate job-file validation, hook executable status, recent `last-*.json` summaries and the tail of `cron.log`. `docker run … doctor` and `docker run … /bin/doctor` execute it directly without starting cron.
> - **From 1.16.x → 1.17.0:** purely additive — no env-var rename, no behaviour change in the cron-driven workers. New surface only: a new operator-driven `/bin/restore` wrapper (interactive on a TTY, flag-driven otherwise) with mail/webhook notifications enabled by default, a new `/var/log/last-restore.json` summary, and optional `/hooks/{pre,post}-restore.sh`. See [Restore (operator-friendly)](#restore-operator-friendly). The manual `restic restore latest --target /restore` invocation still works unchanged.
> - **From 1.15.x → 1.16.0:** purely additive — no env-var rename, no behaviour change in the workers. New surfaces only:
>   - **SBOM** generation for image builds via `SBOM=ON ./build.sh` (requires `syft`); CI also uploads source-tree SBOMs on tag releases. See [Supply chain](#supply-chain-sbom-trivy).
>   - **`scripts/docker-compose.yml`** now ships two opt-in [Compose profiles](https://docs.docker.com/compose/profiles/): `metrics` (node-exporter sidecar) and `dev` (mailhog SMTP catcher). Existing `docker compose up` invocations keep starting only the main service.
>   - **Multiple backup jobs** pattern at [`examples/compose/multi-job.yml`](examples/compose/multi-job.yml) for setups that already wanted to back up several datasets on different schedules. See [Multiple backup jobs](#multiple-backup-jobs).
>   - **Hardening** docs section enumerates capabilities to drop and tmpfs paths needed for `read_only: true` (orchestration-layer tightening; no image change).
> - **From 1.18.x → 2.0.0:** the old "sync/bisync" surface is renamed to **replicate**. Use `/bin/replicate`, `REPLICATE_*` env vars, `/config/replicate_jobs.txt`, `/hooks/pre-replicate.sh` / `/hooks/post-replicate.sh`, `/var/log/last-replicate.json`, `/var/log/replicate-last.log` and `restic_replicate.prom`. Legacy `SYNC_*` env vars and `/bin/bisync` still work with deprecation warnings and will be removed in 3.0.0. The old `config/sync_jobs.txt` sample is not installed anymore; rename your mounted file or set `REPLICATE_JOB_FILE` explicitly.
> - **From 1.14.x → 1.15.0:** purely additive. New opt-in env vars: `METRICS_DIR` (Prometheus textfile collector) and `REPLICATE_BISYNC_CHECK_ACCESS` (bisync `--check-access` opt-in; legacy `SYNC_BISYNC_CHECK_ACCESS` still accepted until 3.0.0). Mail subjects gain a richer prefix (`[OK|FAIL N] Backup …`); update any subject-based filter rules. Container logs now mask inline credentials in replicate source/destination URLs.
> - **From 1.13.x → 1.14.0:** `RESTIC_TAG=""` (explicitly empty) is now a hard failure with exit code 2 — set a meaningful tag (e.g. `daily`, `${HOSTNAME}-data`). The Dockerfile still defaults to `automated`, so installs that never set `RESTIC_TAG` are unaffected. Replicate job files gain optional `MODE` / `EXTRA_ARGS` columns; existing two-column lines keep working as bisync.
> - **From 1.11.x:** Automatic `restic unlock` after backup / check failures is **opt-in** via `RESTIC_AUTO_UNLOCK=ON` (since 1.12.0). The new default leaves the lock alone (safer for repositories shared across multiple hosts). See the env table below and the [Troubleshooting](#troubleshooting) section for the migration hint.

Pinned tags let you lock both **helper semver** and **Restic base** (`<semver>-<restic>`).

---

## Quick start

Minimal ingredients:

1. Set `RESTIC_REPOSITORY` and authentication (`RESTIC_PASSWORD` or `RESTIC_PASSWORD_FILE`).
2. Set **`RESTIC_TAG`** (required by the backup script; default image value is `automated`).
3. Mount data to back up (commonly `/data`) and a writable `/config` if you use `rclone.conf`, exclude lists, or msmtp.
4. Provide `BACKUP_CRON`.

Example (adjust paths and secrets; do not commit real passwords):

```shell
docker run -d \
  --name restic-backup-helper \
  -e RESTIC_REPOSITORY='s3:https://s3.amazonaws.com/my-bucket/restic' \
  -e RESTIC_PASSWORD='use-a-strong-secret' \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /srv/backup-src:/data:ro \
  -v restic-config:/config \
  marc0janssen/restic-backup-helper:latest
```

For **FUSE / `restic mount`**, add capabilities and device (see [Manual operations](#manual-operations)).

---

## How it works

1. **`/entry.sh`** starts at container boot, prints release metadata (`RESTIC_BACKUP_HELPER_RELEASE`), optionally mounts NFS (`NFS_TARGET`), validates or initializes the repository, then writes **root’s crontab** under `/var/spool/cron/crontabs/root` and runs **`crond`**.
2. **Backup line** (always present): `BACKUP_CRON … /bin/locked_run backup … /bin/backup >> /var/log/cron.log`.
3. **Check line** (optional): appended only if `CHECK_CRON` is non-empty.
4. **Replicate line** (optional): appended only if `REPLICATE_CRON` is non-empty (legacy `SYNC_CRON` is still accepted until 3.0.0).
5. **Prune line** (optional): appended only if `PRUNE_CRON` is non-empty.
6. **Rotate line** (always present): `ROTATE_LOG_CRON … /bin/locked_run rotate_log … /bin/rotate_log`.
6. Default **CMD** tails `/var/log/cron.log` so the container stays foreground-friendly for Compose and logs aggregate cron output.

Worker scripts live at `/bin/backup`, `/bin/check`, `/bin/prune`, `/bin/replicate`, `/bin/restore`, `/bin/snapshot-export`, `/bin/forget-preview`, `/bin/doctor`, `/bin/rotate_log`. The deprecated `/bin/bisync` alias points to `/bin/replicate` until 3.0.0. The cron wrapper itself is `/bin/locked_run`.

---

## Volumes and filesystem layout

| Path | Purpose |
| --- | --- |
| `/data` | Declared `VOLUME`; typical backup source when `BACKUP_ROOT_DIR=/data`. |
| `/config` | Recommended mount for `rclone.conf`, exclude files, `msmtprc`, replicate job file. |
| `/hooks` | Optional mount for hook scripts (see [Hooks](#hooks)). |
| `/var/log` | Optional mount to persist logs on the host. |
| `/restore` | Convention for `restic restore --target /restore` (mount explicitly). |
| `/mnt/restic` | Default `RESTIC_REPOSITORY` path when using local disk or NFS target mount. |

---

## Environment variables

Defaults below match **`Dockerfile`** unless noted. Empty default means unset/blank unless you provide it at runtime.

### Restic core

| Variable | Default | Description |
| --- | --- | --- |
| `RESTIC_REPOSITORY` | `/mnt/restic` | Restic repository location (local path, `s3:…`, `sftp:…`, `rclone:…`, `swift:…`, etc.). |
| `RESTIC_PASSWORD` | *(empty)* | Repository password. |
| `RESTIC_PASSWORD_FILE` | *(empty)* | File inside the container containing the password (Restic standard). |
| `RESTIC_TAG` | `automated` | **Required** tag passed to `restic backup` (`--tag=…`). Since 1.14.0 an explicitly empty value is a hard failure (exit 2) — pick something meaningful (e.g. `daily`, `${HOSTNAME}-data`) so snapshots can be filtered by tag. |
| `RESTIC_CACHE_DIR` | `/.cache/restic` | Restic cache directory. |
| `RESTIC_CACERT` | *(empty)* | When set to a path inside the container that points to a readable PEM bundle, the entrypoint and worker scripts automatically pass `--cacert "$RESTIC_CACERT"` to every `restic` invocation (`backup`, `check`, `forget`, `unlock`, the startup `cat config` probe and `init`). When set but the file is unreadable, a warning is logged and the flag is omitted; **`config-check`** treats the same condition as a hard error. You can still add extra `--cacert` flags via `RESTIC_JOB_ARGS` / `RESTIC_CHECK_ARGS` if you need additional trust roots. |
| `RESTIC_CHECK_REPOSITORY_STATUS` | `ON` | On startup, probe with `restic cat config`; auto-`restic init` only when the probe exits `10` (repo missing). Other non-zero exits (auth, network, TLS, …) abort startup with restic stderr in the container log. Set to anything other than `ON` to skip both the probe and the auto-init. |
| `RESTIC_AUTO_UNLOCK` | `OFF` | When `ON`, `/bin/backup` and `/bin/check` run `restic unlock` after a non-zero restic exit (the historical 1.11.x default). When unset or `OFF`, the lock is **not** touched and a one-line hint is logged instead — recommended for repositories shared across multiple hosts where an automatic unlock could clear another host's legitimate lock. The `restic unlock --remove-all` call in `/entry.sh` after a failed `restic init` is unaffected because that lock can only have been created by the failing init attempt itself. |

### Backup job

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_CRON` | `0 */6 * * *` | Cron schedule for `/bin/backup`. |
| `BACKUP_ROOT_DIR` | *(empty)* | If set, appended as backup path(s). If empty and `RESTIC_JOB_ARGS` is empty, `restic backup` runs with **no explicit path** (usually wrong for normal use—set `BACKUP_ROOT_DIR` or pass paths via `RESTIC_JOB_ARGS`). |
| `RESTIC_JOB_ARGS` | *(empty)* | Extra words passed to `restic backup` (parsed as shell words). Examples: `--exclude-file /config/exclude_files.txt`, `--limit-upload 5000`. |
| `RESTIC_FORGET_ARGS` | *(empty)* | If set **and** backup exits `0`, runs `restic forget` with these words (parsed as shell words), e.g. `--prune --keep-daily 7`. |

### Check job

| Variable | Default | Description |
| --- | --- | --- |
| `CHECK_CRON` | *(empty)* | If non-empty, schedules `/bin/check`. |
| `RESTIC_CHECK_ARGS` | *(empty)* | Extra arguments for `restic check`. |

### Prune job

| Variable | Default | Description |
| --- | --- | --- |
| `PRUNE_CRON` | *(empty)* | If non-empty, schedules a standalone **`/bin/prune`** (via `/bin/locked_run` on its own `/var/run/prune.lock`). Use this to run the heavy `restic prune` on its own cadence (typically weekly) while `RESTIC_FORGET_ARGS` keeps post-backup forget cheap. Independent of `RESTIC_FORGET_ARGS`; if `--prune` is already part of `RESTIC_FORGET_ARGS` the next standalone prune simply has nothing to do. |
| `RESTIC_PRUNE_ARGS` | *(empty)* | Extra words passed to `restic prune` (shell-word split), e.g. `--max-unused 10%`, `--max-repack-size 5G`. |

### NFS

| Variable | Default | Description |
| --- | --- | --- |
| `NFS_TARGET` | *(empty)* | If set, entrypoint runs `mount -o nolock -v "$NFS_TARGET" /mnt/restic`. **Container aborts with exit `1` if the mount fails** so jobs do not run against an empty `/mnt/restic`. Intended workflow keeps `RESTIC_REPOSITORY` at default `/mnt/restic`. |

### Rclone replicate (bisync/sync/copy)

| Variable | Default | Description |
| --- | --- | --- |
| `RCLONE_CONFIG` | `/config/rclone.conf` | Path to Rclone configuration. |
| `REPLICATE_JOB_FILE` | `/config/replicate_jobs.txt` | Job file: `SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]` per line (comments `#` allowed). See [Optional Rclone replicate jobs](#optional-rclone-replicate-jobs). Legacy `SYNC_JOB_FILE` is accepted until 3.0.0. |
| `REPLICATE_JOB_ARGS` | *(empty)* | Extra global args passed to every rclone job (shell-word split; `--resync` is stripped from routine runs). Per-job extras can be added via the 4th column of `REPLICATE_JOB_FILE`. Legacy `SYNC_JOB_ARGS` is accepted until 3.0.0. |
| `REPLICATE_CRON` | *(empty)* | If non-empty, schedules `/bin/replicate`. Legacy `SYNC_CRON` is accepted until 3.0.0. |
| `REPLICATE_VERBOSE` | `ON` | When `ON`, replicate messages also echo to stdout (still always logged to file). Legacy `SYNC_VERBOSE` is accepted until 3.0.0. |
| `REPLICATE_BISYNC_CHECK_ACCESS` | `OFF` | When `ON`, appends `--check-access` to the routine `bisync` runs and the recovery `bisync --resync`. Requires the well-known `RCLONE_TEST` marker file to exist on both endpoints; rclone aborts loudly when it is missing instead of treating one side as "everything deleted". One-way `sync`/`copy` modes are unaffected. Legacy `SYNC_BISYNC_CHECK_ACCESS` is accepted until 3.0.0. See [Optional Rclone replicate jobs](#optional-rclone-replicate-jobs). |

### Mail

| Variable | Default | Description |
| --- | --- | --- |
| `MAILX_RCPT` | *(empty)* | If set, backup/check can mail logs (see [Mail notifications](#mail-notifications)). |
| `MAILX_ON_ERROR` | `OFF` | When `ON`, backup and check only send mail after a **failed** run. Replicate mails only when at least one job error occurred (see scripts). |

### Webhook

| Variable | Default | Description |
| --- | --- | --- |
| `WEBHOOK_URL` | *(empty)* | When set, backup/check/sync POST the same JSON document as `/var/log/last-<job>.json` (see [Webhook notifications](#webhook-notifications)). |
| `WEBHOOK_HEADER_AUTH` | *(empty)* | Sent verbatim as `Authorization: <value>` (e.g. `Bearer …`, `Token …`). Not echoed in logs. |
| `WEBHOOK_TIMEOUT` | `10` | Curl `--max-time` in seconds. Non-positive values fall back to 10. |
| `WEBHOOK_ON_ERROR` | `OFF` | When `ON`, only fire on non-zero job exit codes (mirrors `MAILX_ON_ERROR`). |

### Prometheus metrics (textfile collector)

| Variable | Default | Description |
| --- | --- | --- |
| `METRICS_DIR` | *(empty)* | When set to a writable directory inside the container, every worker writes a `restic_<job>.prom` document there (atomic tmp+mv) with the same data as `/var/log/last-<job>.json`. Mount that directory into the host and point a node-exporter `--collector.textfile.directory` at it. Empty default keeps the feature off. See [Per-run JSON summaries](#per-run-json-summaries). |

### Log rotation (`/var/log/cron.log`)

| Variable | Default | Description |
| --- | --- | --- |
| `ROTATE_LOG_CRON` | `0 0 * * 6` | Cron schedule for `/bin/rotate_log`. |
| `CRON_LOG_MAX_SIZE` | `1048576` | Rotate when `cron.log` exceeds this size (bytes). |
| `MAX_CRON_LOG_ARCHIVES` | `5` | Keep this many compressed archives `cron_log_<timestamp>.tar.gz`. |

### Hooks

| Variable | Default | Description |
| --- | --- | --- |
| `HOOK_TIMEOUT` | `0` | When `> 0`, wraps each `/hooks/*.sh` invocation in `timeout ${HOOK_TIMEOUT}s`. Exit code `124` (timed out) is logged prominently as an error. `0` keeps the historical behaviour of no enforced timeout. |

### OpenStack Swift (when using `swift:` repository)

| Variable | Default |
| --- | --- |
| `OS_AUTH_URL` | *(empty)* |
| `OS_PROJECT_ID` | *(empty)* |
| `OS_PROJECT_NAME` | *(empty)* |
| `OS_USER_DOMAIN_NAME` | `Default` |
| `OS_PROJECT_DOMAIN_ID` | `Default` |
| `OS_USERNAME` | *(empty)* |
| `OS_PASSWORD` | *(empty)* |
| `OS_REGION_NAME` | *(empty)* |
| `OS_INTERFACE` | *(empty)* |
| `OS_IDENTITY_API_VERSION` | `3` |

### AWS S3

Use standard AWS variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, etc.) as required by Restic’s S3 backend; they are not declared in the Dockerfile but are honored by the runtime.

### Locale / time

| Variable | Default | Description |
| --- | --- | --- |
| `TZ` | `Europe/Amsterdam` | Container timezone; cron typically respects `TZ` when set in the environment used by `crond`. |

---

## Cron and time zones

Crontab entries are written literally from `BACKUP_CRON`, `CHECK_CRON`, `REPLICATE_CRON`, `PRUNE_CRON` and `ROTATE_LOG_CRON`. Each entry is wrapped in `/bin/locked_run` so overlapping ticks log `⏭ <job> skipped: previous run still active` to `/var/log/cron.log` instead of failing silently. Ensure **`TZ`** matches how you expect schedules to fire. For UTC-only mental models, set `TZ=UTC`.

---

## Hooks

Mount scripts into **`/hooks`**:

| Hook | When |
| --- | --- |
| `/hooks/pre-backup.sh` | Before backup |
| `/hooks/post-backup.sh` | After backup; receives **backup exit code** as `$1` |
| `/hooks/pre-check.sh` | Before check |
| `/hooks/post-check.sh` | After check; receives **check exit code** as `$1` |
| `/hooks/pre-prune.sh` | Before prune |
| `/hooks/post-prune.sh` | After prune; receives **prune exit code** as `$1` |
| `/hooks/pre-replicate.sh` | Before replicate batch |
| `/hooks/post-replicate.sh` | After replicate batch; receives **aggregate exit code** as `$1` |
| `/hooks/pre-restore.sh` | Before restore |
| `/hooks/post-restore.sh` | After restore; receives **restore exit code** as `$1` |
| `/hooks/pre-snapshot-export.sh` | Before snapshot export |
| `/hooks/post-snapshot-export.sh` | After snapshot export; receives **snapshot export exit code** as `$1` |
| `/hooks/pre-forget-preview.sh` | Before forget preview |
| `/hooks/post-forget-preview.sh` | After forget preview; receives **forget preview exit code** as `$1` |

Hooks must be executable inside the container (`chmod +x`); a hook present but **not executable** is reported as an error in the cron log instead of silently doing nothing. Set **`HOOK_TIMEOUT`** to a positive integer to wrap each invocation in `timeout ${HOOK_TIMEOUT}s`; the runner logs `pre-*`/`post-*` start, exit code and duration in a uniform format and reports timeouts (exit `124`) prominently. Hook exit codes are logged but do **not** propagate to the worker exit code (the cron job is still considered successful when the underlying restic/rclone command succeeded).

---

## Examples: Docker Compose

This is a **complete reference** stack that exercises every option exposed by the image. Comment out (or delete) the sections you do not need; the **only** strictly required keys are `RESTIC_REPOSITORY`, a password (`RESTIC_PASSWORD_FILE` or `RESTIC_PASSWORD`), `RESTIC_TAG`, `BACKUP_CRON` and a backup source mounted into the container. Use a `.env` file (gitignored) or Docker secrets for credentials — never commit `restic.password`, `rclone.conf`, `msmtprc`, or webhook tokens.

```yaml
# docker-compose.yml — reference stack with all options; trim to taste.
# Required at runtime at minimum: RESTIC_REPOSITORY, a password, RESTIC_TAG, BACKUP_CRON.

services:
  restic-backup:
    image: marc0janssen/restic-backup-helper:latest
    container_name: restic-backup-helper
    hostname: backup-node            # appears in mail subjects, JSON summaries, webhook payloads
    restart: unless-stopped

    # Needed for `restic mount` (FUSE) and reading source paths under tight ACLs.
    cap_add:
      - DAC_READ_SEARCH
      - SYS_ADMIN
    devices:
      - /dev/fuse

    # Non-secret defaults can live in restic.env (gitignored). Secrets belong in `secrets:` below.
    env_file:
      - restic.env

    environment:
      # ─── Restic core ───────────────────────────────────────────────────────────
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY:?set in restic.env or shell}
      # Preferred: mount the password as a Docker secret and point Restic at the file.
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      # Fallback (less secure, kept here for clarity):
      # RESTIC_PASSWORD: ${RESTIC_PASSWORD}
      RESTIC_TAG: ${RESTIC_TAG:-daily}
      RESTIC_CACHE_DIR: /.cache/restic
      # RESTIC_CACERT: /config/ca-bundle.pem   # set when using a private CA / corp proxy
      RESTIC_CHECK_REPOSITORY_STATUS: "ON"     # probe with `restic cat config`, auto-init only on exit 10
      # RESTIC_AUTO_UNLOCK: "ON"               # opt-in; only safe when ONE host writes to this repo

      # ─── Backup job (always runs) ──────────────────────────────────────────────
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_JOB_ARGS: "--exclude-file /config/exclude_files.txt --one-file-system"
      RESTIC_FORGET_ARGS: "--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10"

      # ─── Optional: scheduled integrity check ───────────────────────────────────
      CHECK_CRON: "37 3 * * 0"                 # weekly; leave empty to disable
      # RESTIC_CHECK_ARGS: "--read-data-subset 5%"

      # ─── Optional: standalone prune (decoupled from forget) ────────────────────
      PRUNE_CRON: "0 4 * * 0"                  # weekly; leave empty to disable
      RESTIC_PRUNE_ARGS: "--max-unused 10%"

      # ─── Optional: Rclone replicate (bisync/sync/copy) ────────────────────────
      RCLONE_CONFIG: /config/rclone.conf
      REPLICATE_JOB_FILE: /config/replicate_jobs.txt
      REPLICATE_JOB_ARGS: "--exclude-from /config/exclude_sync.txt"
      REPLICATE_CRON: "*/30 * * * *"           # leave empty to disable replicate
      REPLICATE_VERBOSE: "ON"

      # ─── Optional: NFS-mounted repo target (then keep RESTIC_REPOSITORY=/mnt/restic) ─
      # NFS_TARGET: "nfs-server:/export/restic"

      # ─── Mail notifications (msmtp via /etc/msmtprc) ───────────────────────────
      MAILX_RCPT: ops@example.com
      MAILX_ON_ERROR: "ON"                     # OFF = mail every run; ON = only on failure

      # ─── Webhook notifications (healthchecks.io / Slack / Gotify / ntfy / …) ───
      WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
      # WEBHOOK_HEADER_AUTH: "Bearer your-token"   # never echoed in logs
      WEBHOOK_TIMEOUT: "15"
      WEBHOOK_ON_ERROR: "OFF"                  # OFF = post every run; ON = only on failure

      # ─── Hooks (/hooks/{pre,post}-{backup,check,prune,replicate}.sh) ──────────
      HOOK_TIMEOUT: "300"                      # seconds; 0 = no enforced timeout

      # ─── Log rotation (/var/log/cron.log) ──────────────────────────────────────
      ROTATE_LOG_CRON: "0 0 * * 6"
      CRON_LOG_MAX_SIZE: "1048576"             # 1 MiB
      MAX_CRON_LOG_ARCHIVES: "5"

      # ─── Locale / time ─────────────────────────────────────────────────────────
      TZ: Europe/Amsterdam

    secrets:
      - restic_password

    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config:ro                    # rclone.conf, exclude lists, replicate_jobs.txt, ca-bundle.pem
      - ./config/msmtprc:/etc/msmtprc:ro       # only needed when MAILX_RCPT is set
      - ./hooks:/hooks:ro                      # only needed when you ship hook scripts
      - backup-logs:/var/log                   # persists last-*.json, cron.log, archives
      - restic-cache:/.cache/restic            # speeds up subsequent backups
      - /srv/documents:/data:ro                # backup source — adjust to taste
      # - /mnt/restic:/mnt/restic              # uncomment for local/NFS repo target
      # - ./restore:/restore                   # convention for `restic restore --target /restore`
      # - ~/.ssh:/root/.ssh:ro                 # only needed for sftp: repositories

    healthcheck:
      # Strong probe — fails when credentials or repo reachability break.
      test: ["CMD-SHELL", "restic cat config >/dev/null 2>&1 || exit 1"]
      interval: 15m
      timeout: 30s
      start_period: 1m
      start_interval: 10s

    command: ["tail", "-fn0", "/var/log/cron.log"]

secrets:
  restic_password:
    file: ./restic.password                    # gitignored; chmod 600 on the host

volumes:
  backup-logs:
  restic-cache:
```

A runnable, less commented variant lives at [`scripts/docker-compose.yml`](scripts/docker-compose.yml) for quick `docker compose up` testing. A heavily commented, anonymized cloud-remote reference lives at [`examples/compose/cloud-reference.yml`](examples/compose/cloud-reference.yml) when you want a complete private-registry / rclone-style stack to trim down. The quick-start file also ships two **opt-in [Compose profiles](https://docs.docker.com/compose/profiles/)** so you do not have to fork it for ancillary services:

| Profile | Adds | Why |
| --- | --- | --- |
| `metrics` | `node-exporter` sidecar bound to `127.0.0.1:9100`, scraping the `backup-logs` volume's `textfile_collector/` subdirectory | Exposes the `restic_<job>_last_*` gauges from `METRICS_DIR` over HTTP without a host-level node-exporter. |
| `dev` | `mailhog` SMTP catcher (port 1025 SMTP, 8025 web UI; both bound to `127.0.0.1`) | Local end-to-end test of `MAILX_RCPT` mail subjects/bodies without a real relay. Point your `msmtprc` at `host mailhog`, `port 1025` (no auth, no TLS). |

```shell
docker compose up                       # only the restic-backup service
docker compose --profile metrics up     # + node-exporter sidecar
docker compose --profile dev up         # + mailhog SMTP catcher
docker compose --profile metrics --profile dev up   # both
```

The main `restic-backup` service has no `profiles:` key, so it is always brought up regardless of which profile (if any) you pick. For Kubernetes a full single-Pod manifest (Deployment + Secret + PVC, FUSE-friendly capabilities, strong liveness probe and pre-wired `METRICS_DIR`) is at [`examples/kubernetes/restic-backup-helper.yaml`](examples/kubernetes/restic-backup-helper.yaml).

**Health checks:** choose how hard you want Compose to probe the repository.

- **Weak** — only verifies the Restic binary (no repository access):

```yaml
healthcheck:
  test: ["CMD", "restic", "version"]
  interval: 5m
  timeout: 10s
  retries: 3
```

- **Strong** — fails if credentials or repository reachability break (uses `RESTIC_*` env inside the container; same as the reference stack above):

```yaml
healthcheck:
  test: ["CMD-SHELL", "restic cat config >/dev/null 2>&1 || exit 1"]
  interval: 15m
  timeout: 30s
  start_period: 1m
```

`restic snapshots` is a heavier alternative when you want an end-to-end read against the repo.

---

## Backup backends

### Local repository

Point `RESTIC_REPOSITORY` at a mounted path (for example `/mnt/restic`) and persist that volume.

### NFS

Set `NFS_TARGET` (example: `nfs-server:/export/restic`) and keep `RESTIC_REPOSITORY=/mnt/restic` so the mount target matches the repo path.

### SFTP

Restic needs non-interactive SSH auth. Mount keys read-only:

```shell
-v ~/.ssh:/root/.ssh:ro
```

Example repository: `sftp:user@host:/path/to/repo`.

### S3 and compatible APIs

Example: `s3:s3.amazonaws.com/bucket-name/prefix` or custom endpoint per Restic docs. Provide AWS (or provider) credentials via environment.

### Rclone remote

Use `rclone:<remote>:<path>` form for `RESTIC_REPOSITORY` and supply `RCLONE_CONFIG`. Some providers refresh tokens inside `rclone.conf`; keep that file on a writable mount.

### OpenStack Swift

Use `swift:container:/path` style URLs and populate the `OS_*` variables.

---

## Optional Rclone replicate jobs

`REPLICATE_JOB_FILE` lines (semicolon-separated, comments and blank lines allowed):

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
| `EXTRA_ARGS` | no | Per-job rclone flags appended after `REPLICATE_JOB_ARGS`. Shell-word split. `--resync` is filtered out so a routine run can never resync implicitly. |

Schedule with `REPLICATE_CRON`. **Recovery procedure** (copy both directions then `bisync --resync`) only runs for `bisync` failures; `sync` and `copy` failures surface immediately without an automatic destructive recovery — that is intentional because a one-way `sync` failure may already represent the operator's intended state diverging. Mail is sent only when at least one job recorded an unrecoverable error (and `MAILX_RCPT` is set); the same payload is POSTed to `WEBHOOK_URL` when configured. Malformed lines (missing `SOURCE`/`DESTINATION` or unknown `MODE`) count as failed jobs and trigger the same notification path so a typo cannot produce a silently green run.

Legacy `SYNC_*` env vars and `/bin/bisync` remain accepted until 3.0.0 with deprecation warnings, but new deployments should use `REPLICATE_*` and `/bin/replicate`. The old sample name `config/sync_jobs.txt` is not installed anymore; rename it to `config/replicate_jobs.txt` or set `REPLICATE_JOB_FILE` to the path you mount.

#### Bisync recovery hardening

The default bisync recovery (copy both → `bisync --resync`) is convenient but can be **destructive** if one endpoint legitimately holds deletes that you do not want propagated back. Two safety knobs:

1. **`REPLICATE_BISYNC_CHECK_ACCESS=ON`** appends `--check-access` to every bisync run and to the recovery resync. Rclone aborts loudly when the well-known marker file (`RCLONE_TEST` by default) is missing on either side — so a remote that has been wiped no longer looks like "everything got deleted intentionally" and no one-way deletes propagate.

   Seed the marker once on both endpoints before turning the flag on:

   ```shell
   touch /data/inbox/RCLONE_TEST
   rclone copyto /data/inbox/RCLONE_TEST jottacloud:inbox/RCLONE_TEST
   ```

2. **One-way modes** (`sync`, `copy`) explicitly skip the destructive copy-both recovery. If you do not need bidirectional behaviour, prefer `MODE=sync` / `MODE=copy` so a remote glitch surfaces as a normal failed run instead of triggering the recovery path.

Inline credentials in source/destination URLs (`https://user:pass@host/...`) are now masked in container logs and recovery messages, so a verbose error trace will not leak basic-auth secrets to `cron.log`. Configured `rclone:` remotes never had this problem because credentials live in `rclone.conf`.

---

## Mail notifications

- **Backup / check / prune:** If `MAILX_RCPT` is set, mail goes out per run unless `MAILX_ON_ERROR=ON`, in which case mail is sent only on failure.
- **Sync:** Mail is sent when `MAILX_RCPT` is set **and** at least one job recorded an error.

Subjects (since 1.15.0) follow the pattern `[OK|FAIL <code>] <Job> <hostname> · <duration> · <details>`, so a glance at your inbox tells you status, host, run length and (where available) the headline metric:

| Worker | Example subject |
| --- | --- |
| Backup | `[OK] Backup larak · 5m12s · 1.234 MiB new (snap a1b2c3d4)` |
| Check | `[FAIL 12] Check larak · 7s · rclone:jottacloud:backups` |
| Prune | `[OK] Prune larak · 2h14m · rclone:jottacloud:backups` |
| Sync | `[OK] Sync larak · 12m · 3 jobs (0 failed)` |

Mount msmtp configuration so `/usr/sbin/sendmail` (symlinked to `msmtp`) can relay mail, for example:

```shell
-v ./config/msmtprc:/etc/msmtprc:ro
```

---

## Log rotation

`/bin/rotate_log` compresses oversized `cron.log` to `/var/log/cron_log_<timestamp>.tar.gz` and trims old archives. Tune `ROTATE_LOG_CRON`, `CRON_LOG_MAX_SIZE`, and `MAX_CRON_LOG_ARCHIVES`.

---

## Webhook notifications

Set **`WEBHOOK_URL`** to a fully-qualified HTTP/HTTPS endpoint and the workers will POST the **same JSON document** as `/var/log/last-<job>.json` (see [Per-run JSON summaries](#per-run-json-summaries) for the schema) after each run. This pairs with the file sink so you have both a pull and a push interface — choose either or both depending on your monitoring stack.

| Setting | Behaviour |
| --- | --- |
| `WEBHOOK_URL` unset | No-op; nothing is posted. |
| `WEBHOOK_URL` set, `WEBHOOK_ON_ERROR=OFF` (default) | POST after every run regardless of exit code. |
| `WEBHOOK_URL` set, `WEBHOOK_ON_ERROR=ON` | POST only when the job exited with a non-zero code. |
| `WEBHOOK_HEADER_AUTH` set | Added as `Authorization: <value>` (`Bearer …`, `Token …`, etc.). Value is never echoed to logs. |
| `WEBHOOK_TIMEOUT` (default `10`) | Curl `--max-time` in seconds; a hung endpoint cannot block a backup. |

Failures (curl non-zero exit, HTTP non-2xx, timeout) are logged as errors but **never propagate to the worker exit code**, so a flaky webhook endpoint will not turn an otherwise-successful backup into a failed one. Container logs only show `scheme://host/...` for the configured URL — per-recipient secrets in path/query (healthchecks.io UUIDs, Slack/Discord webhook tokens, ntfy topic names, …) are not echoed.

Compatible out of the box with **healthchecks.io**, **Slack** / **Discord** / **Mattermost incoming webhooks**, **Gotify**, **ntfy**, **Apprise** receivers, and any custom HTTPS endpoint that accepts a JSON POST.

```yaml
environment:
  WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
  WEBHOOK_ON_ERROR: "OFF"
  WEBHOOK_TIMEOUT: "15"
```

---

## Per-run JSON summaries

Each worker writes a structured summary of its **last run** under `/var/log` after it finishes, intended for external monitoring without requiring a daemon or push gateway:

| File | Written by | Useful fields |
| --- | --- | --- |
| `/var/log/last-backup.json` | `/bin/backup` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked), `backup_root_dir`, `restic_tag`, plus — when restic produced them — `snapshot_id`, `files_new` / `files_changed` / `files_unmodified`, `bytes_added` / `bytes_stored` (human strings such as `1.234 MiB`) |
| `/var/log/last-check.json` | `/bin/check` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked) |
| `/var/log/last-prune.json` | `/bin/prune` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked) |
| `/var/log/last-replicate.json` | `/bin/replicate` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `replicate_jobs_processed`, `replicate_jobs_failed` |
| `/var/log/last-restore.json` | `/bin/restore` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked), `snapshot`, `target`, `dry_run`, plus — when restic printed its summary line — `files_restored`, `bytes_restored` (human string), `elapsed_human`; on `Ctrl-C`/operator cancel `exit_code` is `130` and `cancelled` is `true`; when `--include` matches 0 files/dirs, `exit_code` is `3` and `include_zero_match` is `true` |
| `/var/log/last-snapshot-export.json` | `/bin/snapshot-export` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked), `snapshot`, `archive`, `work_dir`, `dry_run`, `include_zero_match`, plus — when restic printed its summary line — `files_restored`, `bytes_restored`, `elapsed_human`; on successful archive creation, `archive_size_bytes` is included |
| `/var/log/last-forget-preview.json` | `/bin/forget-preview` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked), `repo_wide`, `policy_args`, `extra_args`, and when host/tag-scoped: `host_filter`, `tag_filter` |

Files are overwritten atomically each run (write to `*.tmp`, then `mv`). Mount `/var/log` on the host to scrape them, or feed them into Prometheus textfile collectors, Datadog log pipelines, or simple shell scripts. The backup-stats keys (`snapshot_id`, `files_*`, `bytes_*`) are best-effort: when a backup fails before restic prints them, they are simply omitted from the JSON.

### Prometheus textfile collector

Set **`METRICS_DIR`** to a writable path inside the container (for example `/var/log/textfile_collector`) and every worker writes a `restic_<job>.prom` document there alongside `last-<job>.json`. Mount that directory into the host and point your node-exporter at it:

```shell
node_exporter --collector.textfile.directory=/var/log/textfile_collector
```

Always-emitted gauges (one of each per `<job>` ∈ `backup`, `check`, `prune`, `replicate`, `restore`, `snapshot_export`, `forget_preview`):

| Metric | Meaning |
| --- | --- |
| `restic_<job>_last_exit_code{hostname="…"}` | Exit code of the most recent run. |
| `restic_<job>_last_success{hostname="…"}` | `1` when exit code was 0, else `0`. |
| `restic_<job>_last_duration_seconds{hostname="…"}` | Wall-clock duration of the run. |
| `restic_<job>_last_finished_timestamp{hostname="…"}` | Unix epoch seconds at which the run ended. Useful for `time() - restic_backup_last_finished_timestamp` alerting. |

Extra numeric fields in `last-<job>.json` (for example `files_new`, `bytes_added` when restic produced bytes as a number, `replicate_jobs_processed`, `replicate_jobs_failed`) are emitted as `restic_<job>_last_<key>`. Non-numeric extras (such as the human-formatted `bytes_added="1.234 MiB"` or the masked `repository`) are intentionally skipped to keep the textfile strictly typed for Prometheus.

Files are atomic (`.tmp` + `mv`) so a node-exporter scrape never sees a partial file. Leave `METRICS_DIR` empty to disable the export entirely (default).

---

## Logging & privacy

The image is intentionally chatty about what it ran and why, but never about secrets. The masking and redaction rules:

- **Repository URLs** (`scheme://user:password@host`, `backend:user:password@host`) — userinfo is replaced with `:***` before being printed, written to `last-<job>.json`, posted to webhooks, or used in mail subjects (`mask_repository`).
- **Replicate source/destination** with inline credentials — same masking via `mask_endpoint`. Configured `rclone:` remotes have credentials in `rclone.conf` and never leak through.
- **Webhook URL** — only the `scheme://host/...` is logged; the full URL with per-recipient secrets in path/query (healthchecks.io UUIDs, Slack tokens, ntfy topics) never appears (`mask_webhook_url`).
- **Webhook auth header** (`WEBHOOK_HEADER_AUTH`) — never echoed; logs only mention `auth header set`.
- **Restic / msmtp passwords** — read from env or password file by restic/msmtp directly; never echoed by the helper scripts.
- **`RESTIC_JOB_ARGS` / `RESTIC_FORGET_ARGS` / `RESTIC_PRUNE_ARGS` / `REPLICATE_JOB_ARGS`** — printed verbatim because they are caller-controlled. Avoid stuffing secrets into these (use `RESTIC_PASSWORD_FILE` and `--password-command` files instead).
- **Hook scripts** — the runner logs `pre-*` / `post-*` start, exit code and duration but never the script's stdout/stderr unless your hook itself prints. Make sure your hook does not echo secrets to stdout.

To audit what your container actually logs:

```shell
docker exec -ti restic-backup-helper cat /var/log/cron.log
docker exec -ti restic-backup-helper cat /var/log/last-backup.json
```

---

## Supply chain (SBOM, Trivy)

Two complementary tools document what is inside this image and surface CVEs against it:

- **Trivy** runs in the [Security Scan](.github/workflows/security-scan.yml) workflow on every push and weekly, and in [Release Orchestration](.github/workflows/release-orchestration.yml) on tag pushes. SARIF results upload to the GitHub Security tab; the release workflow additionally fails on any `CRITICAL`/`HIGH` finding so a tag never ships with a known critical vulnerability.
- **SBOMs** (Software Bill of Materials) are emitted in two places, depending on whether you publish locally or via CI:

  | Source | Tool | Where | When |
  | --- | --- | --- | --- |
  | Pushed image (preferred) | [`syft`](https://github.com/anchore/syft) | `./sbom/restic-backup-helper-<release>.{spdx,cyclonedx}.json` | After `./build.sh` / `./build-testing.sh` when `SBOM=ON` and `syft` is on `PATH`. |
  | Source tree (fallback) | [`anchore/sbom-action`](https://github.com/anchore/sbom-action) | Workflow run artifact `release-orchestration-diagnostics` (`sbom-source.{spdx,cyclonedx}.json`) | Every tag push (`v*`) via the release workflow. |

  Enable image-level SBOMs locally:

  ```shell
  # one-off install (macOS/Linux):
  curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin
  SBOM=ON ./build.sh
  # → sbom/restic-backup-helper-1.16.0-0.18.1.spdx.json
  # → sbom/restic-backup-helper-1.16.0-0.18.1.cyclonedx.json
  ```

  The `sbom/` directory is gitignored. Both SPDX and CycloneDX JSON are produced so you can feed Dependency-Track, GUAC, or any SCA tool that prefers either format.

If `SBOM=ON` is set but `syft` is not installed, the build logs a clear skip line and continues — it never breaks an existing publish flow.

---

## Hardening (read-only root, capabilities, non-root)

The image **runs as root** and uses a writable root filesystem by default. That is a deliberate trade-off for the workloads it serves; this section explains why and what you can still tighten on top.

### Why root, FUSE, NFS

- **Cron-as-root**: `crond` (busybox) writes to `/var/spool/cron/crontabs/root` and reads `/etc/crontabs/root`; restoring snapshots commonly needs root to recreate UIDs/GIDs and ACLs faithfully.
- **FUSE (`restic mount`)**: requires `CAP_SYS_ADMIN` and access to `/dev/fuse`; that capability is meaningless without an effective UID 0 inside the container.
- **NFS** (`NFS_TARGET`): the `mount` syscall in busybox needs `CAP_SYS_ADMIN`; the same constraint as FUSE.
- **Hooks**: user-supplied `/hooks/*.sh` scripts may need to read source files under tight ACLs; running as a non-root UID would break some perfectly reasonable backup setups.
- **Restic backends**: most cloud backends (`s3:`, `swift:`, `rclone:`) work fine as non-root, but `sftp:` plus `~/.ssh` mounts and local repository mounts under `/mnt/restic` typically end up needing root.

A separate "slim" image (no FUSE, no NFS, no cron, runs as UID 1000) is on the backlog for users who can accept those trade-offs. The default image keeps the boring, batteries-included behaviour.

### What you CAN tighten at the orchestration layer

Cap the blast radius **outside** the image — Docker / Compose / Kubernetes are the right place for these knobs:

- **Drop most kernel capabilities**, keep only what FUSE/NFS need:

  ```yaml
  cap_drop:
    - ALL
  cap_add:
    - DAC_READ_SEARCH   # source paths under tight ACLs
    - SYS_ADMIN         # FUSE / NFS mount / restic mount
  ```

- **Read-only root filesystem** with tmpfs for the few writable paths the workers actually need:

  ```yaml
  read_only: true
  tmpfs:
    - /tmp
    - /run
    - /var/run
    - /var/spool/cron        # crond writes the rendered crontab here
    - /var/log               # last-*.json + cron.log; switch to a named volume to persist
    - /.cache/restic         # restic cache; mount a volume to keep it across restarts
  ```

  Trade-offs to know:
  - `/var/log` as tmpfs means `last-*.json`, `cron.log` archives and `*.prom` files are lost on container restart. Switch that one to a named volume if you scrape it externally (Prometheus textfile collector, log forwarder).
  - `/.cache/restic` as tmpfs means every restart re-warms the restic cache (slower first backup after restart). A named volume is recommended for any non-trivial repository.

- **No new privileges**:

  ```yaml
  security_opt:
    - no-new-privileges:true
  ```

- **Per-volume `:ro`** on backup sources so a hostile hook script cannot mutate them:

  ```yaml
  volumes:
    - /srv/documents:/data:ro
    - ~/.ssh:/root/.ssh:ro     # only when using sftp:
  ```

- **Seccomp / AppArmor**: the upstream Docker default profiles already block the riskiest syscalls; an explicit profile path can tighten further but is environment-specific.

On Kubernetes the equivalent knobs are `securityContext.capabilities`, `securityContext.readOnlyRootFilesystem: true` plus `emptyDir` mounts for `/tmp`, `/var/spool/cron`, etc., and a `PodSecurity` policy at namespace level. The [Kubernetes example](examples/kubernetes/restic-backup-helper.yaml) already drops all capabilities and re-adds only `DAC_READ_SEARCH` + `SYS_ADMIN`.

> **TL;DR**: don't try to make the image non-root or read-only **inside** the container — tighten it at the orchestration layer with `cap_drop`, `read_only` + tmpfs, `:ro` source mounts and `no-new-privileges`. You keep the well-tested cron/FUSE behaviour and still meet most CIS-style benchmarks.

---

## Multiple backup jobs

When one host needs to back up several distinct trees on different schedules (or with different tags / forget policies), the recommended pattern is **multiple containers** sharing one Restic repository, password and cache volume — not a single container with multi-job env. Reasons:

- One container = one cron daemon = one set of `BACKUP_CRON` / `RESTIC_TAG` / `BACKUP_ROOT_DIR`. Adding "BACKUP_CRON_documents" / "BACKUP_CRON_media" inside one container would either require a private DSL or invite cron-collisions and ambiguous notifications.
- Multiple containers compose naturally with healthchecks, restart policies, log aggregation and `docker compose ps`.
- Lock contention is repository-level (Restic's own lock); per-container `flock` is independent and never blocks across jobs.
- Notifications (`MAILX_RCPT`, `WEBHOOK_URL`, `last-<job>.json`, mail subjects) are per-container, so each job tells you which dataset it was about without extra plumbing.

A complete reference for the pattern lives at [`examples/compose/multi-job.yml`](examples/compose/multi-job.yml). It uses a YAML anchor (`x-restic-base: &restic_base`) to share repository env, the password secret and the cache volume, then declares one service per dataset (`restic-documents`, `restic-media`, `restic-vmstore`) with its own `BACKUP_CRON`, `BACKUP_ROOT_DIR`, `RESTIC_TAG`, `RESTIC_FORGET_ARGS` and `hostname:` (so mail subjects and `last-*.json` clearly identify the job).

Trade-offs:

- **One container per job** ⇒ lower copy-paste with anchors, clear isolation, easy to disable one job by `docker compose stop restic-media`. Recommended for ≥ 2 jobs.
- **One container** ⇒ keep the existing single-container Compose example, schedule a single `BACKUP_CRON`, and use `RESTIC_JOB_ARGS="--exclude-file /config/excludes.txt"` plus `BACKUP_ROOT_DIR=/data` covering both datasets via separate bind mounts under `/data/`. Simpler when both datasets follow the same retention and timing.
- **`PRUNE_CRON` and `CHECK_CRON`**: run them on **exactly one** of the containers (the "owner" container), not all of them. Otherwise N containers would each schedule a heavy `restic prune` against the same repository on the same cadence and trip Restic's repository lock.

---

## Operator diagnostics

`/bin/doctor` is a read-only support command for "what is wrong with this container?" moments. It does not run `restic init`, `restic unlock`, backups, restores, replicate jobs, hooks, mail or webhooks. It only inspects the current environment and mounted files, then exits non-zero when it finds hard failures that would also break normal operation.

What it reports:

- Release, hostname, current time, `TZ`, `restic version`, `rclone version` and shell version.
- Masked effective environment values, including legacy `SYNC_*` values when they still override `REPLICATE_*`.
- Required secret/config readability (`RESTIC_PASSWORD_FILE`, `RCLONE_CONFIG` for `rclone:` repositories, `RESTIC_CACERT` when set).
- Backup path sanity: `BACKUP_ROOT_DIR`, plus `--files-from` and `--exclude-file` references found in `RESTIC_JOB_ARGS`.
- A non-mutating `restic cat config` repository probe. Exit 10 is reported as "repository missing/not initialized"; doctor never initializes it.
- Replicate job-file validation (`SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]`) with endpoints masked before printing.
- Known hooks under `/hooks` and whether they are executable.
- Recent `/var/log/last-{backup,check,prune,replicate,restore,snapshot-export,forget-preview}.json` summaries and the last 40 lines of `/var/log/cron.log`.

Examples:

```shell
docker exec -ti restic-backup-helper /bin/doctor
docker run --rm --env-file restic.env -v ./config:/config:ro -v ./restic.password:/run/secrets/restic_password:ro marc0janssen/restic-backup-helper:latest doctor
```

Because it prints configured paths and non-secret job arguments, treat its output as operationally sensitive. Repository URLs, webhook URLs, inline endpoint credentials, `RESTIC_PASSWORD`, `OS_PASSWORD` and `WEBHOOK_HEADER_AUTH` are masked/hidden.

---

## Snapshot export

`/bin/snapshot-export` is a wrapper around `restic restore` plus `tar`. It restores a selected snapshot into a temporary work directory, packages the restored tree as a `.tar.gz` archive, and removes the temporary tree again unless `--keep-workdir` is set. It is meant for offline transfer and support handoff, not scheduled backups.

By default it exports `latest` for the configured `RESTIC_TAG` and `HOSTNAME`, writes to `/restore/snapshot-export-latest-<timestamp>.tar.gz`, and refuses to overwrite an existing archive unless `--force` is passed.

Examples:

```shell
docker exec -ti restic-backup-helper /bin/snapshot-export --id latest
docker exec -ti restic-backup-helper /bin/snapshot-export --id 5a3f2c8b --include /data/documents --output /restore/documents-5a3f2c8b.tar.gz
docker exec -ti restic-backup-helper /bin/snapshot-export --id latest --include /host/home/admin --dry-run
docker run --rm --env-file restic.env -v ./config:/config:ro -v ./restic.password:/run/secrets/restic_password:ro -v ./restore:/restore marc0janssen/restic-backup-helper:latest snapshot-export --id latest --include /data/documents
```

Flags:

| Flag | Meaning |
| --- | --- |
| `--id HEX\|latest` | Snapshot ID to export; defaults to `latest`. |
| `--tag TAG`, `--host HOST` | Snapshot filters; default to `RESTIC_TAG` and container `HOSTNAME`. |
| `--include PATH`, `--exclude PATH` | Scope the restore before packaging; repeatable. Include filters that restore 0 files/dirs exit `3`. |
| `--output FILE` | Archive path; default is under `/restore`. |
| `--work-dir DIR` | Use a specific temporary work directory; must be empty unless `--force` is set. |
| `--keep-workdir` | Keep the restored temporary tree for inspection after packaging. |
| `--force` | Allow overwriting an existing archive and reusing a non-empty work directory. |
| `--dry-run` | Run `restic restore --dry-run` only; no archive is created. |
| `--verify` | Pass Restic's `--verify` during restore before packaging. |
| `--verbose`, `-v` | Stream Restic restore output live while still logging to `/var/log/snapshot-export-last.log`. |

The helper writes `/var/log/last-snapshot-export.json`, `/var/log/snapshot-export-last.log`, optional hooks `/hooks/pre-snapshot-export.sh` and `/hooks/post-snapshot-export.sh "$rc"`, webhooks/mail through the existing notification helpers, and `restic_snapshot_export.prom` when `METRICS_DIR` is set.

---

## Forget preview

`/bin/forget-preview` previews your retention policy safely by running
`restic forget --dry-run`. It uses `RESTIC_FORGET_ARGS` by default and
adds `--host "$HOSTNAME"` plus `--tag "$RESTIC_TAG"` unless you
explicitly pass `--repo-wide`.

```shell
# Preview the configured policy for this host + tag.
docker exec -ti restic-backup-helper /bin/forget-preview

# Try a different policy without changing the container env.
docker exec -ti restic-backup-helper /bin/forget-preview \
  --policy "--keep-daily 14 --keep-weekly 8 --keep-monthly 12"

# Explicit repository-wide preview.
docker exec -ti restic-backup-helper /bin/forget-preview --repo-wide
```

Flags:

| Flag | Purpose |
| --- | --- |
| `--repo-wide` | Do not add `--host` / `--tag`; required for repository-wide previews. |
| `--host HOST` | Override the host filter (default: container `HOSTNAME`). |
| `--tag TAG` | Override the tag filter (default: `RESTIC_TAG`). |
| `--policy ARGS` | Use these retention args instead of `RESTIC_FORGET_ARGS`; quote as one argument. |
| `--extra ARGS` | Append extra `restic forget` args after policy + filters. |

The helper writes `/var/log/forget-preview-last.log`,
`/var/log/last-forget-preview.json`, optional hooks
`/hooks/pre-forget-preview.sh` and
`/hooks/post-forget-preview.sh "$rc"`, webhooks/mail through the existing
notification helpers, and `restic_forget_preview.prom` when `METRICS_DIR`
is set.

---

## Manual operations

Replace container name as needed.

```shell
docker exec -ti restic-backup-helper /bin/backup
docker exec -ti restic-backup-helper /bin/check
docker exec -ti restic-backup-helper /bin/prune
docker exec -ti restic-backup-helper /bin/replicate
docker exec -ti restic-backup-helper /bin/doctor
docker exec -ti restic-backup-helper /bin/snapshot-export --id latest
docker exec -ti restic-backup-helper /bin/forget-preview
docker exec -ti restic-backup-helper /bin/rotate_log
docker exec -ti restic-backup-helper restic snapshots
docker exec -ti restic-backup-helper /bin/restore --list           # operator-friendly restore wrapper (see next section)
docker exec -ti restic-backup-helper /bin/restore                  # interactive restore (TTY required)
```

Triggering any worker manually executes the **same code path** as the cron job: hooks (`/hooks/*.sh`), `RESTIC_CACERT` wiring, `/var/log/last-<job>.json`, mail and webhook notifications all fire. Useful for end-to-end verification after changing env vars.

Inspect the latest structured run summary directly from the container:

```shell
docker exec -ti restic-backup-helper cat /var/log/last-backup.json
```

**Configuration check** — validate env and critical paths before relying on cron (exits `0` or `1`; does not run `restic backup`):

```shell
docker run --rm \
  --env-file restic.env \
  -v /srv/documents:/data:ro \
  -v ./config:/config:ro \
  marc0janssen/restic-backup-helper:latest \
  config-check
```

**FUSE mount inside the container** (browse snapshots):

```shell
docker run --rm -it --cap-add SYS_ADMIN --device /dev/fuse \
  --entrypoint /bin/sh \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD \
  marc0janssen/restic-backup-helper:latest \
  -c "mkdir -p /mnt/browse && restic mount /mnt/browse"
```

---

## Restore (operator-friendly)

`/bin/restore` is a wrapper around `restic restore` that handles the nitty-gritty (snapshot selection, empty-target check, dry-run preview, ownership fix-up, mail/webhook/JSON/metrics) so a real restore stays a one-liner instead of a panic-driven cheat-sheet exercise. It works in two complementary modes:

1. **Interactive** — invoked from a TTY (`docker exec -ti …`) without `--yes`. Lists matching snapshots, prompts for index/target/dry-run, and confirms with a final "Proceed? [y/N/q]" before mutating anything. Flags suppress individual prompts whose answer is already known: `--id` skips the snapshot picker, `--target` skips the target prompt, `--dry-run` skips the dry-run prompt. Modifier flags (`--verbose`, `--force`, `--verify`, `--tag`, `--host`, `--since`, `--include`, `--exclude`, `--owner`) leave the interactive flow fully intact — they are pure behaviour/filter overrides.
2. **Non-interactive** — invoked without a TTY (cron, CI, `docker exec` without `-t`) **or** with `--yes` / `-y` from inside an interactive container shell. Skips every prompt; falls back to `latest` when `--id` is not provided, `/restore` when `--target` is not provided and no dry-run. Suitable for cron-jobs, CI smoke tests, runbooks and one-shot operator-driven restores.

It is **not** cron-driven by design: restores are always operator-initiated. All other plumbing matches the rest of the helper (hooks, `RESTIC_CACERT`, `MAILX_RCPT`, `WEBHOOK_URL`, `METRICS_DIR`, `RESTIC_AUTO_UNLOCK` is not used here — restore does not acquire locks).

### Quick start

```shell
docker exec -ti restic-backup-helper /bin/restore --list                          # show last 20 snapshots for this host+tag
docker exec -ti restic-backup-helper /bin/restore --list --all                    # show every matching snapshot
docker exec -ti restic-backup-helper /bin/restore                                 # interactive: pick & restore latest to /restore
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore # specific snapshot, non-interactive
docker exec -ti restic-backup-helper /bin/restore --dry-run                       # preview what `latest` would restore
docker exec -ti restic-backup-helper /bin/restore --since 2026-05-01 --target /restore --include /data/documents
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore --verbose # stream per-file output live
docker exec -ti restic-backup-helper /bin/restore --id 5a3f2c8b --target /restore --yes     # one-shot from inside the container shell (no prompts at all)
```

The container needs a writable `/restore` target. In the [reference `scripts/docker-compose.yml`](scripts/docker-compose.yml) that is the `restic-restore` named volume; bind-mount a host path instead if you want the restored data directly on disk.

### Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--id HEX` | *latest* | Restore a specific snapshot by short or long ID. |
| `--tag TAG` | `$RESTIC_TAG` | Filter snapshots by tag. Use `--tag ""` to disable the filter. |
| `--host HOST` | container `$HOSTNAME` | Filter snapshots by host. Use `--host ""` to disable. |
| `--since DATE` | *(off)* | Pick the oldest snapshot newer than `YYYY-MM-DD` or ISO 8601 timestamp. |
| `--target PATH` | `/restore` | Restore destination; must be writable. Refuses non-empty target unless `--force`. |
| `--include PATH` | *(none)* | Repeatable; only restore these paths inside the snapshot tree. If all includes match 0 files/dirs, the wrapper exits `3` and marks `include_zero_match=true` so a wrong prefix such as `/home/...` vs `/host/home/...` is not silently green. |
| `--exclude PATH` | *(none)* | Repeatable; skip these paths during restore. |
| `--owner UID:GID` | *(off)* | `chown -R UID:GID TARGET` after a successful (non-dry-run) restore. |
| `--dry-run` | off | Pass restic's own `--dry-run`; nothing is written. Skips ownership change. |
| `--verify` | off | Pass restic's `--verify` so hashes are verified during restore (slower, catches silent corruption). |
| `--verbose`, `-v` | off | Stream restic's output to stdout while the restore is running. Two things happen: (a) `--verbose=2` is passed to restic so each file emits a `restored /path/...` line (`--verbose=1` produces almost no per-file output for `restore`); (b) restic is wrapped in `script(1)` (from `util-linux`) which allocates a pseudo-TTY for it, so its native in-place progress bar (`[time] X%, MiB/s, ETA …`) is rendered instead of suppressed by the tee pipe. Combined output is tee'd to `/var/log/restore-last.log`; that file therefore contains ANSI escape codes and `\r` overwrites — view with `cat` on a terminal or strip with `col -bp`. The structured `last-restore.json` summary is unaffected: `lib.sh::parse_restic_restore_stats` normalises `\r → \n` before grepping out the `Summary:` line. |
| `--yes`, `-y` | off | Run fully non-interactive: skip the snapshot picker, the target prompt, the dry-run prompt **and** the final `Proceed? [y/N/q]` confirmation. Falls back on the same defaults the cron/CI path uses (`latest` snapshot when `--id` is not given, `/restore` target when `--target` is not given, no dry-run). Lets an operator inside `docker exec -ti …` launch a one-shot restore without dropping the TTY via `< /dev/null`. Logged as `ASSUME_YES: ON` in `restore-last.log` so audit trails can distinguish "operator typed y" from "operator passed --yes". |
| `--force` | off | Allow restoring into a non-empty target, **or** into `BACKUP_ROOT_DIR` / `/data` (refused by default). |
| `--list` | off | List matching snapshots and exit (no restore, no mail/webhook). |
| `--all` | off | With `--list`, show all matching snapshots; without it, show the last 20. |
| `--help` | – | Print the usage banner and exit. |

### Interactive walkthrough

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

After the dry-run completes successfully, re-run `/bin/restore` without `--dry-run` to do the real one (or answer "n" to "Dry-run first?" up front). Type `q` (or `quit`) at **any** prompt to abort cleanly — the helper records `exit_code=130` + `cancelled=true` in `last-restore.json` (and posts the same payload via the webhook / mail stack) so monitoring can tell "operator backed out" apart from "restore actually failed".

### Notifications

Mail and webhook notifications fire for every restore by default — they share the same `MAILX_RCPT`, `WEBHOOK_URL`, `WEBHOOK_HEADER_AUTH`, `WEBHOOK_ON_ERROR` and `MAILX_ON_ERROR` plumbing as the cron-driven workers. Mail subject examples:

```text
Subject: [OK] Restore larak · 1m12s · 4523 files (567.89 MiB) → /restore
Subject: [OK] Restore larak · 4s · DRY-RUN · 4523 files (567.89 MiB) → /restore
Subject: [FAIL 1] Restore larak · 0s · /restore
```

Per-run summary at `/var/log/last-restore.json` includes `snapshot`, `target`, `dry_run`, `files_restored`, `bytes_restored` and `elapsed_human` where restic produced them. When the operator types `q` / `quit` at any interactive prompt — or answers anything other than `y` / `yes` to the final "Proceed?" prompt — `exit_code` is `130` and `cancelled` is `true` so external monitoring can distinguish "operator changed their mind" from "restore actually failed".

When one or more `--include` filters are configured and restic reports `0` restored files/dirs, the helper treats that as a failed restore (`exit_code=3`, `include_zero_match=true`). This catches the common mistake where the snapshot contains `/host/home/admin/docker/...` but the operator typed `--include /home/admin/docker/...`.

### Hooks

```text
/hooks/pre-restore.sh                # informational; failure does not abort the restore
/hooks/post-restore.sh "$exit_code"  # always called with the restic exit code as $1
```

Useful for unmounting source filesystems before the restore, sending Slack-different notifications, or chowning the restore target in a way `--owner` does not cover.

### Safety rails

- Refuses to restore into a non-empty target unless `--force` or `--dry-run` is passed.
- Refuses to restore directly into `BACKUP_ROOT_DIR` or `/data` (the conventional backup source) unless `--force` is passed — protects against the classic "I will just restore over my source" foot-gun.
- `--owner` is skipped on `--dry-run` so nothing on disk is touched.
- A `chown -R` failure after a successful restore is logged but does not turn the run's `exit_code` non-zero (the data is already on disk; ownership is a follow-up concern).

---

## Security

- Never bake repository passwords, API keys, or mail credentials into images.
- Prefer **`RESTIC_PASSWORD_FILE`** (Restic standard) over `RESTIC_PASSWORD` when you can mount a secret as a file. Docker Compose example:

```yaml
secrets:
  restic_password:
    file: ./restic.password
services:
  restic:
    secrets:
      - restic_password
    environment:
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
```

On Kubernetes, mount a `Secret` as a volume (or use `subPath`) and set `RESTIC_PASSWORD_FILE` to that path so the literal password does not appear in Pod spec env values.

- Prefer secrets, env files ignored by git, or orchestrator secret mounts for other sensitive values.
- Restrict mounts (`:ro` where possible) for backup sources and SSH keys.
- Review logs before forwarding them by mail (paths or URLs might be sensitive).
- **`MAILX_RCPT`** is passed as a single quoted argument to `mail` (no `sh -c` wrapper). Treat it as trusted configuration; odd characters in addresses are discouraged.
- The container **runs as root** (upstream-style for cron, FUSE, NFS). Prefer least privilege at the **Docker/Kubernetes** layer (`cap_drop`, read-only roots where possible, seccomp/AppArmor) rather than expecting a non-root `USER` inside this image.

---

## Troubleshooting

| Symptom | Things to check |
| --- | --- |
| Backup exits immediately / “Missing RESTIC_TAG” | Export **`RESTIC_TAG`**. |
| Empty or wrong backup content | Set **`BACKUP_ROOT_DIR`** and/or **`RESTIC_JOB_ARGS`** paths intentionally; empty both yields a degenerate `restic backup` invocation. |
| Backup logs “success” but `restic snapshots` shows zero / tiny snapshots | Walk this list: 1) confirm the host volume backing **`BACKUP_ROOT_DIR`** is actually mounted into the container (`docker exec … ls -la "$BACKUP_ROOT_DIR"`); 2) when you use `--files-from` or `--exclude-file` in **`RESTIC_JOB_ARGS`**, verify those files exist *inside the container* and contain real, in-container paths; 3) `docker exec … restic snapshots latest --json` to see file/byte counts; 4) inspect `/var/log/last-backup.json` for `files_new` / `bytes_added`. A misspelled bind mount, an `--files-from` referring to host paths the container cannot see, or an over-broad `--exclude-file` all produce a successful but empty backup. |
| Container exits at startup with “Repository probe failed for ‘…’ with exit code N” | Restic could reach restic but the repository is unhealthy (`12` = wrong password, other = network/DNS/TLS/auth). Read the restic stderr in the container log; the entrypoint deliberately refuses to run `restic init` to avoid masking a transient failure. As a last resort, set `RESTIC_CHECK_REPOSITORY_STATUS=OFF` to bypass the probe (you lose the auto-init safety net). |
| TLS / certificate errors against the repository or a corporate proxy | Mount the PEM bundle into the container and set **`RESTIC_CACERT`** to its path. The flag is appended to every restic invocation automatically; `config-check` will fail when the path is unreadable. |
| Webhook never reaches the endpoint and the cron log is silent | Confirm **`WEBHOOK_URL`** is set inside the container (`docker exec … env | grep WEBHOOK`); container logs only show `scheme://host/...`. Test connectivity from inside the container: `docker exec -ti … curl -fsS -X POST -H 'Content-Type: application/json' -d '{"test":true}' "$WEBHOOK_URL"`. |
| Hook never returns / blocks the next cron run | Set **`HOOK_TIMEOUT`** to a positive integer (seconds). The hook is wrapped in `timeout`; exit `124` is logged as a timeout but does not fail the underlying restic job. |
| `restic` reports a stale lock (`unable to create lock in backend: repository is already locked`) after a previous failed run | List with `docker exec … restic list locks` and confirm the lock host/PID is yours, then `docker exec … restic unlock`. Since 1.12.0 the helper no longer auto-unlocks after a failure (safer for multi-host repos); set **`RESTIC_AUTO_UNLOCK=ON`** to restore the previous behaviour if you only ever back up from one host. |
| Cron tick runs but `/var/log/cron.log` shows `⏭ <job> skipped: previous run still active` | The previous backup/check/sync/rotate is still holding its `flock`. Confirm the long-running PID inside the container (`docker exec … ps -ef`) and either wait, kill it, or widen the cron interval. |
| Cron “wrong timezone” | Set **`TZ`** and restart the container. |
| Rclone auth breaks | Ensure `rclone.conf` is writable if the backend refreshes tokens. |
| Permission denied on source | Match UID/GID or ACLs on mounted volumes; avoid overly broad `:privileged` unless required. |
| Pull / push fails via corporate proxy to a **private registry** or LAN host | Add the registry hostname or LAN ranges to **`NO_PROXY`** / **`no_proxy`** (e.g. `192.168.0.0/16,.internal,myregistry.local`) so Docker talks directly; verify TLS to internal registries. |

---

## Contributing

Lint matrix, pre-commit setup and worker-script invariants are documented in [`CONTRIBUTING.md`](CONTRIBUTING.md). The same checks run in CI; install the hooks once with `pre-commit install` to catch shellcheck / shfmt / hadolint / yamllint / actionlint findings before you push.

---

## Documentation site (Material for MkDocs)

A full Material for MkDocs site is published from [`docs/`](docs/) to [marc0janssen.github.io/restic-backup-helper](https://marc0janssen.github.io/restic-backup-helper/) by [`.github/workflows/docs.yml`](.github/workflows/docs.yml). Build with `mkdocs build --strict` (run in CI) emits one HTML file per page under `site/` (`use_directory_urls: false`, so `site/workers/backup.html` is also directly openable over `file://`).

To preview the docs locally, create a Python virtual environment, install the docs requirements and run `mkdocs serve`. The activation command depends on your shell:

**Bash / Zsh**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r docs/requirements.txt
mkdocs serve      # live preview at http://127.0.0.1:8000
# or
mkdocs build --strict     # one-shot, writes ./site/
```

**Fish**

```fish
python3 -m venv .venv
source .venv/bin/activate.fish
pip install -r docs/requirements.txt
mkdocs serve
# or
mkdocs build --strict
```

Deactivate with `deactivate` in either shell. The `.venv/` directory and the generated `site/` directory are both gitignored.

> Pages-source note: for the workflow’s `actions/deploy-pages@v4` step to actually publish, set **Settings → Pages → Build and deployment → Source** to **GitHub Actions** once on the repo. The `deploy` job runs on pushes to `main` and `develop`; `main` is the long-term production branch, `develop` is a preview channel until the next release merge.

---

## Further reading

- **Documentation site (Material for MkDocs):** <https://marc0janssen.github.io/restic-backup-helper/>
- [CHANGELOG.md](CHANGELOG.md)
- [BACKLOG.md](BACKLOG.md)
- [GitHub Releases](https://github.com/marc0janssen/restic-backup-helper/releases)
- Sample files under [`config/`](config/)
- Kubernetes example: [`examples/kubernetes/restic-backup-helper.yaml`](examples/kubernetes/restic-backup-helper.yaml)
- Local dev workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md)

---

This project evolved from [**Restic Backup Docker** (lobaro/restic-backup-docker)](https://github.com/lobaro/restic-backup-docker); thank you to the original authors.
