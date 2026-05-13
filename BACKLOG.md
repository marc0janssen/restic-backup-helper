# Backlog

Ideas and planned enhancements for **restic-backup-helper**. Ordering is not strict priority; tick items when shipped and note version/date like the done section.

---

## Done

- [x] Start time and date of container @20250312 1.6.54-0.17.3
- [x] Health check container @20250325 1.7.68-0.17.3
- [x] Cycle the cron.log (cycle, tar, delete after x) @20250326 1.7.68-0.17.3
- [x] Uniform date notations in all scripts @20250326 1.7.68-0.17.3

---

## Observability & notifications

- [x] **`/bin/doctor` read-only diagnostics**: one command for operator/support triage that prints release/tool versions, masked effective env, path/readability checks, `restic cat config` probe output, replicate job-file validation, hook executable status, recent `last-*.json` summaries and the tail of `cron.log`; exits non-zero only on hard configuration/probe errors — 2.1.0-0.18.1.
- [x] **Webhook** notifications after backup / check / sync via `WEBHOOK_URL` (POSTs the same JSON document as `/var/log/last-<job>.json`); supports `WEBHOOK_HEADER_AUTH`, `WEBHOOK_TIMEOUT` (default 10s) and `WEBHOOK_ON_ERROR` (only on non-zero exit) — 1.11.21-0.18.1.
- [x] **`last-run.json`** under `/var/log` for backup / check / replicate with job name, timestamps, duration, exit code, hostname and job-specific details (repository (masked), backup root, replicate job counts) — 1.11.18-0.18.1.
- [x] **Restic backup stats** in `last-backup.json` + backup webhook payload: `snapshot_id`, `files_new` / `files_changed` / `files_unmodified`, `bytes_added` / `bytes_stored` (parsed from `restic backup` text output) — 1.11.22-0.18.1.
- [x] **Prometheus textfile collector** integration via opt-in `METRICS_DIR`: every worker writes `restic_<job>.prom` (atomic tmp+mv) with exit code, success, duration, finished timestamp and any numeric extras already attached to `last-<job>.json`. README documents node-exporter wiring — 1.15.0-0.18.1.
- [x] **Richer mail subjects** for backup/check/prune/replicate: `[OK|FAIL <code>] <Job> <hostname> · <duration> · <details>` with bytes-added + snapshot ID (backup), masked repository (check/prune) and `<n> jobs (<m> failed)` (replicate). `lib.sh::format_subject` + `lib.sh::human_duration` — 1.15.0-0.18.1.
- [x] Documented **Compose HEALTHCHECK** recipes (weak vs strong: `restic version` vs `restic cat config` / `snapshots`) — 1.11.3-0.18.1.

---

## Restic & scheduling

- [x] First-class **`RESTIC_CACERT`** wiring in backup/check/entrypoint restic calls: append `--cacert "$RESTIC_CACERT"` automatically when set/readable; warn at runtime and error in `config-check` when set but unreadable — 1.11.17-0.18.1.
- [x] Standalone **`PRUNE_CRON`** + **`RESTIC_PRUNE_ARGS`** + `/bin/prune` so heavy `restic prune` runs on its own cadence (typically weekly) while `RESTIC_FORGET_ARGS` keeps post-backup forget cheap. Writes `/var/log/last-prune.json`, supports `pre-prune.sh` / `post-prune.sh` hooks and the `MAILX_*` / `WEBHOOK_*` notification stack — 1.13.0-0.18.1.
- [x] **`RESTIC_PASSWORD_FILE`** + **Docker/Kubernetes secrets** as primary examples in README / Compose samples — 1.11.3-0.18.1.
- [x] Pre/post **hook timeouts** and clearer logging of hook exit codes via `HOOK_TIMEOUT` (default `0` = no timeout) and `/bin/lib.sh::run_hook` — 1.11.19-0.18.1.
- [x] **Repository startup probe** distinguishes missing repository from transient failures: uses `restic cat config` and only runs `restic init` on exit code 10; aborts startup loudly with restic stderr on other non-zero exits — 1.11.20-0.18.1.
- [x] Make **automatic `restic unlock`** opt-in via `RESTIC_AUTO_UNLOCK` (default `OFF`); safer for repositories shared across multiple hosts. `/bin/backup` and `/bin/check` now log a one-line hint instead of clearing potentially-legitimate locks. `lib.sh::should_auto_unlock` helper — 1.12.0-0.18.1.
- [x] Improve cron **`flock -n` skipped-run logging** via `/bin/locked_run` wrapper that logs `⏭ <job> skipped: previous run still active (lock <path>)` to `/var/log/cron.log` and exits 0 instead of an opaque non-zero `flock` exit; works with both util-linux and busybox flock — 1.11.25-0.18.1.

