# Upgrading

This page captures the upgrade notes for every release that needs operator
attention. Patch releases that only fix bugs without changing behaviour are
omitted; see the full [Changelog](../changelog.md) for every release.

## How versions are cut

| Bump | Trigger | What you should expect |
| --- | --- | --- |
| **PATCH** | Bugfix, docs-only change, rebuild tweak, Restic patch bump without behaviour change. | Drop in. No config changes required. |
| **MINOR** | New feature, new env variable, new script hook, materially new behaviour. | Drop in; pre-existing behaviour preserved. May expose new optional knobs. |
| **MAJOR** | Breaking configuration, path, or runtime contract change. | Read the upgrade note carefully. May require config rename. |

See [Versioning policy](../concepts/versioning.md) for the full semver
contract.

## 2.2.x → 2.3.0

Purely additive. New `/bin/forget-preview` helper previews retention with
`restic forget --dry-run` using `RESTIC_FORGET_ARGS`.

By default it scopes the preview to the current container's `HOSTNAME`
and `RESTIC_TAG`, which is safer for repositories shared by multiple
hosts. Use `--repo-wide` only when you intentionally want to preview the
policy against every snapshot in the repository.

It writes `/var/log/last-forget-preview.json`, supports
`pre/post-forget-preview` hooks, webhooks, mail and Prometheus metrics.

[Forget preview :material-arrow-right:](../operations/forget-preview.md)

## 2.2.1 → 2.2.2

Patch / docs release. Adds the Material for MkDocs documentation site
under `docs/` and the GitHub Pages workflow. No runtime behaviour change.

## 2.2.0 → 2.2.1

Patch release. CI-only fix in `app/snapshot_export.sh`:

- Combined `# shellcheck disable=SC2317,SC2329` on the EXIT-trap `cleanup()`
  function (false positive about unreachable code).
- Explicit `copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"` call to
  satisfy SC2119 in newer shellcheck versions.

**No runtime behaviour change. No env-var change. Drop in.**

## 2.1.x → 2.2.0

Purely additive. New `/bin/snapshot-export` helper restores a selected
snapshot (or include-filtered subtree) into a temporary work directory and
packages it as a `.tar.gz` archive under `/restore` by default. It supports
`--id`, `--include`, `--exclude`, `--output`, `--dry-run`, `--verify`,
hooks, JSON, webhook, mail and Prometheus metrics.

[Snapshot export :material-arrow-right:](../operations/snapshot-export.md)

## 2.0.x → 2.1.0

Purely additive. New `/bin/doctor` read-only diagnostics command for
support/triage. Prints release/tool versions, masked effective env, path
checks, `restic cat config` probe, replicate job-file validation, hook
executable status, recent `last-*.json` summaries and the tail of
`cron.log`.

`docker run … doctor` and `docker run … /bin/doctor` execute it directly
without starting cron, so it works equally well as an entrypoint and via
`docker exec`.

[Diagnostics :material-arrow-right:](../operations/diagnostics.md)

## 1.18.x → 2.0.0 :material-alert-octagon:{ title="Breaking" }

The old "sync/bisync" surface is renamed to **replicate**. The runtime keeps
a compatibility bridge until 3.0.0, but plan to migrate on your schedule.

### What changed

| Old name | New name |
| --- | --- |
| `app/bisync.sh` worker | `app/replicate.sh` |
| `/bin/bisync` | `/bin/replicate` (with `/bin/bisync` symlink kept until 3.0.0) |
| `/var/run/bisync.lock` | `/var/run/replicate.lock` |
| `/var/log/sync-last.log` | `/var/log/replicate-last.log` |
| `/var/log/sync-error-last.log` | `/var/log/replicate-error-last.log` |
| `/var/log/sync-mail-last.log` | `/var/log/replicate-mail-last.log` |
| `/var/log/last-sync.json` | `/var/log/last-replicate.json` |
| `restic_sync.prom` | `restic_replicate.prom` |
| `/hooks/pre-sync.sh`, `/hooks/post-sync.sh` | `/hooks/pre-replicate.sh`, `/hooks/post-replicate.sh` |
| Mail subject `Sync` | `Replicate` |
| `config/sync_jobs.txt` (sample) | `config/replicate_jobs.txt` |
| `SYNC_CRON` | `REPLICATE_CRON` |
| `SYNC_JOB_FILE` | `REPLICATE_JOB_FILE` |
| `SYNC_JOB_ARGS` | `REPLICATE_JOB_ARGS` |
| `SYNC_VERBOSE` | `REPLICATE_VERBOSE` |
| `SYNC_BISYNC_CHECK_ACCESS` | `REPLICATE_BISYNC_CHECK_ACCESS` |

### Compatibility bridge

- `/bin/bisync` is symlinked to `/bin/replicate` until **3.0.0**.
- All `SYNC_*` env vars are read at startup and mapped to their `REPLICATE_*`
  counterparts when the new name is unset, with a deprecation warning in
  `cron.log` so you can see what is still legacy.
