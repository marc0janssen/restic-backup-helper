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

## 3.1.0 → 3.2.0

Additive release with safer operational defaults.

- New `/bin/support-bundle` creates a redacted diagnostics tarball for
  support handoff.
- Worker `last-*.json` files now include the documented integer
  `started_epoch` and `finished_epoch` fields.
- Compose, Kubernetes examples and the Helm chart now use a local liveness
  probe (`test -f /var/log/cron.log && pidof crond >/dev/null`) instead of
  `restic cat config`. Keep repository reachability checks in readiness or
  external monitoring when you want alerts for remote outages.
- Tracked `config/rclone.conf` and `config/msmtprc` are now
  `config/rclone.conf.example` and `config/msmtprc.example`; real local
  files are gitignored.

Existing deployments keep working. If you used the repository's tracked
sample config files as writable local files, copy the new `.example` template
to the old local filename and keep your real file untracked.

## 2.x → 3.0.0 :material-alert-octagon:{ title="Breaking" } {#replicate-30-bridge}

The **replicate compatibility bridge** from the 2.0.0 rename is gone.

### What was removed

| Removed in 3.0.0 | Use instead |
| --- | --- |
| `SYNC_CRON` | `REPLICATE_CRON` |
| `SYNC_JOB_FILE` | `REPLICATE_JOB_FILE` |
| `SYNC_JOB_ARGS` | `REPLICATE_JOB_ARGS` |
| `SYNC_VERBOSE` | `REPLICATE_VERBOSE` |
| `SYNC_BISYNC_CHECK_ACCESS` | `REPLICATE_BISYNC_CHECK_ACCESS` |
| `/bin/bisync` (symlink) | `/bin/replicate` |

The image no longer maps `SYNC_*` at startup, and the Dockerfile no longer
declares those variables. If you still export only `SYNC_CRON`, replicate
will **not** schedule until you rename the variable.

### Upgrade checklist

1. **Search/replace** in every manifest: `SYNC_` → `REPLICATE_` (Compose,
   Kubernetes, Nomad, Ansible, `.env` files, CI secrets).
2. **Commands and probes** that invoked `/bin/bisync` → `/bin/replicate`.
3. **Pin a 3.x image tag** (`3.0.0-0.18.1` or newer) and roll out after a
   config-only change; rolling the image first without renaming env vars
   will silently disable replicate until `REPLICATE_*` is set.

The rclone job-file **`MODE`** value `bisync` is unchanged — only the
**shell entrypoint** name `/bin/bisync` is removed.

## 2.4.0 → 2.5.0

Multi-host retention hardening. Three composing changes, all backwards
compatible — single-host setups and operators who never touched
`RESTIC_FORGET_ARGS` see no behaviour change.

### 1. New standalone forget worker (`FORGET_CRON`)

`/bin/forget` is a new worker that mirrors the existing `/bin/prune`
shape: own `flock` on `/var/run/forget.lock`, own log
(`/var/log/forget-last.log`), own JSON summary
(`/var/log/last-forget.json`), own Prometheus textfile
(`restic_forget.prom`), own mail subject (`[OK|FAIL N] Forget …`),
own webhook payload, own `pre-forget` / `post-forget "$rc"` hooks. It
reuses `RESTIC_FORGET_ARGS` verbatim — no duplicate retention env
var.

Activate by setting `FORGET_CRON` (default: empty). When set,
`/bin/backup` **automatically skips** its inline post-backup forget
(cron log records `⏭ Skipping inline forget: FORGET_CRON is set …`)
so the repository's exclusive forget-lock is only ever taken inside
this dedicated maintenance window. Recommended for repositories
shared by multiple hosts: eliminates the exit-11 race entirely.

```yaml
environment:
  FORGET_CRON: "30 1 * * *"
  RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
```

See [Forget worker](../workers/forget.md) for the full state machine,
sample configurations and exit-code reference.

### 2. Soft-skip semantic for `restic forget` exit 11