---

## Runtime correctness & logging

- [x] Harden **`/bin/rotate_log`** so `cron.log` is truncated only after archive creation succeeds — 1.11.15-0.18.1.
- [x] Store rotated logs with relative archive paths (`tar -C /var/log ... cron.log`) instead of embedding `/var/log/cron.log` as an absolute path — 1.11.15-0.18.1.
- [x] Validate **`CRON_LOG_MAX_SIZE`** and **`MAX_CRON_LOG_ARCHIVES`** as positive integers before comparing sizes or pruning archives — 1.11.15-0.18.1.
- [x] Add explicit **NFS mount failure handling** in `entry.sh`: if `NFS_TARGET` is set and mount fails, log a clear error and exit non-zero instead of scheduling broken jobs — 1.11.15-0.18.1.
- [x] Reuse the stronger repository credential masking from backup/check in **`entry.sh`** so startup logs do not expose credentials in repository URLs — 1.11.15-0.18.1.

---

## Security & supply chain

- [x] Remove the duplicate **Rclone install path**: dropped `rclone` from the Dockerfile `apk add` line so `install_rclone.sh` is the single source — 1.14.0-0.18.1.
- [x] **Checksum-pinned Rclone download** in `install_rclone.sh`: verifies the archive against the upstream `SHA256SUMS` (per-version when `RCLONE_VERSION` build-arg is set), fails the build on mismatch — 1.14.0-0.18.1.
- [x] **SBOM artifacts on release builds**: opt-in `SBOM=ON ./build.sh` runs Syft against the pushed image and writes SPDX + CycloneDX JSON to `./sbom/` (gitignored); release-orchestration workflow additionally runs `anchore/sbom-action` against the source tree on every `v*` tag and uploads `sbom-source.{spdx,cyclonedx}.json` next to the existing Trivy diagnostics. README **Supply chain** section documents both surfaces — 1.16.0-0.18.1.
- [x] **Hardening (read-only root, non-root) docs**: README section explains why the image runs as root (cron, FUSE, NFS, hooks) and ships a Compose recipe (`read_only: true` + tmpfs for `/tmp`, `/run`, `/var/run`, `/var/spool/cron`, `/var/log`, `/.cache/restic`, plus `cap_drop: [ALL]` + `cap_add: [DAC_READ_SEARCH, SYS_ADMIN]` and `no-new-privileges:true`) so operators can tighten the blast radius at the orchestration layer without forking the image. A separate "slim" image remains an open backlog idea — 1.16.0-0.18.1.
- [x] Reviewed Dockerfile package strategy: dropped `apk upgrade` (reproducibility win, CVE coverage stays a Trivy-scan / base-rebuild responsibility) and inline-documented every remaining apk package — 1.15.0-0.18.1.
- [x] Audited logs and notification output: replicate source/destination credentials are now masked via new `lib.sh::mask_endpoint` helper; README "Logging & privacy" section enumerates the redaction surface (repository URL, replicate endpoints, webhook URL, webhook auth header, hook stdout, restic args) — 1.15.0-0.18.1.

---

## UX & operations