- The rclone per-job MODE value `bisync` is unchanged. Job rows of the form
  `SOURCE;DESTINATION;bisync`, `SOURCE;DESTINATION;sync` and
  `SOURCE;DESTINATION;copy` keep working as-is.

### What you must do

1. **Migrate the env vars.** Rename `SYNC_*` → `REPLICATE_*` in your
   `docker-compose.yml`, `.env`, Kubernetes manifest. Helpful one-liner:

    ```shell
    sed -i 's/\bSYNC_/REPLICATE_/g' docker-compose.yml
    ```

2. **Rename the job file** (or set the env var). The installed default is now
   `REPLICATE_JOB_FILE=/config/replicate_jobs.txt`. If you keep the old
   filename, set it explicitly:

    ```yaml
    environment:
      REPLICATE_JOB_FILE: /config/sync_jobs.txt
    ```

3. **Update monitoring / scrapers** that read `last-sync.json` or
   `restic_sync.prom` — those files no longer exist.

4. **Update hooks** if you have `/hooks/pre-sync.sh` / `/hooks/post-sync.sh`.
   The runtime does not read them anymore; rename to `pre-replicate.sh` /
   `post-replicate.sh`.

The compatibility bridge means you can do these in any order. The old `SYNC_*`
env var names continue to work, but each emits a deprecation warning into
`cron.log` until you switch over.

### Removal in 3.0.0

In `3.0.0` (no date set yet), the bridge will be removed: `/bin/bisync`
symlink, `SYNC_*` env-var mapping and all logs/JSON/Prom names will only
respond to the `replicate` spelling. Plan the migration on your schedule.

## 1.16.x → 1.17.0

Purely additive. New operator-driven `/bin/restore` wrapper:

- Interactive on a TTY (`docker exec -ti …`); flag-driven otherwise.
- Mail / webhook notifications are on by default for restores (same
  `MAILX_RCPT`, `WEBHOOK_URL` plumbing as the cron-driven workers).
- New `/var/log/last-restore.json` summary, new
  `restic_restore_last_*` Prometheus gauges, optional
  `/hooks/{pre,post}-restore.sh`.

The manual `restic restore latest --target /restore` invocation still works
unchanged.

[Restore :material-arrow-right:](../operations/restore.md)

## 1.15.x → 1.16.0

Purely additive — no env rename, no behaviour change in cron workers.

- **SBOM** generation for image builds via `SBOM=ON ./build.sh` when
  `syft` is on `PATH`. Release CI also uploads source-tree SBOMs on tag
  releases.
- **`scripts/docker-compose.yml`** now ships two opt-in Compose profiles:
  `metrics` (node-exporter sidecar) and `dev` (mailhog SMTP catcher).
  Existing `docker compose up` invocations keep starting only the main
  service.
- **Multiple backup jobs pattern** at
  [`examples/compose/multi-job.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/compose/multi-job.yml).
- **Hardening section** in the README enumerates capabilities to drop and
  tmpfs paths needed for `read_only: true`.

## 1.14.x → 1.15.0

Purely additive.

- New opt-in `METRICS_DIR` exports Prometheus textfile metrics.
- New opt-in `SYNC_BISYNC_CHECK_ACCESS` (now `REPLICATE_BISYNC_CHECK_ACCESS`)
  appends `--check-access` to every routine bisync run and the recovery
  resync. Requires the well-known `RCLONE_TEST` marker on both endpoints;
  rclone aborts loudly when it's missing instead of treating one side as
  "everything deleted".
- Mail subjects gained the `[OK|FAIL N] <Job> <host> · <duration> · <details>`
  prefix; update any subject-based filter rules.
- Container logs now mask inline credentials in replicate source/destination
  URLs (`mask_endpoint`).

## 1.13.x → 1.14.0 :material-alert-octagon:{ title="Breaking" }

`RESTIC_TAG=""` (explicitly empty) is now a **hard failure** with exit code
`2`. Pick something meaningful (`daily`, `${HOSTNAME}-data`, …) so snapshots
can be filtered by tag later. The Dockerfile still defaults to `automated`,
so installs that never set `RESTIC_TAG` are unaffected.

Replicate job files gained optional `MODE` / `EXTRA_ARGS` columns; existing
two-column lines keep working as `bisync`.

## 1.11.x → 1.12.0+

Automatic `restic unlock` after backup / check failures is **opt-in** via
`RESTIC_AUTO_UNLOCK=ON`. The new default leaves the lock alone — safer for
repositories shared across multiple hosts where an automatic unlock could
clear another host's legitimate lock.

The `restic unlock --remove-all` call in `/entry.sh` after a failed
`restic init` is unaffected, because that lock can only have been created
by the failing init attempt itself.

[Troubleshooting :material-arrow-right:](../operations/troubleshooting.md)
