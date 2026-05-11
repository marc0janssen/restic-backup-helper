# Changelog

## Restic Backup Helper

### 1.17.0-0.18.1 (2026-05-11)

#### Added

- **Operator-friendly restore wrapper** at `/bin/restore` (`app/restore.sh`). Wraps `restic restore` so the common case ("give me last night's data back") is a one-liner and the panic-driven cheat-sheet exercise is gone. Two complementary modes:
  - **Interactive** (`docker exec -ti … /bin/restore`): lists the 10 most recent snapshots matching `RESTIC_TAG` + `HOSTNAME` (or `--tag`/`--host` overrides), prompts for index/short-id (`latest` default), prompts for `--target` (default `/restore`), offers a dry-run first, and asks for a final "Proceed? [y/N]" before mutating anything.
  - **Non-interactive** (any restore flag passed): flag-driven, suitable for cron-jobs, CI smoke tests and runbooks.
  - Flags: `--id`, `--tag`, `--host`, `--since DATE`, `--target`, `--include` / `--exclude` (repeatable), `--owner UID:GID` (post-restore `chown -R`), `--dry-run`, `--verify`, `--force`, `--list` / `--all`, `--help`.
  - Refuses to restore into a non-empty target (unless `--force` or `--dry-run`), or directly into `BACKUP_ROOT_DIR` / `/data` (unless `--force`) — protects against the classic "I will just restore over my source" foot-gun.
  - Shares the existing plumbing: `RESTIC_CACERT_ARGS`, `/hooks/{pre,post}-restore.sh`, `/var/log/last-restore.json`, `MAILX_RCPT` / `WEBHOOK_URL` (on by default like the other workers), `METRICS_DIR` Prometheus textfile, masked repository in subject/body/JSON. Operator cancellation at the final prompt records `exit_code=130` + `cancelled=true` so monitoring can distinguish "changed mind" from "actually failed".
- **`lib.sh::parse_restic_restore_stats`** parses the `Summary: Restored N files/dirs (X) in Y` line from `restic restore` text output into `RESTORE_STATS_FILES_RESTORED` / `RESTORE_STATS_BYTES_RESTORED` / `RESTORE_STATS_ELAPSED_HUMAN` so `last-restore.json`, the webhook payload and the mail subject can carry the same numbers without depending on `jq`.
- **README "Restore (operator-friendly)" section** with flag table, interactive walkthrough, mail subject examples, hook reference, safety rails and the `last-restore.json` schema row in the per-run JSON summaries table.
- **SBOM parity for `./build-testing-local.sh`.** The private-registry build now calls the shared `emit_sbom` helper after `docker buildx build --push`, mirroring `./build.sh` / `./build-testing.sh`. Gated by `SBOM=ON` (and a working `syft` on `PATH`) so existing local builds are unaffected by default. To prevent collisions with the Docker Hub SBOM artifacts that land in `./sbom/`, the local script defaults `SBOM_DIR=./sbom/local`; an explicit `SBOM_DIR` override still wins.

#### Fixed

- **`/bin/restore` snapshot ordering.** Interactive mode and `--list` are now sorted **newest-first**: the second awk pass in `list_snapshots_table` collects matching snapshots into an array and emits them in reverse order with a renumbered 1-based index in its `END` block, so row 1 is the most recent snapshot and `print_snapshot_table 10` shows "the 10 most recent" instead of "the 10 oldest". The interactive prompt now caps its `index 1-N` range at the number of rows actually displayed and, when the filter matched more snapshots than fit on screen, prints a one-line hint pointing operators to `/bin/restore --list` (or the short-id form) for older snapshots.
- **`/bin/restore` snapshot parsing.** Added `n` and `rest` (and `content` in `jget_array`) to the function-local parameter lists of the inline awk parsers so they cannot clobber the body block's `n` counter that indexes the buffered `out[]` array. Without this, each `jget` call rewrote the global `n` to `index(blob, key)`, causing later records to overwrite earlier `out[n]` entries — visible as a mostly-empty interactive list (only the last one or two snapshots populated) once the new newest-first buffering was introduced.

#### Changed

- **Universal `q` / `quit` cancel in interactive `/bin/restore`.** Operators can now abort at any of the four interactive prompts (snapshot index, target path, "Dry-run first?", "Proceed?") by typing `q` or `quit`. The new `cancel_interactive_restore` helper records `exit_code=130` + `cancelled=true` in `/var/log/last-restore.json` regardless of how far into the flow the cancel happens, falling back to "now" when the start epoch has not been set yet. Prompt labels updated accordingly (`[…, q=quit]`, `[Y/n/q]`, `[y/N/q]`) and the per-run log file is now cleared before the first prompt so a cancel does not append to stale content.

### 1.16.0-0.18.1 (2026-05-10)

#### Added

