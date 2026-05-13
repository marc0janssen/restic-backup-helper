# Restic Backup Helper

[![Quality Checks](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/quality-checks.yml)
[![Smoke Test](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/smoke-test.yml)
[![Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml)
[![Docs](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/docs.yml/badge.svg)](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/docs.yml)

Scheduled [Restic](https://restic.net) backups, optional `restic check`, optional [Rclone](https://rclone.org) **replicate** jobs (`bisync` / `sync` / `copy`), cron automation, logs under `/var/log`, optional mail via **msmtp** + **mailx**. Includes read-only operator helpers such as `/bin/doctor`, `/bin/cron-list`, `/bin/sources-report`, `/bin/notify-test` and an audited `/bin/init-repo` bootstrap wrapper. Based on **`restic/restic`** Alpine.

**Documentation:** [marc0janssen.github.io/restic-backup-helper](https://marc0janssen.github.io/restic-backup-helper/) · **GitHub (full manual, Compose, hooks, env matrix):** [github.com/marc0janssen/restic-backup-helper](https://github.com/marc0janssen/restic-backup-helper)

---

## Release

release: 2.11.0-0.18.1

**Stable**

```shell
docker pull marc0janssen/restic-backup-helper:latest
docker pull marc0janssen/restic-backup-helper:2.11.0-0.18.1
```

**Development (experimental)**

```shell
docker pull marc0janssen/restic-backup-helper:develop
docker pull marc0janssen/restic-backup-helper:2.11.0-0.18.1-dev
```

> **Upgrading?**
>
> - **2.10.1 → 2.11.0:** purely additive. `RESTIC_REPOSITORY_FILE` is now first-class. The entrypoint reads the first non-blank, non-comment line of the file and promotes it into `RESTIC_REPOSITORY` before the banner, the repository probe, the cron-driven workers and restic itself see the env, then unsets `RESTIC_REPOSITORY_FILE` so restic never fails with `Options --repo and --repository-file are mutually exclusive` (the image bakes a `RESTIC_REPOSITORY=/mnt/restic` default in `Dockerfile`, so the two would otherwise both be set). The "Assuming repository '…' is online" banner now shows the masked resolved URL, and `config-check` / `/bin/doctor` surface clear errors when the file is unreadable or empty/comments-only. No behaviour change when `RESTIC_REPOSITORY_FILE` is unset.
> - **2.10.0 → 2.10.1:** patch release. Prometheus textfile metrics now escape the `hostname` label and emit the documented `restic_<job>_last_started_timestamp` gauge, the webhook helper contract is documented accurately, and docs clarify that `RESTIC_*_ARGS` / `REPLICATE_*_ARGS` values are whitespace-split strings rather than full shell syntax. Keep paths/values free of spaces, or use file-based inputs such as `--files-from`, `--exclude-file` and rclone config files.
> - **2.9.0 → 2.10.0:** purely additive. New `/bin/notify-test` helper sends clearly-labelled test mail and/or webhook notifications through the same `notify_mail` / `notify_webhook` helpers used by real jobs, so operators can validate `msmtprc`, `MAILX_RCPT`, `WEBHOOK_URL`, `WEBHOOK_HEADER_AUTH` and `WEBHOOK_TIMEOUT` before waiting for a real failure. Default mode sends to every configured target; `--mail`, `--webhook` and `--all` select target scope; `--dry-run` prints what would be sent without invoking `mail` or `curl`; `--subject` / `--message` label the test. Unlike real workers, delivery failures affect the helper exit code (`1`) so CI can catch notification drift. Writes `/var/log/last-notify-test.json`, `restic_notify_test.prom`, and runs `pre-notify-test` / `post-notify-test` hooks. No new environment variables.
> - **2.8.0 → 2.9.0:** purely additive. New audited operator helper `/bin/init-repo` is the operator-driven counterpart to the entrypoint auto-init probe. The recommended deployment pattern on shared remotes is now `RESTIC_CHECK_REPOSITORY_STATUS=OFF` (no auto-init on a transient TLS / DNS / auth hiccup) plus a one-shot `/bin/init-repo --yes` (CI) or interactive `/bin/init-repo` (operator) for the first bootstrap. `--dry-run` runs the same `restic cat config` probe and prints the planned `restic init` command + verdict (`would CREATE` / `would REFUSE — already exists` / probe error) without mutation. Without `--dry-run` a typed `init` confirmation (interactive TTY) or explicit `--yes` is required. Adds the `RESTIC_INIT_ARGS` env-var (e.g. `--repository-version=2`, `--copy-chunker-params=…`); CLI passthrough after `--` works too. Writes `/var/log/last-init-repo.json` (with `dry_run`, `assume_yes`, `confirmed`, `repo_existed`, `probe_exit_code`, `init_args`), `restic_init_repo.prom`, and runs `pre-init-repo` / `post-init-repo` hooks, mail and webhook the same way as the other workers. Reachable via `docker exec … /bin/init-repo` or `docker run … init-repo`. Idempotent: exits `3` when the repo already exists. No behaviour change for the entrypoint auto-init probe; `RESTIC_CHECK_REPOSITORY_STATUS=ON` keeps its existing semantics.
> - **2.7.0 → 2.8.0:** purely additive. New read-only operator helper `/bin/sources-report` is a pre-flight inventory of the paths your next backup will actually read: re-uses the same `BACKUP_ROOT_DIR` + `RESTIC_JOB_ARGS` parsing as `/bin/backup`, reports readability, type, file count and (optional) size per source, plus pattern counts and missing-entry counts for every `--files-from` / `--exclude-file` reference. `--no-size` skips `du -sk` on slow / remote sources; `--depth N` caps `find` depth; repeatable `--source PATH` / `--files-from FILE` add ad-hoc entries. Writes `/var/log/last-sources-report.json` (flat aggregates plus nested `sources`, `files_from`, `exclude_files` arrays), `restic_sources_report.prom`, and runs `pre-sources-report` / `post-sources-report` hooks, mail and webhook the same way as the other workers. Reachable via `docker exec … /bin/sources-report` or `docker run … sources-report`. The size figure is unfiltered (exclude rules are not applied); the exclude-file inventory is reported separately. No env-var changes.
> - **2.6.0 → 2.7.0:** purely additive. New audited operator helper `/bin/unlock` complements the safer `RESTIC_AUTO_UNLOCK=OFF` default (workers still never auto-clear locks on failure). Removes stale exclusive locks by default; `--remove-all` widens to non-exclusive locks; `--dry-run` only lists current locks. Writes `/var/log/last-unlock.json` (with `remove_all`, `dry_run`, `locks_before`, `locks_after`), `restic_unlock.prom`, and runs `pre-unlock` / `post-unlock` hooks, mail and webhook the same way as the other workers. Reachable via `docker exec … /bin/unlock` or `docker run … unlock`. No env-var changes; `RESTIC_AUTO_UNLOCK` keeps its existing semantics.
> - **2.5.0 → 2.6.0:** purely additive. New read-only `/bin/cron-list` inspector prints `TZ`, the rendered crontab and a per-job summary (run via `docker exec … /bin/cron-list` or `docker run … cron-list`). Build scripts gain a `--base <restic-tag>` CLI flag with `newest`/`latest` and `prerelease`/`rc`/`beta` sentinels resolved against Docker Hub before the tag is computed; the resolved tag is verified to exist on Docker Hub before any files are mutated, so a non-existent `--base 0.19.0` aborts cleanly instead of producing an image whose tag suffix does not match the base actually used. `./build-testing-local.sh` now also patches `Dockerfile FROM` to match `--base`, and pushes `:develop` instead of `:testing` (versioned `:<release>` tag unchanged) — update any `image: …:testing` references in your private-registry manifests to `…:develop` or pin to `…:2.6.0-0.18.1-dev`. No runtime change inside the container beyond the new cron-list helper.
> - **2.4.0 → 2.5.0:** multi-host retention hardening. New standalone `/bin/forget` worker scheduled via `FORGET_CRON` (own JSON/Prometheus/mail/webhook/hooks like `/bin/prune`); when set, `/bin/backup` skips its inline forget so the exclusive lock is only taken in the dedicated window — eliminates the exit-11 race. Inline post-backup forget exit 11 is also downgraded to `⏭ Forget skipped …` (backup `exit_code` stays `0`); the forget result is recorded separately as `forget_exit_code` in `last-backup.json` and as a `restic_backup_last_forget_exit_code` Prometheus gauge. `restic unlock` is **never** auto-run on exit 11 regardless of `RESTIC_AUTO_UNLOCK` (the lock we lost is another host's legitimate lock). Drop-in: `FORGET_CRON` empty (= default) keeps legacy behaviour. Adding `--retry-lock=DURATION` to `RESTIC_FORGET_ARGS` is recommended either way.
> - **2.3.x → 2.4.0:** additive. New `/bin/mount-snapshot` helper wraps `restic mount` (FUSE) read-only under `/fusemount` (container-internal by design, never collides with `/bin/restore` output or host bind-mounts), scoped to this container's host/tag by default, with safe target validation, opt-in `--allow-other`, repeatable `--path`, an explicit `--repo-wide` override and an `EXIT` trap so SIGINT / SIGTERM / crash always unmounts cleanly. FUSE still requires `--cap-add SYS_ADMIN --device /dev/fuse` and, on hosts that ship AppArmor's `docker-default` profile, `--security-opt apparmor=unconfined`.
> - **2.2.x → 2.3.0:** additive. New `/bin/forget-preview` helper runs `restic forget --dry-run` with `RESTIC_FORGET_ARGS`, host/tag-scoped by default and repository-wide only with `--repo-wide`.
> - **2.2.1 → 2.2.2:** docs/patch. Adds a Material for MkDocs documentation site (hosted at <https://marc0janssen.github.io/restic-backup-helper/>) plus a GitHub Pages deploy workflow. No runtime change.
> - **2.2.0 → 2.2.1:** patch. CI-only shellcheck cleanup in `app/snapshot_export.sh` (SC2317/SC2119); no runtime change.
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
| `<semver>-<restic>` | Pinned stable (helper version + Restic base), e.g. `2.11.0-0.18.1` |
| `develop` | Latest testing build |
| `<semver>-<restic>-dev` | Pinned testing image |

Full documentation: <https://marc0janssen.github.io/restic-backup-helper/>

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
| **Cron list** | `/bin/cron-list` or `docker run … cron-list` prints timezone, rendered crontab and schedule summary |
| **Snapshot export** | One-shot `/bin/snapshot-export` or `docker run … snapshot-export` archives a selected snapshot/subtree as `.tar.gz` |
| **Forget preview** | One-shot `/bin/forget-preview` or `docker run … forget-preview` previews `RESTIC_FORGET_ARGS` with `restic forget --dry-run` |
| **Mount snapshot** | One-shot `/bin/mount-snapshot` or `docker run … mount-snapshot` mounts the repo read-only over FUSE under `/fusemount` (container-internal; needs `--cap-add SYS_ADMIN --device /dev/fuse` + `--security-opt apparmor=unconfined` on Ubuntu/Debian hosts) |
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

**Forget policy:** set `RESTIC_FORGET_ARGS` (example: `--retry-lock=5m --keep-daily 7 --keep-weekly 5 --keep-monthly 12`) to run `restic forget` after a successful backup. Add `--prune` only if you do not run `PRUNE_CRON` separately. Run `/bin/forget-preview` first to preview the policy safely (`--dry-run`, host/tag-scoped by default).

**Mail:** `MAILX_RCPT` + mounted **`/etc/msmtprc`**; `MAILX_ON_ERROR=ON` limits backup/check mail to failures. Replicate mails only when errors occurred.

**Replicate file format:** `SOURCE;DESTINATION[;MODE[;EXTRA_ARGS]]` per line (`MODE` ∈ `bisync` (default) / `sync` / `copy`; `EXTRA_ARGS` are per-job rclone flags). See [`config/replicate_jobs.txt`](https://github.com/marc0janssen/restic-backup-helper/blob/master/config/replicate_jobs.txt). Bisync recovery hardening: set `REPLICATE_BISYNC_CHECK_ACCESS=ON` to require the `RCLONE_TEST` marker on both endpoints.

**Metrics:** set `METRICS_DIR=/var/log/textfile_collector` to write Prometheus textfile-collector `*.prom` files alongside `last-*.json` (point node-exporter at it).

---

## Hooks (`/hooks`)

`pre-backup.sh`, `post-backup.sh` (backup exit code), `pre-check.sh`, `post-check.sh` (check exit code), `pre-prune.sh`, `post-prune.sh` (prune exit code), `pre-replicate.sh`, `post-replicate.sh` (aggregate replicate exit code), `pre-restore.sh`, `post-restore.sh` (restore exit code), `pre-snapshot-export.sh`, `post-snapshot-export.sh` (snapshot export exit code), `pre-forget-preview.sh`, `post-forget-preview.sh` (forget preview exit code), `pre-mount-snapshot.sh`, `post-mount-snapshot.sh` (mount snapshot exit code, called after unmount).

---

## Security

Do not embed secrets in image tags or public Hub descriptions. Use env files, secrets, or mounts excluded from git. Treat `rclone.conf` as sensitive.

---

## Links

- **Documentation site (Material for MkDocs):** <https://marc0janssen.github.io/restic-backup-helper/>
- **Full manual (README on GitHub):** [README.md](https://github.com/marc0janssen/restic-backup-helper/blob/master/README.md)
- **Changelog:** [CHANGELOG.md](https://github.com/marc0janssen/restic-backup-helper/blob/master/CHANGELOG.md)
- **Issues / source:** [GitHub repository](https://github.com/marc0janssen/restic-backup-helper)

---

_Image lineage: derived from [lobaro/restic-backup-docker](https://github.com/lobaro/restic-backup-docker)._
