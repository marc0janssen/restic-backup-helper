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

- [x] **Webhook** notifications after backup / check / sync via `WEBHOOK_URL` (POSTs the same JSON document as `/var/log/last-<job>.json`); supports `WEBHOOK_HEADER_AUTH`, `WEBHOOK_TIMEOUT` (default 10s) and `WEBHOOK_ON_ERROR` (only on non-zero exit) — 1.11.21-0.18.1.
- [x] **`last-run.json`** under `/var/log` for backup / check / sync with job name, timestamps, duration, exit code, hostname and job-specific details (repository (masked), backup root, sync job counts) — 1.11.18-0.18.1.
- [x] **Restic backup stats** in `last-backup.json` + backup webhook payload: `snapshot_id`, `files_new` / `files_changed` / `files_unmodified`, `bytes_added` / `bytes_stored` (parsed from `restic backup` text output) — 1.11.22-0.18.1.
- [ ] **Prometheus** metrics endpoint or simple **node_exporter textfile** companion doc (push gateway pattern).
- [ ] Optional richer backup/check mail subjects using structured Restic output where practical (duration, status, bytes changed and snapshot ID).
- [x] Documented **Compose HEALTHCHECK** recipes (weak vs strong: `restic version` vs `restic cat config` / `snapshots`) — 1.11.3-0.18.1.

---

## Restic & scheduling

- [x] First-class **`RESTIC_CACERT`** wiring in backup/check/entrypoint restic calls: append `--cacert "$RESTIC_CACERT"` automatically when set/readable; warn at runtime and error in `config-check` when set but unreadable — 1.11.17-0.18.1.
- [ ] Optional **separate cron for `prune`** (decouple retention from post-backup `forget`).
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

- [ ] Remove the duplicate **Rclone install path** if possible: the image already installs `rclone` via `apk`; avoid also downloading and overwriting it with `install_rclone.sh`.
- [ ] If `install_rclone.sh` stays, add a **checksum-pinned** Rclone download (verify archive before unzip).
- [ ] **SBOM** artifact on release builds (e.g. Syft / build attestations) alongside existing Trivy CI.
- [ ] Optional **read-only root** + **non-root** exploration doc (likely separate “slim” image or documented trade-offs vs FUSE/NFS/cron-as-root).
- [ ] Review Dockerfile package strategy: avoid unnecessary `apk upgrade` during image build or document/justify it; keep Hadolint suppressions intentional.
- [ ] Audit logs and notification output for sensitive paths, repository URLs and mail/rclone config details before adding new observability features.

---

## UX & operations

- [x] **`config-check` mode**: entrypoint or script that validates env + critical paths/mounts and exits non-zero before starting cron (CI / smoke friendly) — 1.11.3-0.18.1.
- [x] Clearer behaviour when **`BACKUP_ROOT_DIR` is empty** (warn loudly or documented single recommended pattern) — 1.11.3-0.18.1.
- [ ] **`RESTIC_TAG`** ergonomics: stronger validation message or optional safe default policy (breaking change — needs semver note).
- [ ] Troubleshooting entry for **successful but empty backups**: guide users to verify mounted source paths and `BACKUP_ROOT_DIR` / `RESTIC_JOB_ARGS`.

---

## Rclone sync

- [ ] Optional **one-way** sync jobs (`rclone sync` / `copy`) in addition to **`bisync`** (same or parallel job file format).
- [ ] **Per-job** extra args (not only global `SYNC_JOB_ARGS`) — syntax TBD (e.g. optional third/fourth column or ini-style sections).
- [ ] Document and/or harden **bisync recovery**: current copy-both-directions plus `--resync` can be destructive when deletes/conflicts are real; consider `--check-access` guidance and opt-in recovery mode.

---

## Code quality & maintainability

- [x] Introduce shared runtime helper library (`app/lib.sh` copied to `/bin/lib.sh`) for logging, `copyErrorLog`, repository masking — 1.11.16-0.18.1.
- [x] Remove obsolete commented **`RESTIC_PUBLICKEY`** / `CACERT_OPTION` code now that `RESTIC_CACERT` is the documented path — 1.11.15-0.18.1.
- [x] Add `set -Eeuo pipefail` to runtime workers (`/entry.sh`, `/bin/backup`, `/bin/check`, `/bin/bisync`, `/bin/rotate_log`) and `lib.sh::run_hook` / `parse_restic_backup_stats`; restic and rclone invocations wrapped in `if/else` to preserve exit-code handling around forget / unlock / recovery / mail / webhook branches — 1.11.24-0.18.1.
- [x] Generic **hook runner** in `/bin/lib.sh` with executable checks, timeout support (`HOOK_TIMEOUT`) and consistent logging of hook start, exit code and duration — 1.11.19-0.18.1.
- [x] Reduce duplicated mail-notification logic between backup/check/sync into `/bin/lib.sh::notify_mail`; preserves `MAILX_ON_ERROR` semantics and bisync's "only on irrecoverable error" pattern via an optional third arg — 1.11.23-0.18.1.

---

## Multi-job / scale (larger changes)

- [ ] **Multiple named backup jobs** (different roots, tags, crons) in one container **or** official **multi-container Compose** pattern with shared repo env.
- [ ] **Helm chart** or **Compose profiles** (`minimal`, `backup+sync`, `dev`) to reduce copy-paste.

---

## Docs & CI

- [ ] **Kubernetes** example manifest: `Secret`/`env`, `SecurityContext`, optional `emptyDir` cache, no plaintext passwords in YAML.
- [ ] Add optional **pre-commit** setup for local shellcheck/shfmt/hadolint/yamllint/actionlint checks to match CI earlier in contributor workflows.
- [x] **Private registry** troubleshooting (proxy `NO_PROXY`, TLS to LAN registry) in README FAQ — 1.11.3-0.18.1.
- [x] **Dependabot** (or Renovate) for GitHub Actions pin bumps — 1.11.3-0.18.1 (Dependabot weekly on `/`).