- **SBOM artifacts on release builds.** Two complementary surfaces:
  - `scripts/build-common.sh::emit_sbom` runs after the `docker buildx --push` step in `./build.sh` / `./build-testing.sh` when `SBOM=ON` and [`syft`](https://github.com/anchore/syft) is on `PATH`; writes SPDX + CycloneDX JSON to `./sbom/restic-backup-helper-<release>.{spdx,cyclonedx}.json`. Skips with a clear log line when `SBOM` is unset or when `syft` is missing, so existing local builds are unaffected.
  - `.github/workflows/release-orchestration.yml` now runs `anchore/sbom-action@v0` against the source tree on every `v*` tag push and uploads `sbom-source.{spdx,cyclonedx}.json` alongside the existing Trivy diagnostics.
  - New `sbom/` is gitignored. README has a new **"Supply chain (SBOM, Trivy)"** section explaining where each artifact comes from and which tool to feed it to (Dependency-Track, GUAC, etc.).
- **Hardening docs (read-only root, capabilities, non-root).** New README section explains why the image runs as root (cron, FUSE, NFS, hooks), and shows a Compose snippet that wraps it in `read_only: true` + tmpfs for `/tmp`, `/run`, `/var/run`, `/var/spool/cron`, `/var/log`, `/.cache/restic` plus `cap_drop: [ALL]` + `cap_add: [DAC_READ_SEARCH, SYS_ADMIN]` and `no-new-privileges:true` so operators can tighten the blast radius at the orchestration layer without forking the image.
- **Compose profiles in [`scripts/docker-compose.yml`](scripts/docker-compose.yml).** Two opt-in [profiles](https://docs.docker.com/compose/profiles/):
  - `metrics` adds a `prom/node-exporter` sidecar (bound to `127.0.0.1:9100`) that scrapes the `backup-logs` volume's `textfile_collector/` subdirectory using `--collector.disable-defaults --collector.textfile`, exposing the `restic_<job>_last_*` gauges over HTTP without a host-level node-exporter.
  - `dev` adds a `mailhog/mailhog` SMTP catcher on `127.0.0.1:1025` (SMTP) + `127.0.0.1:8025` (web UI) so contributors can end-to-end test `MAILX_RCPT` mail subjects/bodies locally without a real relay.
  - The main `restic-backup` service has no `profiles:` key and is always brought up regardless of selection. README documents the matrix and the `docker compose --profile metrics --profile dev up` invocation.
- **Multiple backup jobs example** at [`examples/compose/multi-job.yml`](examples/compose/multi-job.yml). One container per dataset (documents/media/vmstore), all sharing one `RESTIC_REPOSITORY` + Restic password secret + per-job cache and log volumes via two YAML anchors (`x-restic-base`, `x-restic-env`). The "owner" container also runs `CHECK_CRON` + `PRUNE_CRON` for the shared repo so a heavy weekly prune does not run N times in parallel and trip the Restic repository lock. README has a new **"Multiple backup jobs"** section that documents the trade-offs vs. a single multi-job container (rejected: ambiguous `last-*.json`, no per-job mail subjects, single-cron contention).

### 1.15.0-0.18.1 (2026-05-10)

#### Added

- **Richer mail subjects** for backup, check, prune and sync notifications. Format: `[OK|FAIL <code>] <Job> <hostname> · <duration> · <details>`. Backup details now include the human-readable bytes-added value and an 8-char snapshot ID (when restic produced them); sync details include `<jobs> jobs (<failed> failed)`. Implemented in `lib.sh::format_subject` + `lib.sh::human_duration`.
- **Prometheus textfile collector** integration via the new **`METRICS_DIR`** env (default empty = disabled). When set, every worker writes `restic_<job>.prom` next to `last-<job>.json` with `restic_<job>_last_{exit_code,success,duration_seconds,finished_timestamp}` plus any numeric extras already passed to `last-run.json` (`files_new`, `bytes_added`, `sync_jobs_processed`, …). Atomic tmp+mv writes so a node-exporter scrape never sees a partial file. Implemented in `lib.sh::write_metrics_for_job`.
- **Bisync recovery hardening — `SYNC_BISYNC_CHECK_ACCESS`** (default `OFF`). When `ON`, the routine bisync runs and the recovery `--resync` invocation are extended with `--check-access`, so rclone aborts (instead of treating one side as "everything deleted") when the well-known `RCLONE_TEST` marker file is missing on either endpoint. One-way `sync`/`copy` modes are unaffected.
- **`mask_endpoint`** helper in `lib.sh`; the bisync worker now masks inline credentials in source/destination paths before logging them to `cron.log` and the recovery messages.
- **`CONTRIBUTING.md`** with the local quality-check workflow (CI script + optional pre-commit setup).
- **`.pre-commit-config.yaml`** mirroring the CI linter matrix (shellcheck, shfmt, hadolint, yamllint, actionlint plus generic hygiene hooks). Optional for contributors.
- **`examples/kubernetes/restic-backup-helper.yaml`** — full single-Pod Deployment + Secret + PVC manifest with the recommended `RESTIC_PASSWORD_FILE` + Secret pattern, FUSE-friendly capabilities, strong liveness probe, and pre-wired `METRICS_DIR` for node-exporter textfile scraping.

#### Changed

- **Dockerfile cleanup**: removed `apk upgrade` and inline-documented every remaining apk package (`bash`, `curl`, `fuse`, `libcap`, `mailx`, `msmtp`, `sshpass`, `sudo`, `tzdata`). Reproducibility win for the helper layer; CVE coverage stays the responsibility of the Trivy scan workflow and rebuilds against newer upstream `restic/restic` tags.
- New env vars exposed in the Dockerfile: `SYNC_BISYNC_CHECK_ACCESS=""` and `METRICS_DIR=""` (both default off; opt-in only).

### 1.14.0-0.18.1 (2026-05-10)

#### Added

- **Per-job sync mode and arguments** in `SYNC_JOB_FILE`. The format gains two optional columns: `SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]`.
  - `MODE` ∈ `bisync` (default, preserves the current copy-both + `--resync` recovery), `sync` (`rclone sync` one-way) or `copy` (`rclone copy` one-way). One-way modes have **no** automatic recovery.
  - `EXTRA_ARGS` are extra rclone flags appended after the global `SYNC_JOB_ARGS` for that job only (shell-word split). `--resync` is stripped from both the global and per-job lists for routine runs; the recovery path adds it explicitly when warranted.
  - Existing two-column lines (`SOURCE;DESTINATION`) keep working unchanged and run as bisync.

#### Changed (BREAKING for narrow edge case)

- **`/bin/backup` now refuses to run when `RESTIC_TAG` is empty** (previously only refused when *unset*; the Dockerfile default `automated` made the difference invisible). Empty `RESTIC_TAG` exits with code 2 and a clear error pointing operators at meaningful tag examples. Practical impact: only setups that explicitly set `RESTIC_TAG=""` are affected.
- **Sync invalid lines** (missing `SOURCE` / `DESTINATION` or unknown `MODE`) now count as failed jobs **and** trigger the mail/webhook error path so a malformed `SYNC_JOB_FILE` cannot silently produce a green run.

#### Security & supply chain

- **`rclone` is no longer installed twice.** Removed `rclone` from the `apk add` line in the Dockerfile so `install_rclone.sh` is the single source. Reduces image size and eliminates the silent overwrite of the Alpine-package binary.
- **`install_rclone.sh` now SHA256-verifies the downloaded archive** against the upstream `SHA256SUMS` published in the per-version directory. Stable installs (pinned or unpinned) always download from `https://downloads.rclone.org/v<version>/` because the `/current/` alias does not publish `SHA256SUMS`; the unpinned path resolves the version via `version.txt` first. Fails the build (exit 5) if `SHA256SUMS` is missing, the entry for the target arch is missing, or the checksum does not match. Beta channel keeps a clear log line that verification is skipped (no canonical SHA256SUMS).
- **Optional `RCLONE_VERSION` build-arg** in the Dockerfile pins to a specific upstream release (`docker build --build-arg RCLONE_VERSION=1.74.1 …`). Empty default keeps the "latest stable" behaviour but still downloads from the versioned, checksum-verified URL.

#### Docs

- README "Optional Rclone sync jobs" section rewritten with the new column format, examples for bisync / sync / copy and per-job args, and a clear note that one-way modes do not run the recovery procedure.
- README troubleshooting entry for "successful but empty backup" expanded to also cover `--files-from` / `--exclude-file` paths in `RESTIC_JOB_ARGS` and to recommend `restic snapshots latest --json`.
- README env table notes that `RESTIC_TAG` empty is now a hard failure.

### 1.13.1-0.18.1 (2026-05-10)

#### Changed

- **`/entry.sh`**: log an explicit `ℹ️ <name> cron disabled (<VAR> empty)` line for each optional cron (`CHECK_CRON`, `SYNC_CRON`, `PRUNE_CRON`) instead of silently skipping it. Operators can now confirm at a glance which schedules are active without grepping for absences in the startup log. No functional change to scheduling itself; backup and rotate cron lines still print as before.
- **Compose docs/examples**: replaced the abbreviated README Compose example with a comprehensive reference stack that lists every supported environment variable (Restic core, backup, optional check/prune/sync, mail, webhook, hooks, log rotation, locale), shows the recommended `RESTIC_PASSWORD_FILE` + Docker secrets pattern, and documents which volumes are required vs. optional. Refreshed `scripts/docker-compose.yml` as the lighter runnable starter with the same current options.

### 1.13.0-0.18.1 (2026-05-10)

#### Added

- **Standalone `restic prune` schedule** (`/bin/prune`) so retention can be decoupled from the post-backup `restic forget`. New environment variables:
  - **`PRUNE_CRON`** (default empty): when non-empty, `/entry.sh` schedules `/bin/prune` via `/bin/locked_run` on its own lock (`/var/run/prune.lock`).
  - **`RESTIC_PRUNE_ARGS`** (default empty): extra words passed to `restic prune` (e.g. `--max-unused 10%`, `--max-repack-size 5G`); shell-word split.
- **`/var/log/last-prune.json`**: same schema as the other per-run JSON summaries (`job`, `hostname`, `release`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `repository` (masked)). Posted to `WEBHOOK_URL` when configured. Supports `pre-prune.sh` / `post-prune.sh` hooks via the existing hook runner.
- **Mail subject** for prune mirrors backup/check (`Result of the last <hostname> prune run on <repository>`); honours `MAILX_RCPT` and `MAILX_ON_ERROR`.

#### Changed

- **`/entry.sh`** appends a fifth cron line when `PRUNE_CRON` is set; existing `RESTIC_FORGET_ARGS` behaviour in `/bin/backup` is unchanged. Typical pattern: keep `RESTIC_FORGET_ARGS=--keep-daily 7 --keep-weekly 4` (forget only, fast) on every backup and run `restic prune` (slow, repository-wide) once a week via `PRUNE_CRON='0 4 * * 0'`. If `RESTIC_FORGET_ARGS` already includes `--prune` the next standalone prune simply has nothing to do.

### 1.12.0-0.18.1 (2026-05-10)

#### Added

- **`RESTIC_AUTO_UNLOCK`** (default `OFF`): controls whether `/bin/backup` and `/bin/check` automatically run `restic unlock` after a non-zero exit. Set to `ON` to restore the historical default; the new safer default leaves the lock in place so the next run logs an explicit hint and the operator can inspect with `restic list locks` first.
- **`/bin/lib.sh`**: `should_auto_unlock` helper.

#### Changed (behaviour change — read before upgrading)

- **Automatic `restic unlock` after backup / check failures is now opt-in** (`RESTIC_AUTO_UNLOCK=ON`). Previously every non-zero `restic backup` / `restic forget` / `restic check` call was followed by `restic unlock`, which on a repository shared across multiple hosts could clear another host's legitimate lock and let two hosts mutate the repository concurrently. The new default logs `ℹ️ Skipping automatic 'restic unlock' (RESTIC_AUTO_UNLOCK!=ON)` with a one-line remediation hint instead. Single-host users who relied on auto-unlock to recover from their own crashed jobs should set `RESTIC_AUTO_UNLOCK=ON` explicitly. The `restic unlock --remove-all` call in `/entry.sh` after a failed `restic init` is unchanged because the lock can only have been created by the failing init attempt itself.

### 1.11.25-0.18.1 (2026-05-10)

#### Fixed

- **Cron skipped-run visibility**: introduce **`/bin/locked_run`**, a small lock-aware wrapper that the cron entries written by `/entry.sh` now invoke instead of `/usr/bin/flock -n` directly. When a previous backup / check / sync / rotate is still running and the new cron tick cannot acquire the lock, the wrapper logs `[<timestamp>] ⏭ <job> skipped: previous run still active (lock <path>)` to `/var/log/cron.log` and exits `0`, instead of leaving cron with an opaque non-zero `flock` exit that disappears silently. Implemented with `exec 9>"<lock>"; flock -n 9` (FD form) so it works with both util-linux and busybox `flock` without depending on `flock -E`. Worker exit codes are passed through unchanged via `exec "$@"`; lock files (`/var/run/{cron,check,bisync,rotate_log}.lock`) are unchanged.

### 1.11.24-0.18.1 (2026-05-10)

#### Changed

- **Strict-mode shell hygiene**: `/entry.sh`, `/bin/backup`, `/bin/check`, `/bin/bisync` and `/bin/rotate_log` now run under **`set -Eeuo pipefail`**. Every reference to a possibly-unset env var (`BACKUP_CRON`, `BACKUP_ROOT_DIR`, `RESTIC_TAG`, `RESTIC_FORGET_ARGS`, `RESTIC_JOB_ARGS`, `RESTIC_CHECK_ARGS`, `CHECK_CRON`, `SYNC_CRON`, `SYNC_JOB_FILE`, `SYNC_JOB_ARGS`, `NFS_TARGET`, `RESTIC_CHECK_REPOSITORY_STATUS`, `ROTATE_LOG_CRON`, `CRON_LOG_MAX_SIZE`, `MAX_CRON_LOG_ARCHIVES`, `HOSTNAME`, …) now uses `${VAR:-}` so missing config produces a clear validation error instead of a `unbound variable` crash. Restic and Rclone invocations are wrapped in `if/else` so non-zero exits are captured into `backupRC` / `checkRC` / `syncRC` / `copy1RC` / `copy2RC` (with the same downstream forget / unlock / mail / webhook / recovery branches as before). Fire-and-forget commands (`restic unlock`) and pre-hooks (`run_hook "pre-*"`) get an explicit `|| true` so they cannot abort the worker. **No user-visible output changes.**
- **`/bin/lib.sh`**: `run_hook` captures hook exit codes via `if/else` instead of `cmd; rc=$?` so duration logging and the timeout-vs-failure distinction still happen when a hook fails under `set -e` in the caller. `parse_restic_backup_stats` adds `|| true` to its `grep | tail` substitutions so missing log lines (failed runs) do not abort the caller under `pipefail`.

### 1.11.23-0.18.1 (2026-05-10)

#### Changed

- **Mail notification dedup**: extract the per-worker mail block into **`/bin/lib.sh::notify_mail`**. `/bin/backup`, `/bin/check` and `/bin/bisync` now share one implementation that honours `MAILX_RCPT`, `MAILX_ON_ERROR` and `LAST_LOGFILE` / `LAST_MAIL_LOGFILE` consistently. Behaviour is preserved: backup and check mail per run unless `MAILX_ON_ERROR=ON` (then only on failures); sync still mails only when a job recorded an unrecoverable error (the new helper accepts an optional third `error_only_override` argument that bisync passes as `"ON"`). Mail-send failures are logged via `errorlog` (always echoed) but never propagate to the worker exit code, so a flaky mail relay cannot fail an otherwise-successful backup.
- **`/bin/lib.sh`**: new `notify_mail <subject> <exit_code> [error_only_override]` helper. Closes the lib.sh refactor opened in 1.11.16.

### 1.11.22-0.18.1 (2026-05-10)

#### Added

- **Restic backup stats** parsed into `/var/log/last-backup.json` and the backup webhook payload: `snapshot_id` (short id from `snapshot <id> saved`), `files_new` / `files_changed` / `files_unmodified` and `bytes_added` / `bytes_stored` (human-readable strings as restic prints them, e.g. `1.234 MiB`). Closes the snapshot-id follow-up from 1.11.18; downstream monitoring (Slack, Discord, healthchecks.io, …) can surface "backup added X to repository, snapshot abc12345" without a second `restic snapshots` call. Fields are only added when restic actually printed them, so failed runs simply omit the keys.
- **`/bin/lib.sh`**: `parse_restic_backup_stats <log_file>` populates the new `BACKUP_STATS_*` globals from a captured `restic backup` text-format log; jq-free, tolerant of missing lines.

### 1.11.21-0.18.1 (2026-05-10)

#### Added

- **Webhook notifications**: when **`WEBHOOK_URL`** is set, `/bin/backup`, `/bin/check` and `/bin/bisync` POST the same JSON document that is written to `/var/log/last-<job>.json` to the configured endpoint after each run. New environment variables:
  - `WEBHOOK_URL` (default empty) — enables webhook delivery when set.
  - `WEBHOOK_HEADER_AUTH` (default empty) — sent verbatim as `Authorization: <value>` (e.g. `Bearer …`, `Token …`).
  - `WEBHOOK_TIMEOUT` (default `10`) — curl `--max-time` in seconds; non-positive values fall back to 10s.
  - `WEBHOOK_ON_ERROR` (default `OFF`) — when `ON`, only fire on non-zero exit codes (mirrors `MAILX_ON_ERROR`).
- **`/bin/lib.sh`**: `render_last_run_json`, `notify_webhook` and `mask_webhook_url` helpers. The mask logs only `scheme://host/...` so per-recipient secrets in path/query (healthchecks.io UUIDs, Slack/Discord webhook tokens, ntfy topic names, ...) never end up in container logs. Curl failures are logged as errors but do not propagate to the worker exit code, so a flaky webhook endpoint never fails an otherwise-successful backup.

#### Changed

- **`/bin/lib.sh`**: extract `render_last_run_json` from `write_last_run_json` so file and HTTP sinks share one schema.

### 1.11.20-0.18.1 (2026-05-10)

#### Fixed

- **Startup repository probe** (`/entry.sh` with `RESTIC_CHECK_REPOSITORY_STATUS=ON`): switch from `restic snapshots` to `restic cat config` and key the auto-`restic init` decision on **exit code 10** (repository does not exist) instead of "any non-zero status". Transient failures such as wrong password (12), network/DNS, TLS or auth errors now log the restic stderr output and abort startup with `exit 1` instead of silently re-initializing a healthy remote. Set `RESTIC_CHECK_REPOSITORY_STATUS` to anything other than `ON` to bypass both the probe and the auto-init.

### 1.11.19-0.18.1 (2026-05-10)

#### Added

- **Hook runner** (`/bin/lib.sh::run_hook`): centralised hook invocation for `/hooks/{pre,post}-{backup,check,sync}.sh` with consistent start, exit code and duration logging plus an optional **`HOOK_TIMEOUT`** (seconds; default `0` = no timeout). When set to a positive integer, hooks are wrapped in `timeout`; an exit code of `124` is logged prominently as a timeout. Non-executable hooks are reported as errors instead of silently doing nothing.
- **`HOOK_TIMEOUT`** environment variable (default `0`).

#### Changed

- **`/bin/backup`**, **`/bin/check`**, **`/bin/bisync`**: replace the six inlined hook checks with `run_hook` calls. Behaviour with `HOOK_TIMEOUT=0` is equivalent to the previous implementation; with a positive timeout, long-running hooks no longer block backups indefinitely.

### 1.11.18-0.18.1 (2026-05-10)

#### Added

- **Per-run last-run JSON files** under `/var/log` for external monitoring (no daemons or push gateways required):
  - `/var/log/last-backup.json` (job, hostname, release, started_at, finished_at, duration_seconds, exit_code, repository (masked), backup_root_dir, restic_tag).
  - `/var/log/last-check.json` (job, hostname, release, started_at, finished_at, duration_seconds, exit_code, repository (masked)).
  - `/var/log/last-sync.json` (job, hostname, release, started_at, finished_at, duration_seconds, exit_code, sync_jobs_processed, sync_jobs_failed).
- **`/bin/lib.sh`**: `write_last_run_json` writer, `json_escape` helper and `iso8601_local` formatter so the workers stay dependency-free (no `jq` in the image).

### 1.11.17-0.18.1 (2026-05-10)

#### Added

- **First-class `RESTIC_CACERT` wiring**: when **`RESTIC_CACERT`** points to a readable PEM bundle inside the container, `--cacert "$RESTIC_CACERT"` is automatically appended to every `restic` invocation in `/entry.sh` (`snapshots` probe, `init`, `unlock --remove-all`), `/bin/backup` (`backup`, `forget`, `unlock`) and `/bin/check` (`check`, `unlock`). Users no longer need to embed `--cacert` in `RESTIC_JOB_ARGS` / `RESTIC_CHECK_ARGS`. When `RESTIC_CACERT` is set but the file is unreadable, a warning is logged at runtime and the flag is omitted; **`config-check`** treats the same condition as a hard error.
- **`/bin/lib.sh`**: `build_restic_cacert_args` helper populates the shared `RESTIC_CACERT_ARGS` array consumed by the workers and the entrypoint.

#### Changed

- **README**: refreshed `RESTIC_CACERT` description to reflect the automatic wiring.
- **`/bin/backup`** and **`/bin/check`** now log `RESTIC_CACERT` alongside the other restic environment variables for traceability (the path itself, no certificate content).

### 1.11.16-0.18.1 (2026-05-10)

#### Changed

- **Shared runtime helpers**: extract `mask_repository`, `log`, `logLast`, `errorlog` and `copyErrorLog` to **`/bin/lib.sh`** (sourced by `/entry.sh`, `/bin/backup`, `/bin/check`, `/bin/bisync` and `/bin/rotate_log`). Pure refactor; user-visible behaviour for backup, check, bisync, rotate_log and entrypoint is unchanged.
- **`/bin/check`**: rename internal log variables `LAST_CHECK_LOGFILE` → `LAST_LOGFILE` and `LAST_ERROR_CHECK_LOGFILE` → `LAST_ERROR_LOGFILE` so the shared helpers can be reused. The on-disk file paths (`/var/log/check-last.log`, `/var/log/check-error-last.log`, `/var/log/check-mail-last.log`) are unchanged.
- **`/bin/bisync`**: keep current `SYNC_VERBOSE` semantics by mapping it onto `LOG_VERBOSE` for the shared `log()` helper (default `OFF` when `SYNC_VERBOSE` is unset, matching prior behaviour).

### 1.11.15-0.18.1 (2026-05-10)

#### Fixed

- **`/bin/rotate_log`**: archive **`cron.log`** with a relative path (`tar -C /var/log ... cron.log`) so extracted archives no longer recreate `/var/log/...`, and only truncate the live log after the `tar` archive is created successfully (previous behaviour could lose log data on archive failure).
- **`/entry.sh`**: fail fast and exit non-zero when **`NFS_TARGET`** is set but the `mount` call fails, instead of continuing to schedule jobs that would silently fail later.
- **`/entry.sh`**: reuse the same repository credential masking helper as `/bin/backup` and `/bin/check` so startup logs no longer expose embedded credentials in non-`https://` repository URLs (`s3:`, `sftp:`, `swift:`, `rclone:`).

#### Changed

- **`/bin/rotate_log`**: validate **`CRON_LOG_MAX_SIZE`** and **`MAX_CRON_LOG_ARCHIVES`** as positive integers and exit with a clear error otherwise, instead of failing inside `[`/`-ge` comparisons.
- **`/entry.sh`**, **`/bin/backup`**, **`/bin/check`**: drop obsolete commented-out **`RESTIC_PUBLICKEY`** / `CACERT_OPTION` lines now that custom CA usage is documented through `RESTIC_CACERT` / `--cacert` in `RESTIC_JOB_ARGS` and `RESTIC_CHECK_ARGS`.
- **README**: troubleshooting entry for *successful but empty backup* (mounted source missing or wrong path).

### 1.11.14-0.18.1 (2026-05-10)

#### Changed

- **`./build.sh`** / **`./build-testing.sh`** (via `scripts/build-common.sh`): no longer increment **`VERSION`** or **`sed`**-edit README files. Image tags and **`RESTIC_BACKUP_HELPER_RELEASE`** use the current **`VERSION`** plus **`VERSION_RESTIC`** (and `-dev` for testing). **`Dockerfile`** `FROM` is still updated from **`VERSION_RESTIC`**. Align **`VERSION`**, changelogs, and README release lines manually before release; **`scripts/update-restic-base.sh`** unchanged for Restic base bumps.

### 1.11.9-0.18.1 (2026-05-10)

#### Fixed

- **CI smoke test**: wait until **`restic init`** has finished (`restic` repo `config` present) before seeding and **`/bin/backup`** — avoids racing the entrypoint (`Running` was true while `entry.sh` still ran snapshots/init).

### 1.11.8-0.18.1 (2026-05-10)

#### Changed

- **Quality CI**: extend `scripts/ci-quality-checks.sh` with **yamllint** (tracked `*.yml` / `*.yaml`; falls back to `python3 -m yamllint` when the CLI is absent), **actionlint** (GitHub Actions), **hadolint** (`Dockerfile` + `.hadolint.yaml`; falls back to **`hadolint/hadolint`** when the binary is absent but Docker works), and **`docker compose … config -q`** on `ci/docker-compose.smoke.yml` and `scripts/docker-compose.yml` (Compose validation skips when Docker is unavailable). Workflow installs pinned **actionlint** and **hadolint** binaries for `amd64` / `arm64`; job timeout **20** minutes. Added **`.yamllint`**.
- **Example Compose**: remove obsolete top-level **`version`** key from `scripts/docker-compose.yml` (Compose V2).

### 1.11.7-0.18.1 (2026-05-10)

#### Changed

- **CI smoke workflow**: run `chmod +x ./ci/smoke-hooks/*.sh` before the smoke script so hook stubs are executable on the runner (redundant with `ci-smoke-test.sh`, explicit in YAML).

### 1.11.6-0.18.1 (2026-05-09)

#### Changed

- **CI smoke test**: exercise **`/bin/backup`** (with **`RESTIC_FORGET_ARGS`** so forget/prune runs), **`/bin/check`**, **`/bin/bisync`** (local directory pair + `ci/smoke-sync_jobs.txt`), **`/bin/rotate_log`** (low `CRON_LOG_MAX_SIZE` for deterministic rotation), mounted **hook stubs** under `ci/smoke-hooks`, snapshot verification, and bisync file replication check. NFS and real mail delivery remain out of scope for CI.

### 1.11.5-0.18.1 (2026-05-09)

#### Changed

- **CI**: upgrade `actions/upload-artifact` from v4 to **v6** (runs on Node.js 24; avoids deprecated Node 20 action runtime).

### 1.11.4-0.18.1 (2026-05-09)

#### Changed

- **Release metadata**: align `README.md` and `README-containers.md` release lines and pinned pull examples with `VERSION` and the Restic base tag in `Dockerfile` (CI versioning guard).

### 1.11.3-0.18.1 (2026-05-09)

#### Added

- **`config-check`** entrypoint mode: validate `RESTIC_REPOSITORY`, repository auth (`RESTIC_PASSWORD` or readable `RESTIC_PASSWORD_FILE`), `RESTIC_TAG`, backup paths (`BACKUP_ROOT_DIR` / `RESTIC_JOB_ARGS`), readable `RCLONE_CONFIG` when using `rclone:` repositories; warn when `SYNC_CRON` is set without a non-empty `SYNC_JOB_FILE`. Exits before cron, NFS mount, or repository init (CI-friendly).
- **Dependabot** (weekly) for GitHub Actions workflow dependency updates (`.github/dependabot.yml`).

#### Changed

- **`backup.sh`**: prominent warning when both `BACKUP_ROOT_DIR` and `RESTIC_JOB_ARGS` are empty (degenerate `restic backup` without paths).
- **Docs**: Compose **HEALTHCHECK** examples (weak `restic version` vs strong `restic cat config`), **`RESTIC_PASSWORD_FILE`** with Docker Compose secrets and a minimal Kubernetes pattern, private-registry **`NO_PROXY`** troubleshooting, **`config-check`** usage.
- **CI smoke**: `docker compose … run … config-check`; smoke compose sets `RESTIC_TAG` and `BACKUP_ROOT_DIR` for validation.

### 1.11.2-0.18.1 (2026-05-09)

#### Changed

- Expanded **BACKLOG.md** with grouped future ideas (observability, Restic ops, security, UX, sync, scale, docs/CI).

### 1.11.1-0.18.1 (2026-05-09)

#### Security

- **Mail:** invoke `mail` with a quoted `"${MAILX_RCPT}"` recipient instead of `sh -c … ${MAILX_RCPT}` to prevent command injection from a malicious env value.
- **Samples:** remove hardcoded repository/SMTP passwords from `scripts/docker-compose.yml` and `config/msmtprc`; require `.env` / local edits for secrets.
- **Compose healthcheck** uses `restic cat config` with repository settings from container env (no baked URL).
- **Trivy:** ignore **AVD-DS-0002** (non-root `USER`)—root is intentional for FUSE/NFS/cron in this image class; document mitigations in README.

### 1.11.0-0.18.1 (2026-05-09)

#### Changed

- Rewrote **README.md** and **README-containers.md**: accurate defaults from the image, full environment matrix, hooks, volumes, compose patterns, backend notes (S3, SFTP, Rclone, Swift, NFS), logging, mail, sync behaviour, and operations (backup, check, restore, mount). Added CI status badges to Docker Hub readme alignment.

### 1.10.5-0.18.1 (2026-05-09)

#### Changed

- `ci-quality-checks.sh`: use `continue` in versioning guard `case` branch so `shfmt` output matches across Ubuntu CI vs local toolchains (no empty `;;` arm).

### 1.10.4-0.18.1 (2026-05-09)

#### Changed

- Publish full `scripts/update-restic-base.sh` (VERSION patch, README/CHANGELOG, `VERSION_RESTIC` defaults) and align drift-radar messaging; `ci-quality-checks.sh` shfmt fix for empty `case` branch.

### 1.10.3-0.18.1 (2026-05-09)

#### Changed

- Ignore Trivy **AVD-DS-0031** for the Dockerfile: empty `ENV` placeholders for runtime secrets are intentional, not leaked build-time credentials.

### 1.10.2-0.18.1 (2026-05-09)

#### Changed

- `scripts/update-restic-base.sh` now bumps `VERSION` (patch), refreshes README release lines, prepends `CHANGELOG`, and syncs `VERSION_RESTIC` defaults when the Restic base tag changes (so drift/automation PRs satisfy the CI versioning guard).

### 1.10.1-0.18.1 (2026-05-09)

#### Added

- GitHub Actions workflows aligned with `marc0janssen/nzbgetvpn`: quality checks (`shellcheck`, `shfmt`), Docker smoke test, Trivy security scan, release orchestration on tags, and weekly drift radar for `restic/restic` base image updates.

### 1.10.0-0.18.1 (2026-05-09)

#### Added

- `README-containers.md` for Docker Hub (`docker pushrm --file`).
- `AGENTS.md` for coding agents; optional `build.env` / `build-testing.env`; `build-testing-local.sh` with env precedence fixes.
- Release metadata in images via `ARG`/`ENV RESTIC_BACKUP_HELPER_RELEASE` and OCI labels (no repository `.release` file).

#### Changed

- Build scripts: shared `scripts/build-common.sh`, env loading and `RESTIC_BACKUP_HELPER_RELEASE` build-arg on all publish builds.

### 1.9.97-0.18.1 (2025-09-28)

#### Changed
- Changed rclone 

### 1.9.97-0.18.1 (2025-09-28)

#### Changed
- Changed show RELEASE in LOGs
- Update Restic to version 0.18.1

### 1.8.89-0.18.0 (2025-04-25)

#### Added
- `RESTIC_CHECK_REPOSITORY_STATUS` - Optional. Check if repository is online on container startup. Default: `ON`

#### Changed
- Changed mail in backup script
- Changed mail in check script
- Changed mail in bisync script
- Masked the password in a REPO URL

### 1.7.76-0.18.0 (2025-04-06)

#### Changed
- Changed log in backup script
- Changed log in check script
- Changed log in bisync script

### 1.7.71-0.18.0 (2025-04-01)

#### Changed
- CRON backup is always started
- Revised build scripts
- Change Restic to version 0.18.0

### 1.7.68-0.17.3 (2025-03-27)

#### Added
- Unified the date in the scripts
- Rotate cron.log
- Healthcheck in container

#### Changed
- Healthcheck CMD changed to a non-locking command
- Typo in backup log text corrected


### 1.6.49-0.17.3 (2025-03-24)

#### Changed
- Automatic versioning when buidling the container

### 1.6.3-0.17.3 (2025-03-23)

#### Bugfix
- Backup script fixed

### 1.6.2-0.17.3 (2025-03-23)

#### Added
- Rclone bisync script added to enable a sync folder if you like

### 1.5.6-0.17.3 (2025-03-21)

#### Changed
- Updated Restic to version 0.17.3
- Revamped the code
- Restic running as root again
- Fixed mail with msmtp
- Reduced number of layers in Docker image
- switched to Rclone from Alpine Linux Repository

### 1.4.2-0.12.1 (2022-01-17)

#### Changed
- EXITCODE check MAILX

### 1.4.1-0.12.1

#### Added
- "bash" as shell

#### Changed
- Changed logpaths
- Removed the Microsoft Teams WEBHOOKS

#### Fixed
- checkRC missing

### 1.3.4-0.12.1

#### Fixed
- Fixed arguments for mail

### 1.3.3-0.12.1 (2021-12-31)

#### Added
- 'restic check' for repo can be setup now with CHECK_CRON and RESTIC_CHECK_ARGS

#### Changed
- Removed Openshift "Fix"
- mailsubject is a fixed text in backup and check script

#### Fixed
- .cache directory now within the context of user 'restic:users'

### 1.2.2-0.12.1

#### Changed
- Changed filepermission on /log directory

### 1.2.1-0.12.1

#### Fixed
- Fixed Dockerfile

### 1.2.0-0.12.1

#### Changed
- Log directory is now a volume and logs are exposed

### 1.1.2-0.12.1

#### Added
- Email only when the backup fails. Controlled by MAILX_ON_ERROR.

#### Changed
- Moved account creating and modified restic binary to the Dockerfile

#### Fixed
- Fixed typo in text
- Fixed calling the restic binary with extra file capabilities

### 1.0.0-0.12.1

#### Changed
- DOES NOT run as ROOT in the container so resulting backup is NOT OWNED by ROOT anymore
- Backup source PATH can be set by environment var BACKUP_ROOT_DIR (will default to /data if not set)
- Updated to Restic version 0.12.1

## Restic Backup Docker

### 1.3.1-0.9.6

#### Changed
- Update to Restic v0.9.5
- Reduced the number of layers in the Docker image

#### Fixed
- Check if a repo already exists works now for all repository types

#### Added
- ssh added to container
- fuse added to container
- support to send mails using external SMTP server after backups

### 1.2-0.9.4

#### Added
- AWS Support

### 1.1

#### Fixed
- `--prune` must be passed to `RESTIC_FORGET_ARGS` to execute prune after forget.

#### Changed
- Switch to base Docker container to `golang:1.7-alpine` to support latest restic build.

### 1.0

Initial release.

- The container has proper logs now and was running for over a month in production.
- There are still some features missing. Sticking to semantic versioning we do not expect any breaking changes in the 1.x releases.
