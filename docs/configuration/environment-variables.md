# Environment variables

The complete option surface of the image. Defaults below match the
`Dockerfile` unless noted; an empty default means *unset/blank unless you
provide it at runtime*.

!!! info "Legacy aliases"

    Variables marked **legacy** are still read at startup for backwards
    compatibility and emit a deprecation warning in `cron.log` when they
    override their replacement. They will be removed in **3.0.0**.

## Restic core

| Variable | Default | Description |
| --- | --- | --- |
| `RESTIC_REPOSITORY` | `/mnt/restic` | Restic repository location (local path, `s3:…`, `sftp:…`, `rclone:…`, `swift:…`, `b2:…`, etc.). The image bakes the `/mnt/restic` default into the env; `RESTIC_REPOSITORY_FILE` (below) is resolved before this value is used so a non-empty file always wins. |
| `RESTIC_REPOSITORY_FILE` | *(empty)* | File path inside the container containing the repository URL (Restic standard, mirrors `RESTIC_PASSWORD_FILE`). The entrypoint reads the first non-blank, non-comment line — leading/trailing whitespace and trailing CR are stripped — and promotes it into `RESTIC_REPOSITORY` before any banner, repository probe or worker runs. The original `RESTIC_REPOSITORY_FILE` env var is unset after a successful promotion so restic never fails with `Options --repo and --repository-file are mutually exclusive`. Use this to keep `rest:https://user:pass@host/`, `s3:…` access strings or any other credential-bearing URL out of `docker inspect`; point it at a Docker secret mount, e.g. `/run/secrets/restic_repository`. If the file is unreadable or contains no usable URL the entrypoint leaves both env vars in place and `config-check` / `/bin/doctor` surface the specific failure. |
| `RESTIC_PASSWORD` | *(empty)* | Repository password. Appears in `docker inspect`; prefer `RESTIC_PASSWORD_FILE`. |
| `RESTIC_PASSWORD_FILE` | *(empty)* | File path inside the container containing the password (Restic standard). Point at a Docker secret mount, e.g. `/run/secrets/restic_password`. |
| `RESTIC_TAG` | `automated` | **Required.** Tag passed to `restic backup` as `--tag=…`. Explicitly empty value is a hard failure (exit 2). Pick something meaningful, e.g. `daily`, `${HOSTNAME}-data`. |
| `RESTIC_CACHE_DIR` | `/.cache/restic` | Restic cache directory. Mount a volume to persist across restarts. |
| `RESTIC_CACERT` | *(empty)* | Path inside the container to a readable PEM bundle. Automatically passed as `--cacert "$RESTIC_CACERT"` to every restic invocation. Unreadable path logs a warning and omits the flag; `config-check` treats the same condition as a hard error. |
| `RESTIC_CHECK_REPOSITORY_STATUS` | `ON` | When `ON`, the entrypoint probes the repo with `restic cat config`; auto-`restic init` runs only on exit `10`. Other non-zero exits abort startup. Set to anything else to skip both the probe and the auto-init — pair that with [`/bin/init-repo`](../operations/init-repo.md) for an audited operator-driven bootstrap. |
| `RESTIC_AUTO_UNLOCK` | `OFF` | When `ON`, `/bin/backup` and `/bin/check` run `restic unlock` after a non-zero restic exit. Default leaves the lock alone — safer for repositories shared across multiple hosts. Use the audited [`/bin/unlock`](../operations/unlock.md) helper for explicit, logged manual unlocks instead. |

## Backup job

