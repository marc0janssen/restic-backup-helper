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
14. [Manual operations](#manual-operations)
15. [Security](#security)
16. [Troubleshooting](#troubleshooting)
17. [Further reading](#further-reading)

---

## What you get

- **Scheduled backup** via `/bin/backup` (cron expression `BACKUP_CRON`), with optional **snapshot policy** (`RESTIC_FORGET_ARGS` runs `restic forget` after a successful backup).
- **Scheduled integrity check** via `/bin/check` when `CHECK_CRON` is non-empty.
- **Scheduled Rclone bisync** via `/bin/bisync` when `SYNC_CRON` and a valid `SYNC_JOB_FILE` are configured.
- **Repository probe on startup**: when `RESTIC_CHECK_REPOSITORY_STATUS=ON`, the entrypoint runs `restic snapshots`; if the repo is missing it attempts `restic init` (requires a valid `RESTIC_PASSWORD` / `RESTIC_PASSWORD_FILE`).
- **Configuration check**: run `docker run … config-check` with the same env as production to validate credentials and backup paths without starting cron (CI-friendly).
- **Concurrency**: each job uses `flock` on a dedicated lock file so overlapping runs do not corrupt state.
- **Based on** [`restic/restic`](https://hub.docker.com/r/restic/restic) Alpine image; Restic version follows the `FROM restic/restic:<tag>` line in this repo’s `Dockerfile`.

---

## Image tags and release

release: 1.11.5-0.18.1

| Train | When to use | Example pull |
| --- | --- | --- |
| **Stable** | Production | `docker pull marc0janssen/restic-backup-helper:latest` or pinned `marc0janssen/restic-backup-helper:1.11.5-0.18.1` |
| **Testing** | Pre-release / CI | `docker pull marc0janssen/restic-backup-helper:develop` or `marc0janssen/restic-backup-helper:1.11.5-0.18.1-dev` |

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
2. **Backup line** (always present): `BACKUP_CRON … flock … /bin/backup >> /var/log/cron.log`.
3. **Check line** (optional): appended only if `CHECK_CRON` is non-empty.
4. **Sync line** (optional): appended only if `SYNC_CRON` is non-empty.
5. **Rotate line** (always present): `ROTATE_LOG_CRON … /bin/rotate_log`.
6. Default **CMD** tails `/var/log/cron.log` so the container stays foreground-friendly for Compose and logs aggregate cron output.

Worker scripts live at `/bin/backup`, `/bin/check`, `/bin/bisync`, `/bin/rotate_log`.

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
| `RESTIC_CACERT` | *(empty)* | Declared in the image for custom CA workflows; pass TLS trust material via Restic flags in **`RESTIC_JOB_ARGS`** / **`RESTIC_CHECK_ARGS`** (for example `--cacert /config/ca.pem`) when needed. |
| `RESTIC_CHECK_REPOSITORY_STATUS` | `ON` | On startup, probe repo (`restic snapshots`); init if missing. Set to anything else to skip probe/init. |

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

### NFS

| Variable | Default | Description |
| --- | --- | --- |
| `NFS_TARGET` | *(empty)* | If set, entrypoint runs `mount -o nolock -v "$NFS_TARGET" /mnt/restic`. Intended workflow keeps `RESTIC_REPOSITORY` at default `/mnt/restic`. |

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

### Log rotation (`/var/log/cron.log`)

| Variable | Default | Description |
| --- | --- | --- |
| `ROTATE_LOG_CRON` | `0 0 * * 6` | Cron schedule for `/bin/rotate_log`. |
| `CRON_LOG_MAX_SIZE` | `1048576` | Rotate when `cron.log` exceeds this size (bytes). |
| `MAX_CRON_LOG_ARCHIVES` | `5` | Keep this many compressed archives `cron_log_<timestamp>.tar.gz`. |

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

Crontab entries are written literally from `BACKUP_CRON`, `CHECK_CRON`, `SYNC_CRON`, and `ROTATE_LOG_CRON`. Ensure **`TZ`** matches how you expect schedules to fire. For UTC-only mental models, set `TZ=UTC`.

---

## Hooks

Mount scripts into **`/hooks`**:

| Hook | When |
| --- | --- |
| `/hooks/pre-backup.sh` | Before backup |
| `/hooks/post-backup.sh` | After backup; receives **backup exit code** as `$1` |
| `/hooks/pre-check.sh` | Before check |
| `/hooks/post-check.sh` | After check; receives **check exit code** as `$1` |
| `/hooks/pre-sync.sh` | Before sync batch |
| `/hooks/post-sync.sh` | After sync batch; receives **aggregate exit code** as `$1` |

Hooks must be executable inside the container (`chmod +x`).

---

## Examples: Docker Compose

Use a `.env` file or Docker secrets for `RESTIC_PASSWORD`; avoid committing secrets.

```yaml
services:
  restic:
    image: marc0janssen/restic-backup-helper:latest
    container_name: restic-backup-helper
    hostname: backup-node
    restart: unless-stopped
    cap_add:
      - DAC_READ_SEARCH
      - SYS_ADMIN
    devices:
      - /dev/fuse
    env_file:
      - restic.env
    environment:
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}
      RESTIC_TAG: ${RESTIC_TAG:-daily}
      BACKUP_CRON: ${BACKUP_CRON:-0 2 * * *}
      BACKUP_ROOT_DIR: /data
      CHECK_CRON: ${CHECK_CRON:-37 3 * * 0}
      TZ: ${TZ:-Europe/Amsterdam}
    volumes:
      - ./config:/config
      - ./hooks:/hooks
      - backup-logs:/var/log
      - /srv/documents:/data:ro
    command: ["tail", "-fn0", "/var/log/cron.log"]

volumes:
  backup-logs:
```

**Health checks:** choose how hard you want Compose to probe the repository.

- **Weak** — only verifies the Restic binary (no repository access):

```yaml
healthcheck:
  test: ["CMD", "restic", "version"]
  interval: 5m
  timeout: 10s
  retries: 3
```

- **Strong** — fails if credentials or repository reachability break (uses `RESTIC_*` env inside the container; compare [`scripts/docker-compose.yml`](scripts/docker-compose.yml)):

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

## Manual operations

Replace container name as needed.

```shell
docker exec -ti restic-backup-helper /bin/backup
docker exec -ti restic-backup-helper /bin/check
docker exec -ti restic-backup-helper restic snapshots
docker exec -ti restic-backup-helper restic restore latest --target /restore
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