- [x] **`config-check` mode**: entrypoint or script that validates env + critical paths/mounts and exits non-zero before starting cron (CI / smoke friendly) — 1.11.3-0.18.1.
- [x] Clearer behaviour when **`BACKUP_ROOT_DIR` is empty** (warn loudly or documented single recommended pattern) — 1.11.3-0.18.1.
- [x] **`RESTIC_TAG`** ergonomics: `/bin/backup` now rejects an explicitly empty value (previously only unset was rejected) with a clear error and exit code 2; documented in env table and upgrade banner — 1.14.0-0.18.1.
- [x] Troubleshooting entry for **successful but empty backups** expanded with a step-by-step checklist that covers `BACKUP_ROOT_DIR`, `--files-from` / `--exclude-file` paths in `RESTIC_JOB_ARGS`, `restic snapshots latest --json` and the `last-backup.json` stats — 1.14.0-0.18.1.
- [x] **Operator-friendly restore wrapper** at `/bin/restore` (`app/restore.sh`). Combines a non-interactive flag-driven mode (`--id`, `--target`, `--tag`, `--host`, `--since`, `--include` / `--exclude`, `--owner UID:GID`, `--dry-run`, `--verify`, `--force`, `--list` / `--all`) with an interactive TTY mode that lists matching snapshots, prompts for target/dry-run and a final "Proceed? [y/N]" before mutating anything. Refuses non-empty targets / `BACKUP_ROOT_DIR` / `/data` without `--force`; mail + webhook on by default; writes `/var/log/last-restore.json` with `snapshot`, `target`, `dry_run`, `files_restored`, `bytes_restored`, `elapsed_human` (parsed via new `lib.sh::parse_restic_restore_stats`) and exports the same numbers via `METRICS_DIR`. Optional `/hooks/{pre,post}-restore.sh` hooks. Operator cancellation at the final prompt records `exit_code=130` + `cancelled=true` — 1.17.0-0.18.1.
- [x] **`/bin/snapshot-export`**: restore a selected snapshot or include-filter into a temporary work directory and package it as a `tar.gz` archive under `/restore` (or `--output`) for offline transfer / support handoff. Supports `--id`, `--tag`, `--host`, repeatable `--include` / `--exclude`, `--dry-run`, `--verify`, `--verbose`, `--work-dir`, `--keep-workdir`, `--force`, `/hooks/{pre,post}-snapshot-export.sh`, `/var/log/last-snapshot-export.json`, webhooks, mail and Prometheus textfile metrics (`restic_snapshot_export.prom`) — 2.2.0-0.18.1.
- [ ] **`/bin/notify-test`**: send a clearly-labelled test mail and/or webhook through the same `notify_mail` / `notify_webhook` helpers used by real jobs, so operators can validate `msmtprc`, `MAILX_RCPT`, `WEBHOOK_URL`, auth headers and timeout handling before waiting for a real backup failure.
- [x] **`/bin/forget-preview`**: safe `restic forget --dry-run` wrapper using the configured `RESTIC_FORGET_ARGS`, with host/tag-scoped output by default and an explicit `--repo-wide` override for repository-wide retention previews — 2.3.0-0.18.1.
- [x] **`/bin/mount-snapshot`**: operator-friendly wrapper around `restic mount` that defaults the visible snapshot tree to this container's `--host` + `--tag`, mounts read-only under `/restore`, refuses unsafe targets (`/data`, `BACKUP_ROOT_DIR`, system dirs) unless `--force`, supports repeatable `--path` and opt-in `--allow-other`, and traps `EXIT` so SIGINT / SIGTERM / crash always unmounts cleanly via `fusermount -u` (or `umount` fallback). Writes `/var/log/last-mount-snapshot.json`, `restic_mount_snapshot.prom`, optional `pre/post-mount-snapshot` hooks, and reuses the existing mail/webhook plumbing — 2.4.0-0.18.1.
- [x] **`/bin/forget` standalone retention worker** scheduled via `FORGET_CRON`, mirroring the `/bin/prune` shape (own `flock`, `last-forget.json`, `restic_forget.prom`, mail/webhook subject `Forget …`, `pre-forget` / `post-forget` hooks). Reuses `RESTIC_FORGET_ARGS` verbatim; when set, `/bin/backup` automatically skips its inline post-backup forget so the repository's exclusive forget-lock is only ever taken in this dedicated maintenance window — the recommended pattern for multi-host repositories (eliminates the exit-11 race) — 2.5.0-0.18.1.
- [x] **`/bin/cron-list`**: print the rendered crontab, timezone and a readable schedule summary so operators can quickly answer "what will run and when?" inside the container — 2.6.0-0.18.1.
- [x] **`/bin/unlock`**: explicit manual `restic unlock` wrapper with masked logging and `last-unlock.json`, complementing the safer `RESTIC_AUTO_UNLOCK=OFF` default. Supports `--dry-run` (list locks only) and `--remove-all` (also clear non-exclusive locks); records `locks_before` / `locks_after` and emits the same mail / webhook / `restic_unlock.prom` / `pre-unlock` / `post-unlock` surface as the other workers — 2.7.0-0.18.1.
- [x] **`/bin/sources-report`**: pre-flight source inventory that estimates source sizes and path readability for `BACKUP_ROOT_DIR` and common `--files-from` configurations before a backup runs. Default scope is automatic (BACKUP_ROOT_DIR plus every `--files-from` / `--exclude-file` discovered inside `RESTIC_JOB_ARGS`), with repeatable `--source PATH` / `--files-from FILE` for ad-hoc inspection, `--no-size` to skip `du -sk` on slow / remote sources and `--depth N` to cap `find` depth on huge trees. Emits `/var/log/last-sources-report.json` (flat aggregates plus nested `sources` / `files_from` / `exclude_files` arrays), `restic_sources_report.prom`, and the same mail / webhook / `pre-sources-report` / `post-sources-report` surface as the other workers — 2.8.0-0.18.1.
- [x] **`/bin/init-repo`**: explicit repository initialization helper with a confirmation prompt and no cron side effects, for operators who disable the entrypoint auto-init probe but still want a guided bootstrap command. Pairs with `RESTIC_CHECK_REPOSITORY_STATUS=OFF`: `--dry-run` runs the same `restic cat config` probe and prints the planned `restic init` command + verdict (`would CREATE` / `would REFUSE — already exists` / probe error) without mutation; without `--dry-run` either a typed `init` confirmation (interactive TTY) or an explicit `--yes` / `-y` flag is required. Adds the `RESTIC_INIT_ARGS` env-var for `--repository-version=2` / `--copy-chunker-params=…` pinning (with CLI passthrough after `--`), and emits `/var/log/last-init-repo.json` (flat aggregates plus `dry_run`, `assume_yes`, `confirmed`, `repo_existed`, `probe_exit_code`, `init_args`), `restic_init_repo.prom`, and the same mail / webhook / `pre-init-repo` / `post-init-repo` surface as the other workers. Idempotent: exits `3` when the repo already exists — 2.9.0-0.18.1.