| Variable | Default | Description |
| --- | --- | --- |
| `BACKUP_CRON` | `0 */6 * * *` | Cron schedule for `/bin/backup`. |
| `BACKUP_ROOT_DIR` | *(empty)* | If set, appended as backup path(s). If empty and `RESTIC_JOB_ARGS` does not contain paths, `restic backup` runs with no explicit path. Run [`/bin/sources-report`](../operations/sources-report.md) to inspect what these paths look like on disk before the next backup. |
| `RESTIC_JOB_ARGS` | *(empty)* | Extra words passed to `restic backup` (whitespace-split; not full shell syntax). Examples: `--exclude-file /config/exclude_files.txt --one-file-system`, `--files-from /config/include_files.txt`. Keep values free of spaces; use file-based inputs such as `--files-from` / `--exclude-file` for complex path lists. [`/bin/sources-report`](../operations/sources-report.md) re-uses the same parsing rules to surface `--files-from` / `--exclude-file` readability and pattern counts. |
| `RESTIC_FORGET_ARGS` | *(empty)* | If set **and** backup exits `0`, runs `restic forget` with these words (whitespace-split; not full shell syntax). Example: `--retry-lock=5m --keep-daily 7 --keep-weekly 5 --keep-monthly 12`. Add `--prune` only if you do not run `PRUNE_CRON` separately. |

## Check job

| Variable | Default | Description |
| --- | --- | --- |
| `CHECK_CRON` | *(empty)* | If non-empty, schedules `/bin/check`. |
| `RESTIC_CHECK_ARGS` | *(empty)* | Extra arguments for `restic check` (whitespace-split; not full shell syntax), e.g. `--read-data-subset 5%`. |

## Prune job

| Variable | Default | Description |
| --- | --- | --- |
| `FORGET_CRON` | *(empty)* | If non-empty, schedules a standalone `/bin/forget` on its own `flock` (`/var/run/forget.lock`). When set, `/bin/backup` **skips** its inline post-backup forget so the repository's exclusive forget-lock is only ever taken in this dedicated maintenance window — the recommended pattern for repositories shared by multiple hosts (eliminates the exit-11 race entirely). `RESTIC_FORGET_ARGS` is reused verbatim. Typical value `30 1 * * *`. See [Forget worker](../workers/forget.md). |
| `PRUNE_CRON` | *(empty)* | If non-empty, schedules a standalone `/bin/prune` on its own `flock`. Run the heavy `restic prune` on its own cadence (typically weekly) while `RESTIC_FORGET_ARGS` keeps post-backup forget cheap. |
| `RESTIC_PRUNE_ARGS` | *(empty)* | Extra words passed to `restic prune` (whitespace-split; not full shell syntax), e.g. `--max-unused 10%`, `--max-repack-size 5G`. |
| `RESTIC_INIT_ARGS` | *(empty)* | Extra words passed to `restic init` by [`/bin/init-repo`](../operations/init-repo.md). Whitespace-split, analogous to `RESTIC_FORGET_ARGS` / `RESTIC_PRUNE_ARGS`. Examples: `--repository-version=2`, `--copy-chunker-params=/run/secrets/other_repo` (deduplication-friendly when cloning a sibling repository). Only consulted by `/bin/init-repo`; the cron-driven workers ignore it. |

## NFS

| Variable | Default | Description |
| --- | --- | --- |
| `NFS_TARGET` | *(empty)* | If set, entrypoint runs `mount -o nolock -v "$NFS_TARGET" /mnt/restic`. Container aborts with exit `1` if the mount fails. Intended workflow keeps `RESTIC_REPOSITORY` at default `/mnt/restic`. |

## Rclone replicate

| Variable | Default | Description |
| --- | --- | --- |
| `RCLONE_CONFIG` | `/config/rclone.conf` | Path to the Rclone configuration. |
| `REPLICATE_JOB_FILE` | `/config/replicate_jobs.txt` | Job file: `SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]` per line; `#` comments allowed. See [Replicate worker](../workers/replicate.md). |
| `REPLICATE_JOB_ARGS` | *(empty)* | Extra global args passed to every rclone job (whitespace-split; not full shell syntax; `--resync` stripped from routine runs). Keep values free of spaces or move complex settings into rclone config/files. |
| `REPLICATE_CRON` | *(empty)* | If non-empty, schedules `/bin/replicate`. |
| `REPLICATE_VERBOSE` | `ON` | When `ON`, replicate messages also echo to stdout (still always logged to file). |
| `REPLICATE_BISYNC_CHECK_ACCESS` | `OFF` | When `ON`, appends `--check-access` to the routine `bisync` runs and the recovery `bisync --resync`. Requires the `RCLONE_TEST` marker file on both endpoints. |
| `SYNC_CRON` :material-alert-octagon:{ title="Deprecated; removed in 3.0.0" } | *(empty)* | **Legacy** alias for `REPLICATE_CRON`. |
| `SYNC_JOB_FILE` :material-alert-octagon: | *(empty)* | **Legacy** alias for `REPLICATE_JOB_FILE`. |
| `SYNC_JOB_ARGS` :material-alert-octagon: | *(empty)* | **Legacy** alias for `REPLICATE_JOB_ARGS`. |
| `SYNC_VERBOSE` :material-alert-octagon: | *(empty)* | **Legacy** alias for `REPLICATE_VERBOSE`. |
| `SYNC_BISYNC_CHECK_ACCESS` :material-alert-octagon: | *(empty)* | **Legacy** alias for `REPLICATE_BISYNC_CHECK_ACCESS`. |

