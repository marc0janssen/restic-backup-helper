# Changelog

## Restic Backup Helper

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
