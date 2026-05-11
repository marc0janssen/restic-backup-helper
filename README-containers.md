# Restic Backup Helper

[![Quality Checks](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml)
[![Smoke Test](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml)
[![Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml)

Scheduled [Restic](https://restic.net) backups, optional `restic check`, optional [Rclone](https://rclone.org) **replicate** jobs (`bisync` / `sync` / `copy`), cron automation, logs under `/var/log`, optional mail via **msmtp** + **mailx**. Based on **`restic/restic`** Alpine.

**GitHub (full manual, Compose, hooks, env matrix):** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper)

---

## Release

release: 2.2.0-0.18.1

**Stable**

```shell
docker pull marc0janssen/restic-backup-helper:latest
docker pull marc0janssen/restic-backup-helper:2.2.0-0.18.1
```

**Development (experimental)**

```shell
docker pull marc0janssen/restic-backup-helper:develop
docker pull marc0janssen/restic-backup-helper:2.2.0-0.18.1-dev
```

> **Upgrading?**
>
> - **2.1.x → 2.2.0:** purely additive. New `/bin/snapshot-export` helper restores a selected snapshot or subtree into a temporary workdir and packages it as `.tar.gz` under `/restore` by default. Supports `--id`, `--include`, `--exclude`, `--output`, `--dry-run`, hooks, JSON, webhook, mail and metrics.
> - **2.0.x → 2.1.0:** purely additive. New `/bin/doctor` read-only diagnostics command for support/triage: masked effective env, path checks, repository probe, replicate job-file validation, hook executable status and recent `/var/log` summaries. `docker run … doctor` runs it without starting cron.
> - **1.18.x → 2.0.0:** the old "sync/bisync" surface is renamed to **replicate**. Use `/bin/replicate`, `REPLICATE_*` env vars, `/config/replicate_jobs.txt`, `/hooks/pre-replicate.sh` / `/hooks/post-replicate.sh`, `/var/log/last-replicate.json`, `/var/log/replicate-last.log` and `restic_replicate.prom`. Legacy `SYNC_*` env vars and `/bin/bisync` still work with deprecation warnings and will be removed in 3.0.0. Rename any mounted `config/sync_jobs.txt` to `config/replicate_jobs.txt` or set `REPLICATE_JOB_FILE` explicitly. Monitoring and hook paths must be updated.
> - **1.17.x → 1.18.0:** polish on top of the 1.17.0 `/bin/restore` wrapper. Three operator-visible additions: `--yes` / `-y` runs the wrapper fully non-interactively (skips picker + target + dry-run + Proceed prompts, fills missing answers with cron/CI defaults — useful from inside `docker exec -ti …`); `--verbose` / `-v` now actually streams progress (passes `--verbose=2` to restic for per-file lines AND wraps restic in `script(1)` so the native in-place progress bar renders); interactive mode is TTY-driven only, so modifier flags like `--verbose` and `--force` no longer skip the prompts. Image grows ~6 MB to ship `util-linux` (for `script(1)`). `--include` zero-match now exits `3` instead of silently succeeding. Pure polish, no breaking changes for existing scripted callers.
> - **1.16.x → 1.17.0:** purely additive. New `/bin/restore` wrapper (interactive on a TTY, flag-driven otherwise) with mail/webhook on by default and `/var/log/last-restore.json` summary; optional `/hooks/{pre,post}-restore.sh`. Refuses to restore into `/data` or a non-empty `--target` unless `--force` (or `--dry-run`). See the GitHub README "Restore (operator-friendly)" section.
> - **1.15.x → 1.16.0:** purely additive (no env-var rename, no behaviour change). New surfaces: opt-in image SBOM via `SBOM=ON ./build.sh` (requires `syft`); source-tree SBOM uploaded by the release CI; `scripts/docker-compose.yml` ships Compose profiles `metrics` (node-exporter sidecar) and `dev` (mailhog); new multi-job example at `examples/compose/multi-job.yml`; new README "Hardening" section with the `read_only: true` + tmpfs recipe.
> - **1.14.x → 1.15.0:** purely additive. New opt-in env vars `METRICS_DIR` (Prometheus textfile collector) and `REPLICATE_BISYNC_CHECK_ACCESS` (bisync `--check-access` opt-in; legacy `SYNC_BISYNC_CHECK_ACCESS` accepted until 3.0.0). Mail subjects gain `[OK|FAIL N] Job host · duration · details` prefix. Replicate URL credentials are masked in logs.
> - **1.13.x → 1.14.0:** explicitly empty `RESTIC_TAG` is now a hard error. Replicate job files accept optional `MODE` / `EXTRA_ARGS` columns. `rclone` is now installed once with SHA256 verification.
> - **From 1.11.x:** automatic `restic unlock` after backup / check failures is opt-in (`RESTIC_AUTO_UNLOCK=ON`, since 1.12.0). 1.13.0 adds standalone `PRUNE_CRON` + `RESTIC_PRUNE_ARGS`. See the GitHub README env table.

---

## Tags

| Tag | Meaning |
| --- | --- |
| `latest` | Current stable |
| `<semver>-<restic>` | Pinned stable (helper version + Restic base), e.g. `2.2.0-0.18.1` |
| `develop` | Latest testing build |
| `<semver>-<restic>-dev` | Pinned testing image |

---

## What runs inside

| Component | Trigger |
| --- | --- |
| **Backup** | `BACKUP_CRON` → `/bin/backup` |
| **Check** | `CHECK_CRON` (if set) → `/bin/check` |
| **Prune** | `PRUNE_CRON` (if set) → `/bin/prune` (standalone `restic prune` on its own cadence) |
| **Replicate** | `REPLICATE_CRON` (if set) → `/bin/replicate` reading `REPLICATE_JOB_FILE` |
| **Log rotate** | `ROTATE_LOG_CRON` → `/bin/rotate_log` for `cron.log` |
| **Config check** | One-shot `docker run … config-check` (same env as prod) validates settings without cron |
| **Doctor** | One-shot `/bin/doctor` or `docker run … doctor` read-only diagnostics for support/triage |
| **Snapshot export** | One-shot `/bin/snapshot-export` or `docker run … snapshot-export` archives a selected snapshot/subtree as `.tar.gz` |
| **Restore** | One-shot `/bin/restore`; interactive with a TTY, flag-driven otherwise |

Startup (`/entry.sh`) can verify/init the repo when `RESTIC_CHECK_REPOSITORY_STATUS=ON`. Jobs use **`flock`** locks (`/var/run/*.lock`).

---

## Mount points (typical)

| Path | Use |
| --- | --- |
| `/data` | Backup source (`BACKUP_ROOT_DIR` often `/data`) |
| `/config` | `rclone.conf`, excludes, `msmtprc`, replicate job file |
| `/hooks` | Optional `pre-*` / `post-*` scripts |
| `/var/log` | Persist logs on the host |
| `/restore` | Common restore target volume |

---

## Environment essentials

**Always configure:** `RESTIC_REPOSITORY`, repository auth (`RESTIC_PASSWORD` or `RESTIC_PASSWORD_FILE`), **`RESTIC_TAG`** (required by backup), **`BACKUP_CRON`**, and either **`BACKUP_ROOT_DIR`** and/or paths via **`RESTIC_JOB_ARGS`**.

**Defaults from the image (see GitHub README for full table):** `RESTIC_CACHE_DIR=/.cache/restic`, `RESTIC_CHECK_REPOSITORY_STATUS=ON`, `RCLONE_CONFIG=/config/rclone.conf`, `REPLICATE_JOB_FILE=/config/replicate_jobs.txt`, `REPLICATE_VERBOSE=ON`, `ROTATE_LOG_CRON=0 0 * * 6`, `CRON_LOG_MAX_SIZE=1048576`, `MAX_CRON_LOG_ARCHIVES=5`, `TZ=Europe/Amsterdam`.

**Forget policy:** set `RESTIC_FORGET_ARGS` (example: `--prune --keep-daily 7`) to run `restic forget` after a successful backup.

**Mail:** `MAILX_RCPT` + mounted **`/etc/msmtprc`**; `MAILX_ON_ERROR=ON` limits backup/check mail to failures. Replicate mails only when errors occurred.

**Replicate file format:** `SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]` per line (`MODE` ∈ `bisync` (default) / `sync` / `copy`; `EXTRA_ARGS` are per-job rclone flags). See [`config/replicate_jobs.txt`](https://github.com/marc0janssen/restic-backup-helper/blob/master/config/replicate_jobs.txt). Bisync recovery hardening: set `REPLICATE_BISYNC_CHECK_ACCESS=ON` to require the `RCLONE_TEST` marker on both endpoints.

**Metrics:** set `METRICS_DIR=/var/log/textfile_collector` to write Prometheus textfile-collector `*.prom` files alongside `last-*.json` (point node-exporter at it).

---

## Hooks (`/hooks`)

`pre-backup.sh`, `post-backup.sh` (backup exit code), `pre-check.sh`, `post-check.sh` (check exit code), `pre-prune.sh`, `post-prune.sh` (prune exit code), `pre-replicate.sh`, `post-replicate.sh` (aggregate replicate exit code), `pre-restore.sh`, `post-restore.sh` (restore exit code), `pre-snapshot-export.sh`, `post-snapshot-export.sh` (snapshot export exit code).

---

## Security

Do not embed secrets in image tags or public Hub descriptions. Use env files, secrets, or mounts excluded from git. Treat `rclone.conf` as sensitive.

---

## Links

- **Documentation:** [README.md on GitHub](https://github.com/marc0janssen/restic-backup-helper/blob/master/README.md)
- **Changelog:** [CHANGELOG.md](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)
- **Issues / source:** [GitHub repository](https://github.com/marc0janssen/restic-backup-helper)

---

_Image lineage: derived from [lobaro/restic-backup-docker](https://github.com/lobaro/restic-backup-docker)._