## Mail

| Variable | Default | Description |
| --- | --- | --- |
| `MAILX_RCPT` | *(empty)* | When set, workers can mail per-run logs. See [Mail notifications](mail.md). |
| `MAILX_ON_ERROR` | `OFF` | When `ON`, backup / check / prune / restore / snapshot-export / forget-preview only mail on **failure**. Replicate mails only when at least one job recorded an error. |

## Webhook

| Variable | Default | Description |
| --- | --- | --- |
| `WEBHOOK_URL` | *(empty)* | When set, workers POST the same JSON document as `last-<job>.json`. |
| `WEBHOOK_HEADER_AUTH` | *(empty)* | Sent verbatim as `Authorization: <value>` (e.g. `Bearer …`, `Token …`). Never echoed in logs. |
| `WEBHOOK_TIMEOUT` | `10` | Curl `--max-time` in seconds. Non-positive values fall back to `10`. |
| `WEBHOOK_ON_ERROR` | `OFF` | When `ON`, only fire on non-zero job exit codes (mirrors `MAILX_ON_ERROR`). |

## Prometheus textfile collector

| Variable | Default | Description |
| --- | --- | --- |
| `METRICS_DIR` | *(empty)* | When set to a writable directory inside the container, every worker writes a `restic_<job>.prom` document there. Mount that directory into the host and point a node-exporter `--collector.textfile.directory` at it. |

## Log rotation (`/var/log/cron.log`)

| Variable | Default | Description |
| --- | --- | --- |
| `ROTATE_LOG_CRON` | `0 0 * * 6` | Cron schedule for `/bin/rotate_log`. |
| `CRON_LOG_MAX_SIZE` | `1048576` | Rotate when `cron.log` exceeds this size (bytes). |
| `MAX_CRON_LOG_ARCHIVES` | `5` | Keep this many compressed `cron_log_<timestamp>.tar.gz` archives. |

## Hooks

| Variable | Default | Description |
| --- | --- | --- |
| `HOOK_TIMEOUT` | `0` | When `> 0`, wraps each `/hooks/*.sh` invocation in `timeout ${HOOK_TIMEOUT}s`. Exit `124` is logged prominently. `0` keeps the historical behaviour of no enforced timeout. |

## OpenStack Swift (`swift:` repository)

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

## AWS S3

Use the standard AWS environment variables as required by Restic's S3
backend: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_DEFAULT_REGION`, `AWS_SESSION_TOKEN`, etc. They are not declared in
the `Dockerfile` but are honoured by Restic at runtime.

## Locale / time

| Variable | Default | Description |
| --- | --- | --- |
| `TZ` | `Europe/Amsterdam` | Container timezone; cron typically respects `TZ` when set in the environment used by `crond`. See [Cron and time zones](../concepts/cron-and-time-zones.md). |

## Build metadata (read-only)

The image bakes its release string in at build time via `--build-arg
RESTIC_BACKUP_HELPER_RELEASE=…`. Read it from inside the container:

```shell
docker exec restic-backup-helper printenv RESTIC_BACKUP_HELPER_RELEASE
# → 2.12.0-0.18.1
```

`/bin/doctor` includes the release in its `Runtime` section and every
`last-<job>.json` summary carries it as the `release` field.
