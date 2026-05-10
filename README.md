# Restic Backup Helper

[![Quality Checks](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml)
[![Smoke Test](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml)
[![Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml)

Docker image for scheduled [Restic](https://restic.net) backups, optional scheduled `restic check`, optional [Rclone](https://rclone.org) bidirectional sync (`bisync`), cron-driven automation, structured logs under `/var/log`, and optional mail notifications via `mailx` and [msmtp](https://marlam.de/msmtp/).

**Docker Hub:** [marc0janssen/restic-backup-helper](https://hub.docker.com/r/marc0janssen/restic-backup-helper) · **Source:** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper)

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
11. [Optional Rclone sync jobs](#optional-rclone-sync-jobs)
12. [Mail notifications](#mail-notifications)
13. [Log rotation](#log-rotation)
14. [Webhook notifications](#webhook-notifications)
15. [Per-run JSON summaries](#per-run-json-summaries)
16. [Manual operations](#manual-operations)
17. [Security](#security)
18. [Troubleshooting](#troubleshooting)
19. [Further reading](#further-reading)

---

## What you get

- **Scheduled backup** via `/bin/backup` (cron expression `BACKUP_CRON`), with optional **snapshot policy** (`RESTIC_FORGET_ARGS` runs `restic forget` after a successful backup).
- **Scheduled integrity check** via `/bin/check` when `CHECK_CRON` is non-empty.
- **Scheduled standalone prune** via `/bin/prune` when `PRUNE_CRON` is non-empty (decouples the heavy `restic prune` from per-backup `restic forget`).
- **Scheduled Rclone bisync** via `/bin/bisync` when `SYNC_CRON` and a valid `SYNC_JOB_FILE` are configured.
- **Repository probe on startup**: when `RESTIC_CHECK_REPOSITORY_STATUS=ON`, the entrypoint probes with `restic cat config` and only auto-runs `restic init` when the probe exits **10** (repository does not exist). Other non-zero exits (wrong password, network, DNS, TLS, auth) log restic stderr and abort startup so a transient failure cannot accidentally re-init a healthy remote.
- **Configuration check**: run `docker run … config-check` with the same env as production to validate credentials, backup paths, `RCLONE_CONFIG` and `RESTIC_CACERT` readability without starting cron (CI-friendly).
- **Concurrency**: each job is wrapped in **`/bin/locked_run`** which acquires a dedicated `flock` and, on contention, logs `⏭ <job> skipped: previous run still active` to `/var/log/cron.log` instead of failing silently.
- **Observability**: each run writes `/var/log/last-{backup,check,sync}.json` and, when `WEBHOOK_URL` is set, POSTs the same JSON document to your monitoring endpoint (healthchecks.io, Slack, Discord, Gotify, ntfy, …).
- **Hooks**: optional `/hooks/{pre,post}-{backup,check,sync}.sh` scripts run before/after each job, with consistent start/exit-code/duration logging and an optional `HOOK_TIMEOUT`.
- **Based on** [`restic/restic`](https://hub.docker.com/r/restic/restic) Alpine image; Restic version follows the `FROM restic/restic:<tag>` line in this repo’s `Dockerfile`.

---

## Image tags and release

release: 1.13.1-0.18.1

| Train | When to use | Example pull |
| --- | --- | --- |
| **Stable** | Production | `docker pull marc0janssen/restic-backup-helper:latest` or pinned `marc0janssen/restic-backup-helper:1.13.1-0.18.1` |
| **Testing** | Pre-release / CI | `docker pull marc0janssen/restic-backup-helper:develop` or `marc0janssen/restic-backup-helper:1.13.1-0.18.1-dev` |

> **Upgrading from 1.11.x?** Automatic `restic unlock` after backup / check failures is now **opt-in** via `RESTIC_AUTO_UNLOCK=ON` (since 1.12.0). The new default leaves the lock alone (safer for repositories shared across multiple hosts). See the env table below and the [Troubleshooting](#troubleshooting) section for the migration hint.

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
4. **Sync line** (optional): appended only if `SYNC_CRON` is non-empty.
5. **Prune line** (optional): appended only if `PRUNE_CRON` is non-empty.
6. **Rotate line** (always present): `ROTATE_LOG_CRON … /bin/locked_run rotate_log … /bin/rotate_log`.
6. Default **CMD** tails `/var/log/cron.log` so the container stays foreground-friendly for Compose and logs aggregate cron output.

Worker scripts live at `/bin/backup`, `/bin/check`, `/bin/prune`, `/bin/bisync`, `/bin/rotate_log`. The cron wrapper itself is `/bin/locked_run`.

---

## Volumes and filesystem layout

| Path | Purpose |
| --- | --- |
| `/data` | Declared `VOLUME`; typical backup source when `BACKUP_ROOT_DIR=/data`. |
| `/config` | Recommended mount for `rclone.conf`, exclude files, `msmtprc`, sync job file. |
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
| `RESTIC_TAG` | `automated` | **Required** tag passed to `restic backup` (`--tag=…`). |
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

### Rclone sync (bisync)

| Variable | Default | Description |
| --- | --- | --- |
| `RCLONE_CONFIG` | `/config/rclone.conf` | Path to Rclone configuration. |
| `SYNC_JOB_FILE` | `/config/sync_jobs.txt` | Job file: one `SOURCE;DESTINATION` pair per line (comments `#` allowed). |
| `SYNC_JOB_ARGS` | *(empty)* | Extra args passed to `rclone bisync` / recovery `copy` (shell-word split; `--resync` is stripped from routine runs). |
| `SYNC_CRON` | *(empty)* | If non-empty, schedules `/bin/bisync`. |
| `SYNC_VERBOSE` | `ON` | When `ON`, sync messages also echo to stdout (still always logged to file). |

### Mail

| Variable | Default | Description |
| --- | --- | --- |
| `MAILX_RCPT` | *(empty)* | If set, backup/check can mail logs (see [Mail notifications](#mail-notifications)). |
| `MAILX_ON_ERROR` | `OFF` | When `ON`, backup and check only send mail after a **failed** run. Sync mails only when at least one job error occurred (see scripts). |

### Webhook

| Variable | Default | Description |
| --- | --- | --- |
| `WEBHOOK_URL` | *(empty)* | When set, backup/check/sync POST the same JSON document as `/var/log/last-<job>.json` (see [Webhook notifications](#webhook-notifications)). |
| `WEBHOOK_HEADER_AUTH` | *(empty)* | Sent verbatim as `Authorization: <value>` (e.g. `Bearer …`, `Token …`). Not echoed in logs. |
| `WEBHOOK_TIMEOUT` | `10` | Curl `--max-time` in seconds. Non-positive values fall back to 10. |
| `WEBHOOK_ON_ERROR` | `OFF` | When `ON`, only fire on non-zero job exit codes (mirrors `MAILX_ON_ERROR`). |

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

Crontab entries are written literally from `BACKUP_CRON`, `CHECK_CRON`, `SYNC_CRON`, `PRUNE_CRON` and `ROTATE_LOG_CRON`. Each entry is wrapped in `/bin/locked_run` so overlapping ticks log `⏭ <job> skipped: previous run still active` to `/var/log/cron.log` instead of failing silently. Ensure **`TZ`** matches how you expect schedules to fire. For UTC-only mental models, set `TZ=UTC`.

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
| `/hooks/pre-sync.sh` | Before sync batch |
| `/hooks/post-sync.sh` | After sync batch; receives **aggregate exit code** as `$1` |

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

      # ─── Optional: Rclone bisync ───────────────────────────────────────────────
      RCLONE_CONFIG: /config/rclone.conf
      SYNC_JOB_FILE: /config/sync_jobs.txt
      SYNC_JOB_ARGS: "--exclude-from /config/exclude_sync.txt"
      SYNC_CRON: "*/30 * * * *"                # leave empty to disable sync
      SYNC_VERBOSE: "ON"

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

      # ─── Hooks (/hooks/{pre,post}-{backup,check,prune,sync}.sh) ────────────────
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
      - ./config:/config:ro                    # rclone.conf, exclude lists, sync_jobs.txt, ca-bundle.pem
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

A runnable, less commented variant lives at [`scripts/docker-compose.yml`](scripts/docker-compose.yml) for quick `docker compose up` testing.

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

## Optional Rclone sync jobs

`SYNC_JOB_FILE` lines:

```text
# SOURCE;DESTINATION   (local path or rclone remote path)
/data/inbox;jottacloud:inbox
```

Schedule with `SYNC_CRON`. On bisync failure the script attempts a **recovery** sequence (`copy` both directions, then `bisync --resync`). Mail is sent only when errors occurred (`MAILX_RCPT` set).

---

## Mail notifications

- **Backup / check:** If `MAILX_RCPT` is set, mail goes out per run unless `MAILX_ON_ERROR=ON`, in which case mail is sent only on failure.
- **Sync:** Mail is sent when `MAILX_RCPT` is set **and** at least one job recorded an error.

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
| `/var/log/last-sync.json` | `/bin/bisync` | `job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `sync_jobs_processed`, `sync_jobs_failed` |

Files are overwritten atomically each run (write to `*.tmp`, then `mv`). Mount `/var/log` on the host to scrape them, or feed them into Prometheus textfile collectors, Datadog log pipelines, or simple shell scripts. The backup-stats keys (`snapshot_id`, `files_*`, `bytes_*`) are best-effort: when a backup fails before restic prints them, they are simply omitted from the JSON.

---

## Manual operations

Replace container name as needed.

```shell
docker exec -ti restic-backup-helper /bin/backup
docker exec -ti restic-backup-helper /bin/check
docker exec -ti restic-backup-helper /bin/prune
docker exec -ti restic-backup-helper /bin/bisync
docker exec -ti restic-backup-helper /bin/rotate_log
docker exec -ti restic-backup-helper restic snapshots
docker exec -ti restic-backup-helper restic restore latest --target /restore
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
| Backup logs “success” but `restic snapshots` shows zero or empty snapshots | Verify the host volume that backs **`BACKUP_ROOT_DIR`** is actually mounted into the container, the path inside the container exists, and the user has read access. A misspelled bind mount or an unmounted source produces a successful but empty backup. |
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

## Further reading

- [CHANGELOG.md](CHANGELOG.md)
- [BACKLOG.md](BACKLOG.md)
- [GitHub Releases](https://github.com/marc0janssen/restic-backup-helper/releases)
- Sample files under [`config/`](config/)

---

This project evolved from [**Restic Backup Docker** (lobaro/restic-backup-docker)](https://github.com/lobaro/restic-backup-docker); thank you to the original authors.