On a repository shared by multiple hosts, two simultaneous backups
can race for the exclusive lock that `restic forget` needs. Only one
acquires it; the other returns restic exit `11` ("failed to lock
repository"). Until 2.4.0 the worker treated that as a hard failure
(`❌ Forget Failed with Status 11`) and, with `RESTIC_AUTO_UNLOCK=ON`,
would unlock the **other** host's legitimate lock — a foot-gun on
multi-host setups.

2.5.0 downgrades the exit-11 case to an informational skip in both
the inline path (`/bin/backup`) and the new standalone worker
(`/bin/forget`):

- Cron log records `⏭ Forget skipped: repository was locked by
  another host (exit 11). Retention will catch up on the next backup
  tick.`
- The backup itself still exits `0`; `last-backup.json` keeps
  `exit_code: 0`.
- `restic unlock` is **intentionally never** run on exit 11
  regardless of `RESTIC_AUTO_UNLOCK` (the lock we lost is another
  host's legitimate lock).
- All other non-zero forget exits keep their existing fail-loud
  handling.

### 3. `forget_exit_code` field in `last-backup.json`

The inline forget result is now recorded separately as
`forget_exit_code: <0|11|other>` alongside `exit_code` in
`last-backup.json`. The value is auto-promoted to a
`restic_backup_last_forget_exit_code` Prometheus gauge so monitoring
can alert on persistent skipping without false-flagging the backup
itself. (The standalone worker exposes the same number as its own
top-level `exit_code` plus a `restic_forget_last_exit_code` gauge.)

### Upgrade actions

- **Single host, no `RESTIC_FORGET_ARGS` set:** drop-in, nothing to
  change.
- **Single host, `RESTIC_FORGET_ARGS` set:** drop-in. Consider
  adding `--retry-lock=DURATION` if you ever expect to add a second
  host.
- **Multi-host, hitting `❌ Forget Failed with Status 11`:** the
  failures are now `⏭` skips automatically. For a permanent fix,
  pick one of:
    - **Best:** set `FORGET_CRON` on a single maintenance-owner
      container (or on each container with staggered times) and let
      the dedicated worker own the lock window.
    - Add `--retry-lock=5m` to `RESTIC_FORGET_ARGS`.
    - Stagger `BACKUP_CRON` between hosts.

See [Backup worker → Multi-host repositories and exit 11](../workers/backup.md#multi-host-repositories-and-exit-11)
for the full story.

## 2.3.x → 2.4.0

Purely additive. New `/bin/mount-snapshot` helper wraps `restic mount`
(FUSE) read-only under `/fusemount`, scoped to this container's
`--host "$HOSTNAME"` and `--tag "$RESTIC_TAG"` by default.

Defaults are designed for the common case "give me last night's
snapshot tree, scoped to this host": mounts on `/fusemount`
(container-internal by design, created at image build, never collides
with `/bin/restore` output or a host bind-mount on `/restore`).
Created if missing, must be empty unless `--force`. The helper refuses
`/data`, `BACKUP_ROOT_DIR` and other system/source directories
without `--force`, and registers an `EXIT` trap that calls
`fusermount -u` (with `umount` fallback) so SIGINT, SIGTERM or a
restic crash always unmounts cleanly.

Use `--repo-wide` to expose every snapshot, `--path` (repeatable) to
filter by snapshot path, and `--allow-other` when another UID (e.g. a
host bind-mount consumer) needs read access to the FUSE tree.

FUSE inside the container still requires `--cap-add SYS_ADMIN
--device /dev/fuse` (or the Kubernetes `securityContext` equivalents).
On Ubuntu/Debian hosts (Docker's default AppArmor profile) you also
need `--security-opt apparmor=unconfined` because the `docker-default`
profile denies `mount(2)` regardless of `CAP_SYS_ADMIN`; the helper
pre-flights this and aborts early with a precise hint if any one of
the four FUSE knobs is wrong.

!!! info "Default `--target` changed within the 2.4.0 development cycle"

    Earlier 2.4.0 development tags defaulted to `--target /restore`.
    The released 2.4.0 defaults to `--target /fusemount` to prevent
    collisions with `/bin/restore` and host bind-mounts. If you wired
    a workflow against the old default, pass `--target /restore`
    explicitly (or update your scripts to the new path).

It writes `/var/log/last-mount-snapshot.json`, supports
`pre/post-mount-snapshot` hooks, webhooks, mail and the
`restic_mount_snapshot.prom` Prometheus textfile.

[Mount snapshot :material-arrow-right:](../operations/mount-snapshot.md)

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
| `/bin/bisync` | `/bin/replicate` (throughout **2.x** only, a symlink to the same binary; **removed in 3.0.0**) |
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

### Historical note (2.x compatibility bridge)

From **2.0.0** through **2.x**, `/bin/bisync` was a symlink to `/bin/replicate`
and `SYNC_*` env vars were mapped to `REPLICATE_*` at startup with
deprecation warnings. **3.0.0 removes that bridge** — see
[2.x → 3.0.0](#replicate-30-bridge) above.

### What you must do (when upgrading from 1.x)

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

If you are reading this while already on **3.x**, step 1 is mandatory: `SYNC_*`
is ignored and `/bin/bisync` does not exist.

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