---

## Rclone replicate

- [x] **One-way replicate jobs** (`rclone sync` / `copy`) in addition to **`bisync`** via an optional `MODE` column in `REPLICATE_JOB_FILE` (`SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]`); one-way modes have no automatic recovery — 1.14.0-0.18.1.
- [x] **Per-job** extra args via the optional 4th column in `REPLICATE_JOB_FILE`; appended after the global `REPLICATE_JOB_ARGS` for that job only and shell-word split — 1.14.0-0.18.1.
- [x] Hardened **bisync recovery** documentation + opt-in `REPLICATE_BISYNC_CHECK_ACCESS` (`OFF` default). When `ON`, routine bisync runs and the recovery `bisync --resync` are extended with `--check-access` so a missing `RCLONE_TEST` marker aborts loudly instead of letting a wiped remote propagate deletes. README has a "Bisync recovery hardening" subsection with marker-seeding steps and a recommendation to prefer one-way `sync`/`copy` modes when bidirectional behaviour is not needed — 1.15.0-0.18.1.
- [x] Rename the old **sync/bisync worker surface to replicate**: `app/replicate.sh`, `/bin/replicate`, `REPLICATE_*` env vars, `/var/log/last-replicate.json`, `restic_replicate.prom`, `pre/post-replicate` hooks and `config/replicate_jobs.txt`. Legacy `SYNC_*` env vars and `/bin/bisync` stay as deprecated compatibility aliases until 3.0.0 — 2.0.0-0.18.1.
- [ ] **3.0.0 cleanup:** remove deprecated `SYNC_*` env aliases and the `/bin/bisync` compatibility symlink after a full 2.x deprecation window.

---

## Code quality & maintainability

- [x] Introduce shared runtime helper library (`app/lib.sh` copied to `/bin/lib.sh`) for logging, `copyErrorLog`, repository masking — 1.11.16-0.18.1.
- [x] Remove obsolete commented **`RESTIC_PUBLICKEY`** / `CACERT_OPTION` code now that `RESTIC_CACERT` is the documented path — 1.11.15-0.18.1.
- [x] Add `set -Eeuo pipefail` to runtime workers (`/entry.sh`, `/bin/backup`, `/bin/check`, `/bin/replicate`, `/bin/rotate_log`) and `lib.sh::run_hook` / `parse_restic_backup_stats`; restic and rclone invocations wrapped in `if/else` to preserve exit-code handling around forget / unlock / recovery / mail / webhook branches — 1.11.24-0.18.1.
- [x] Generic **hook runner** in `/bin/lib.sh` with executable checks, timeout support (`HOOK_TIMEOUT`) and consistent logging of hook start, exit code and duration — 1.11.19-0.18.1.
- [x] Reduce duplicated mail-notification logic between backup/check/replicate into `/bin/lib.sh::notify_mail`; preserves `MAILX_ON_ERROR` semantics and replicate's "only on irrecoverable error" pattern via an optional third arg — 1.11.23-0.18.1.

---

## Multi-job / scale (larger changes)

- [x] **Multiple named backup jobs** as a documented multi-container Compose pattern: [`examples/compose/multi-job.yml`](examples/compose/multi-job.yml) uses two YAML anchors (`x-restic-base`, `x-restic-env`) so each per-dataset service only declares the parts that actually differ (cron, source mount, tag, forget policy, hostname). The "owner" service runs `CHECK_CRON` + `PRUNE_CRON` for the shared repo so a heavy weekly prune does not run N times in parallel and trip the Restic repository lock. README has a new **Multiple backup jobs** section that documents the trade-offs vs. an in-container multi-job design (rejected for now) — 1.16.0-0.18.1.
- [x] **Compose profiles** in [`scripts/docker-compose.yml`](scripts/docker-compose.yml): opt-in `metrics` profile adds a `prom/node-exporter` sidecar (bound to `127.0.0.1:9100`) that scrapes the textfile-collector volume; opt-in `dev` profile adds a `mailhog/mailhog` SMTP catcher (`127.0.0.1:1025` + `127.0.0.1:8025` web UI) so contributors can test mail notifications locally. The main `restic-backup` service has no `profiles:` key and is always included. A Helm chart remains an open backlog idea — 1.16.0-0.18.1.

---

## Docs & CI

- [x] **Kubernetes** example manifest at [`examples/kubernetes/restic-backup-helper.yaml`](examples/kubernetes/restic-backup-helper.yaml): single-Pod `Deployment` + `Secret` (Restic password + msmtprc) + `PersistentVolumeClaim` for `/var/log`, FUSE-friendly `cap_add`, strong liveness probe, pre-wired `METRICS_DIR` for node-exporter scraping; no plaintext passwords in env. README links it from the Compose section — 1.15.0-0.18.1.
- [x] **Pre-commit** config at [`.pre-commit-config.yaml`](.pre-commit-config.yaml) mirroring the CI matrix (shellcheck / shfmt / hadolint / yamllint / actionlint plus generic hygiene). [`CONTRIBUTING.md`](CONTRIBUTING.md) documents the local workflow — 1.15.0-0.18.1.
- [x] **Private registry** troubleshooting (proxy `NO_PROXY`, TLS to LAN registry) in README FAQ — 1.11.3-0.18.1.
- [x] **Dependabot** (or Renovate) for GitHub Actions pin bumps — 1.11.3-0.18.1 (Dependabot weekly on `/`).
