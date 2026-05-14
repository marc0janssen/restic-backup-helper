# Changelog

## Restic Backup Helper

### 2.14.1-0.18.1 (2026-05-13)

Patch release: **`app/status.sh`** is reformatted with `shfmt` so
`./scripts/ci-quality-checks.sh` passes the `--diff` gate (empty
`"")` case arm in the `case` statement). No behaviour change.

### 2.14.0-0.18.1 (2026-05-13)

This release adds **`/bin/status`** (alias **`/bin/health-summary`**),
a fast daily operator summary that answers "is this container broadly
healthy?" without the depth or cost of `/bin/doctor`. It reads only
local state: release metadata, the rendered crontab (or environment
preview), known `/var/log/last-*.json` files and the ages / exit codes
for scheduled core jobs.

#### Added

- **`/bin/status` / `/bin/health-summary`: local-state health summary.**
  - Prints release, hostname, current time, masked repository,
    warnings/failures, schedule state and the latest core-job ages.
  - Reads `/var/log/last-*.json`, `/var/spool/cron/crontabs/root`
    (falling back to an env-derived cron preview), `RESTIC_*` release
    metadata and schedule env vars. It deliberately never runs
    `restic`, `rclone`, hooks, mail, webhooks or a repository probe.
  - Health rules are intentionally operator-friendly:
    - `OK`: all enabled core jobs have a successful recent JSON summary.
    - `WARN`: an enabled core job is missing a `last-*.json`, looks
      stale for a simple cron expression, or a non-scheduled helper JSON
      reports a non-zero exit.
    - `FAIL`: an enabled core job (`backup`, `check`, `forget`, `prune`,
      `replicate`) has a non-zero last exit code.
  - Staleness is applied only to simple cron expressions
    (`*/N * * * *`, `M */N * * *`, daily, weekly-ish and monthly-ish)
    with a threshold of three expected intervals plus ten minutes.
    Custom expressions still show age but do not trigger stale warnings.
  - Supports `--json` / `-j` with schema
    `restic-backup-helper.status/1`. The JSON includes `verdict`,
    `warnings`, `failures`, `runtime`, `crontab`, `schedules[]`,
    `jobs[]`, `recent_json[]` and compact `findings[]`. It is
    stdout-only and does **not** create `/var/log/last-status.json`, so
    asking for status does not mutate the local run history.
  - Exit code is `0` for `OK` / `WARN`, `1` for `FAIL`, and `2` for bad
    CLI usage.
- **Smoke-test coverage for `/bin/status`.**
  `scripts/ci-smoke-test.sh` now runs both text mode and the
  `/bin/health-summary --json` alias, asserting schema
  `restic-backup-helper.status/1`, `command == "status"`,
  `exit_code == 0`, `verdict in ("OK", "WARN")`, required typed
  sections, a present successful backup row, non-empty crontab and the
  expected 14 `recent_json[]` entries.

#### Changed

- **Entrypoint and image wiring.** `Dockerfile` copies
  `app/status.sh` to `/bin/status`, creates `/bin/health-summary` as a
  symlink alias and marks the helper executable. `/entry.sh` accepts
  `status`, `/bin/status`, `health-summary` and `/bin/health-summary`
  as one-shot subcommands.
- **Documentation.**
  - New **Operations → Status / health summary** page with health rules,
    examples, JSON schema and exit-code contract.
  - **Operations → Diagnostics** now positions `status` as the fast daily
    view, with `doctor` remaining the deeper support bundle and
    `cron-list` the schedule explanation.
  - **Reference → JSON summaries** documents `status --json` as a
    stdout-only command schema (not a new `last-*.json` file).
  - README / Docker Hub summary mention `/bin/status` and the
    `/bin/health-summary` alias.

#### Versioning

- This is a **MINOR** bump (2.13.0 → 2.14.0) because it adds a new
  operator-facing command, an entrypoint alias and a new machine-readable
  JSON schema. No existing contract is renamed or removed.

### 2.13.0-0.18.1 (2026-05-13)

This release adds **`/bin/restore-test`**, an explicit disaster-recovery
rehearsal helper that complements `restic check` (repository health) by
proving the **bytes can actually come back**: it restores a snapshot (or
a small canary sub-path) into an isolated temp directory, asserts the
restored tree is non-empty and optionally that one or more canary files
match a known SHA-256, then cleans up and emits the same audit surface
every other worker does (log + `last-*.json` + Prometheus + mail +
webhook + pre-/post hooks). Where `restic check` answers "the repo is
healthy", `restore-test` answers "I can really get my data back".

#### Added

- **`/bin/restore-test`: disaster-recovery rehearsal helper.**
  - Snapshot selection mirrors `/bin/restore`: `--id`, `--tag`,
    `--host`. Defaults to the literal `latest` for the container's
    `$HOSTNAME` and `$RESTIC_TAG`.
  - **Isolation by default.** Without `--target` the helper restores
    into `mktemp -d /tmp/restore-test.XXXXXX`. With `--target` it
    refuses to restore into `/`, `/data` or `BACKUP_ROOT_DIR`, and
    requires an empty directory unless `--force` is set.
  - **Scope knobs** for fast rehearsals on large repos: `--path PATH`
    (repeatable) restores a snapshot-absolute sub-path; `--verify`
    asks restic to check per-file hashes against the snapshot manifest
    during restore.
  - **Two-layer verification.** A file-count floor (`--min-files`,
    default `1`) catches "restore silently produced nothing"
    (e.g. `--path` typos against the snapshot tree). Per-file canary
    checksums (`--canary PATH=SHA256`, repeatable, or
    `--canary-file FILE` in the canonical `sha256sum` format) catch
    silent corruption that `restic check` would miss because the
    bytes are internally consistent but happen to be the wrong bytes.
  - **Bounded cleanup.** Auto-tempdirs (`/tmp/restore-test.XXXXXX`)
    are removed on exit unless `--keep` is set; operator-supplied
    targets are never auto-removed so a failing rehearsal stays on
    disk for inspection. The on-disk verdict is recorded in JSON as
    `cleanup_status` (`cleaned`, `kept`, `cleanup-failed`, `absent`).
  - **Dry-run mode** (`--dry-run`) calls `restic restore --dry-run`
    only, skips verification and tempdir creation, and still emits
    the full JSON / metrics / mail / webhook audit trail so CI can
    smoke-check the helper itself.
  - **Audit surface mirrors every other worker:**
    `/var/log/restore-test-last.log`, `/var/log/last-restore-test.json`
    (atomic temp-file write, includes a nested `canary_results[]`
    array post-appended in the same `sources_report.sh` style), and
    when `METRICS_DIR` is set, `restic_restore_test.prom` with the
    common envelope plus `restic_restore_test_last_canary_total`,
    `..._canary_passed`, `..._canary_failed`. Hooks
    `/hooks/pre-restore-test.sh` / `/hooks/post-restore-test.sh` are
    invoked through the standard `run_hook` plumbing, post-hook gets
    the helper exit code as `$1`. `notify_mail` /  `notify_webhook`
    fire with a one-line subject summarising file count and canary
    pass ratio.
  - **Environment-variable equivalents.** Every long-form CLI flag
    has a `RESTORE_TEST_*` env counterpart so Compose / Kubernetes
    manifests can configure the rehearsal without wrapping the
    helper: `RESTORE_TEST_PATH`, `RESTORE_TEST_TARGET`,
    `RESTORE_TEST_CANARY`, `RESTORE_TEST_CANARY_FILE`,
    `RESTORE_TEST_KEEP`, `RESTORE_TEST_MIN_FILES`,
    `RESTORE_TEST_VERIFY`.
  - **No `RESTORE_TEST_CRON` by design.** Restore rehearsals consume
    backend bandwidth and CPU; operators should opt in deliberately
    via a sidecar cron / Kubernetes `CronJob` / systemd timer
    invoking `docker exec restic-backup-helper /bin/restore-test`.
    The new documentation page (`docs/operations/restore-test.md`)
    explains cadence and canary recommendations.
- **Smoke-test coverage for the new helper.**
  `scripts/ci-smoke-test.sh` now seeds a real canary SHA-256 by
  hashing `/data/backup_src/smoke.txt` inside the container, runs
  `/bin/restore-test --min-files 1 --canary "...=<sha>"` and asserts
  the documented JSON schema: `verification == "passed"`,
  `files_restored >= 1`, `bytes_restored > 0`, `canary_total == 1`,
  `canary_passed == 1`, `canary_failed == 0`,
  `target_autotmp == "ON"`, `cleanup_status == "cleaned"`, and that
  the nested `canary_results[0].status == "passed"`. A second pass
  exercises `--dry-run` and asserts `verification == "skipped"`,
  so both the verifying and the non-verifying paths are protected
  against regression. The `doctor --json` assertion was bumped
  accordingly (`recent_json[]` length 13 → 14).

#### Changed

- **`/bin/doctor` enumerates the new helper.** `recent_json[]` now
  surfaces `/var/log/last-restore-test.json`, and the hook-phase
  enumeration lists `pre-restore-test` / `post-restore-test` alongside
  the existing helpers so the doctor output stays a single source of
  truth for "which helpers does this image know about".
- **Documentation, navigation and references updated.**
  - New page **Operations → Restore test (DR rehearsal)** in
    `mkdocs.yml`.
  - **Configuration → Environment variables**: dedicated
    *Restore test (disaster-recovery rehearsal)* section listing
    every `RESTORE_TEST_*` knob.
  - **Configuration → Hooks**: `pre-restore-test` /
    `post-restore-test` rows added.
  - **Configuration → Prometheus metrics** and
    **Reference → Prometheus metrics**: `restic_restore_test.prom`
    listed alongside the other helper-specific textfiles; new
    `_canary_total/_passed/_failed` gauges documented; PromQL recipe
    "Restore rehearsal stale" added.
  - **Reference → JSON summaries**: `restore-test` added to the
    `job` enumeration and a full table documenting every field on
    `last-restore-test.json`, including the nested
    `canary_results[]` array.
  - **Operations → Diagnostics (doctor)**: mermaid diagram, recent
    JSON list and example hook output updated; "See also" cross-link
    to Restore test added.

#### Versioning

- This is a **MINOR** bump (2.12.1 → 2.13.0) because it adds a new
  operator-facing helper, new environment variables, new hook phases,
  new JSON / Prometheus surface and new documentation. No existing
  contract is renamed or removed; everything is additive.

### 2.12.1-0.18.1 (2026-05-13)

This patch release expands the **runtime smoke test** so it now exercises
every recently-added operator helper in CI, not just the original
`backup` / `check` / `replicate` / `rotate_log` quartet. The image
binary contents are unchanged; this is a test-coverage release that
catches regressions in the helper-script surface earlier.

#### Changed

- **`scripts/ci-smoke-test.sh` now covers the operator helper surface.**
  Each new step is run end-to-end against the live smoke stack (so it
  drives the actual `/bin/*` entrypoint dispatch, hooks, JSON summary
  writers and exit-code contracts), and every helper's `last-*.json`
  is parsed on the host with `python3` to assert the documented schema.
  Added steps, in execution order:
  - `cron-list` — invoked twice. Once via `docker compose run --rm`
    (env-preview / no-tty path: only `BACKUP_CRON`-shaped rows expected)
    and once via `docker compose exec` on the long-running container
    (rendered-crontab path: full `/var/spool/cron/crontabs/root`).
  - `config-check --json` — schema = `restic-backup-helper.config-check/1`,
    `exit_code == 0`, `errors == 0`, and the required check keys
    (`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `RESTIC_TAG`, `BACKUP_PATHS`)
    must be present in the flat `checks[]` array.
  - `doctor --json` — schema = `restic-backup-helper.doctor/1`,
    `exit_code == 0`, all six typed sections (`runtime`, `environment`,
    `repository_probe`, `replicate`, `hooks`, `recent_json`) plus the
    flat `checks[]` array must be present, `repository_probe.status`
    must be `ok` (so we know the probe ran against the seeded repo)
    and `recent_json[]` must enumerate exactly 13 known `last-*.json`
    paths.
  - `sources-report` — runs `/bin/sources-report` once and then asserts
    `last-sources-report.json` has `sources_count >= 1` and
    `total_files >= 1` for the seeded `/data/backup_src` source.
  - `forget-preview` — runs the host/tag-scoped dry-run with the
    smoke-test container hostname + `RESTIC_TAG=ci-smoke` and asserts
    `last-forget-preview.json` reports `exit_code == 0`.
  - `init-repo --dry-run --yes` — exercises the already-exists branch
    (the smoke stack auto-inits at startup), asserts `exit_code == 0`,
    `dry_run == "ON"` and `repo_existed == "true"` in
    `last-init-repo.json`. Confirms the helper does NOT mutate an
    existing repo in dry-run.
  - `notify-test --all --dry-run` — invoked with ephemeral
    `MAILX_RCPT=ops@smoke.invalid` and
    `WEBHOOK_URL=https://webhook.smoke.invalid/test` passed via
    `docker compose exec -e` so the helper has both targets configured
    without leaking those values into the long-running compose
    environment. `last-notify-test.json` must report
    `mail_result == "dry-run"` and `webhook_result == "dry-run"` so
    we know neither `mailx` nor `curl` was actually invoked.
  - `restore --dry-run --yes --target /tmp/restore-smoke` — runs the
    latest snapshot through `restic restore --dry-run`, asserts
    `last-restore.json` reports `exit_code == 0` and `dry_run == "ON"`.
    The smoke test creates the target dir inline so the
    `non-empty-target` refusal path stays untouched.
  - `snapshot-export --dry-run` — invokes the latest-snapshot export
    in dry-run mode, asserts `last-snapshot-export.json` reports
    `exit_code == 0` and `dry_run == "ON"`. Confirms no `.tar.gz` is
    written even though the planned archive path is still recorded.
- **`RESTIC_REPOSITORY_FILE` precedence is now smoke-tested explicitly.**
  After the operator-helper sweep the smoke test seeds a temporary
  `/data/repo.url` file (header comment + actual URL on the second
  line so the parser's "first non-blank, non-comment" rule is also
  exercised) and runs `config-check --json` via
  `docker compose run --rm --no-deps -e RESTIC_REPOSITORY= -e
  RESTIC_REPOSITORY_FILE=/data/repo.url`. The assertions confirm that
  the resolver inside `lib.sh::resolve_restic_repository_file`
  promotes the file's content into `RESTIC_REPOSITORY` (the
  `RESTIC_REPOSITORY` check status is `ok` and its message contains
  `/data/repo`) AND unsets `RESTIC_REPOSITORY_FILE` before validation
  runs (no `RESTIC_REPOSITORY_FILE` check appears in `checks[]`). This
  is the regression test for the `Options --repo and
  --repository-file are mutually exclusive` symptom fixed in 2.11.0.
- **JSON assertions run on the host, not in the container.** The
  Alpine-based `restic/restic` base does not ship Python, so the new
  steps `cat /var/log/last-<job>.json` out via `docker compose exec`
  and pipe the body into a host-side `python3 -c '…'` block (Python
  3.8+ compatible, no f-string-with-backslash gotchas). This keeps
  the image footprint unchanged while still letting CI assert on
  structured fields.

#### Notes

- The smoke test still tears the stack down on exit (or keeps it up
  when `KEEP_SMOKE_STACK=yes` is set, unchanged) and the failure-path
  artifact upload (`smoke-failure-logs.txt` / `smoke-failure-ps.txt`)
  also captures the new steps' stdout/stderr automatically.
- No `app/` script, Dockerfile layer, README user-facing instruction
  or environment-variable contract changed in this release — only
  `scripts/ci-smoke-test.sh`, `VERSION`, `CHANGELOG.md`,
  `README.md` and `README-containers.md`, plus the bulk current-release
  string update across docs and examples.

### 2.12.0-0.18.1 (2026-05-13)

This release adds **machine-readable diagnostics**: both `/bin/doctor` and
`config-check` now accept `--json` (alias `-j`) and emit a single JSON
document on stdout in addition to the usual text mode. CI pipelines,
Kubernetes init-container readiness probes and external monitoring no
longer have to regex-parse `[OK] / [WARN] / [FAIL]` lines — they can
gate on `.exit_code == 0` or drill into `.checks[] | select(.status=="fail")`
just like they already do for the per-worker `last-*.json` files. The
text-mode behaviour is unchanged; the JSON path is fed by the same
internal accumulators so the two surfaces always report the same set of
findings.

#### Added

- **`doctor --json` (schema `restic-backup-helper.doctor/1`).** Emits a
  single JSON envelope (`schema`, `command`, `release`, `hostname`,
  `generated_at`, `generated_epoch`, `warnings`, `errors`, `exit_code`)
  plus six typed sections so dashboards can pin individual fields:
  - `runtime{}` — `restic_version`, `rclone_version`, `bash_version`,
    `release`, `hostname`, `date`, `timezone`.
  - `environment{}` — masked key/value map of every variable shown in
    the text-mode `== Effective environment ==` section. Passwords are
    rendered as `"<set, hidden>"` / `"<empty>"`; repository URLs go
    through `mask_repository`; webhook URLs through `mask_webhook_url`.
  - `repository_probe{}` — `{status: "ok"|"fail"|"skipped",
    repository: "<masked URL>", restic_exit_code: <int|null>}`. Mirrors
    the non-mutating `restic cat config` probe, never runs
    `restic init`.
  - `replicate{effective, jobs_count, malformed_count}` — effective
    `REPLICATE_*` values (legacy `SYNC_*` mapping already applied) and
    a count of valid vs. malformed rows in `REPLICATE_JOB_FILE`.
  - `hooks{hook_timeout, directory_mounted, present[{phase, executable}]}`
    — every hook that actually exists on disk, with its executable bit.
  - `recent_json[]` — one `{path, present, size_bytes}` per known
    `last-*.json` (`backup`, `check`, `prune`, `forget`, `replicate`,
    `restore`, `snapshot-export`, `forget-preview`, `mount-snapshot`,
    `unlock`, `sources-report`, `init-repo`, `notify-test`). The file
    body is intentionally not inlined — consumers fetch it directly
    when interested.
  - `checks[]` — flat array of every `[INFO] / [OK] / [WARN] / [FAIL]`
    finding emitted in text mode, tagged with the section it came from
    (`Runtime`, `Effective environment`, `Configuration checks`,
    `Repository probe`, `Replicate`, `Hooks`, `Recent JSON summaries`,
    `Summary`). `status` ∈ `info`, `ok`, `warn`, `fail`.
- **`config-check --json` (schema
  `restic-backup-helper.config-check/1`).** Lean envelope designed for
  Kubernetes init-container readiness probes and CI gates — no
  repository probe, no environment dump, just the validation findings:
  `checks[] = [{key, status, message}, …]` plus the common envelope
  fields. `key` is a stable identifier (`RESTIC_REPOSITORY`,
  `RESTIC_PASSWORD`, `RESTIC_TAG`, `BACKUP_PATHS`, `RCLONE_CONFIG`,
  `REPLICATE_JOB_FILE`, `RESTIC_CACERT`, `RESTIC_REPOSITORY_FILE`) so
  alerts can be wired without parsing message text.
- **Same exit-code contract as text mode.** Both `--json` modes return
  `0` when no errors were recorded and `1` otherwise, matching the
  pre-existing text-mode behaviour. Existing shell wrappers that check
  the exit code of `doctor` / `config-check` continue to work; only
  consumers that scrape the output need to switch.

#### Documentation

- **Operations → Diagnostics** now documents the `--json` flag, both
  schemas, the full field reference, the stability promise (MINOR
  bumps add fields, MAJOR bumps rename/remove), an example output and
  three `jq` one-liners (`exit_code == 0`, masked repository URL,
  Kubernetes readiness probe).

#### Notes

- Strictly additive change. The text output of `doctor` and
  `config-check` is byte-for-byte unchanged (the JSON path is fed from
  the same accumulators); existing dashboards / Loki queries / support
  bundles continue to work.

### 2.11.0-0.18.1 (2026-05-13)

This release promotes `RESTIC_REPOSITORY_FILE` to a first-class alternative
to `RESTIC_REPOSITORY`, matching restic's native precedence model for
`RESTIC_PASSWORD_FILE`. The image used to bake
`ENV RESTIC_REPOSITORY=/mnt/restic` in the Dockerfile, so a compose file
that set only `RESTIC_REPOSITORY_FILE` ended up with both env vars
populated and the entrypoint banner / repository probe printed the
literal `/mnt/restic` default; downstream restic invocations would have
aborted with `Options --repo and --repository-file are mutually
exclusive`. The helper now reads the file at startup, promotes its first
non-blank, non-comment line into `RESTIC_REPOSITORY`, and unsets
`RESTIC_REPOSITORY_FILE` so every consumer — banner, probe, cron-driven
workers and restic itself — observes a single coherent value.

#### Added

- **`RESTIC_REPOSITORY_FILE` first-class support.** New
  `resolve_restic_repository_file` helper in `app/lib.sh` runs as a
  side-effect when `lib.sh` is sourced and:
  - Reads the first non-blank, non-comment line of the file with
    leading/trailing whitespace and an optional trailing CR stripped.
    Lines starting with `#` (after optional whitespace) are treated as
    comments.
  - Promotes the line into `RESTIC_REPOSITORY` and unsets
    `RESTIC_REPOSITORY_FILE` on success, so the rest of the runtime
    (entrypoint banner, `restic cat config` probe, all
    cron-driven workers and operator helpers like `/bin/doctor`,
    `/bin/init-repo`, `/bin/sources-report`) observes the resolved URL
    and restic no longer fails with
    `Options --repo and --repository-file are mutually exclusive`.
  - Emits a single stderr warning when both `RESTIC_REPOSITORY` is set
    to a non-default value and `RESTIC_REPOSITORY_FILE` is present, so
    the override is visible in `cron.log` / `docker logs`.
  - Leaves both env vars untouched and emits a warning when the file is
    unreadable or empty/comments-only, so `config-check` / `/bin/doctor`
    can surface the misconfiguration with their usual context.
- **`config-check` and `/bin/doctor` understand
  `RESTIC_REPOSITORY_FILE`.** `config-check` accepts the file as a valid
  source for the repository and reports the specific reason when
  promotion failed (unreadable path vs. blank/comments-only). `/bin/doctor`
  shows `RESTIC_REPOSITORY_FILE` in its `Effective environment` section
  and reuses the same diagnostic when the file is set but unusable.

#### Fixed

- The entrypoint startup banner
  (`✅ Assuming repository '…' is online…`) and the `restic cat config`
  probe now print the masked resolved repository URL instead of the
  image-baked `/mnt/restic` default when `RESTIC_REPOSITORY_FILE` is
  configured.

#### Documentation

- Added a full `RESTIC_REPOSITORY_FILE` row to
  [`docs/configuration/environment-variables.md`](https://marc0janssen.github.io/restic-backup-helper/configuration/environment-variables.html)
  covering parsing rules, precedence vs. `RESTIC_REPOSITORY`,
  the post-promotion `unset` behaviour and how `config-check` /
  `/bin/doctor` diagnose misconfiguration.
- `examples/compose/cloud-reference.yml` now shows
  `RESTIC_REPOSITORY_FILE` as a commented-out alternative next to
  `RESTIC_PASSWORD_FILE`, so operators have a copy-paste-ready pattern
  for hiding `rest:https://user:pass@host` URLs from `docker inspect`.

#### Notes

- No new environment variables beyond `RESTIC_REPOSITORY_FILE`
  itself (which was already supported by upstream restic and read by
  the workers indirectly; the helper now makes the precedence explicit
  and observable in logs).
- `app/lib.sh` now has a single intentional side effect on source:
  `resolve_restic_repository_file` is invoked at the bottom of the
  file. Documented prominently in the lib.sh header so future
  maintainers do not consider it surprising.
- Internal SemVer policy: MINOR rather than PATCH because the
  entrypoint behaviour changes for any compose file that sets
  `RESTIC_REPOSITORY_FILE` (banner output, probe target, post-startup
  env layout). No breaking change for existing `RESTIC_REPOSITORY`-only
  deployments.

### 2.10.1-0.18.1 (2026-05-13)

This patch tightens observability and documentation around the shared
notification / metrics helpers.

#### Fixed

- Prometheus textfile metrics now escape the `hostname` label before
  writing `restic_<job>.prom`, so unusual container hostnames containing
  quotes, backslashes or newlines cannot produce invalid textfile output.
- Prometheus textfile metrics now also emit the documented
  `restic_<job>_last_started_timestamp` gauge alongside the existing
  finished timestamp.
- The `notify_webhook` helper comment now matches the actual helper
  contract: it returns curl's status for callers that need it, while
  cron-driven workers explicitly keep webhook delivery failures from
  changing the worker exit code.

#### Documentation

- Clarified that `RESTIC_JOB_ARGS`, `RESTIC_CHECK_ARGS`,
  `RESTIC_FORGET_ARGS`, `RESTIC_PRUNE_ARGS`, `RESTIC_INIT_ARGS`,
  `REPLICATE_JOB_ARGS` and replicate per-job `EXTRA_ARGS` are
  whitespace-split argument strings, not a shell parser. Keep paths/values
  free of spaces, or use file-based inputs such as `--files-from`,
  `--exclude-file` or rclone config files.

### 2.10.0-0.18.1 (2026-05-13)

This release adds a first-class notification plumbing test so operators
can validate SMTP and webhook configuration before waiting for a real
backup failure. `/bin/notify-test` sends clearly-labelled mail and/or
webhook notifications through the same `notify_mail` / `notify_webhook`
helpers used by real jobs, but unlike real jobs, delivery failures
affect the helper exit code so CI and manual smoke tests can catch bad
`msmtprc`, `MAILX_RCPT`, `WEBHOOK_URL`, auth headers and timeout
settings.

#### Added

- **`/bin/notify-test` operator-driven mail/webhook test.** Default
  mode sends to every configured target (`MAILX_RCPT` and/or
  `WEBHOOK_URL`); `--mail`, `--webhook` and `--all` select a narrower
  or stricter target set. `--dry-run` prints what would be sent without
  invoking `mail` or `curl`, while still writing JSON / metrics /
  hooks. `--subject TEXT` and `--message TEXT` let operators label the
  test. The helper intentionally forces the test delivery to send even
  when `MAILX_ON_ERROR=ON` / `WEBHOOK_ON_ERROR=ON`, while preserving
  those original policy values in logs and JSON. Emits the standard
  worker surface: `/var/log/notify-test-last.log`,
  `/var/log/notify-test-mail-last.log`,
  `/var/log/last-notify-test.json` (target mode, requested/configured
  targets, delivery results, raw mail/webhook return codes, masked
  webhook URL, auth-header-present flag, timeout, subject/message),
  `restic_notify_test.prom` when `METRICS_DIR` is set, plus
  `pre-notify-test` / `post-notify-test "$rc"` hooks. Reachable via
  `docker exec … /bin/notify-test` and the entrypoint shortcut
  `docker run … notify-test`.
- **Documentation: `/bin/notify-test` operations page**
  ([`docs/operations/notify-test.md`](https://marc0janssen.github.io/restic-backup-helper/operations/notify-test.html))
  with quick-start examples, target-selection rules, dry-run behaviour,
  JSON schema, exit-code table and cross-links from mail/webhook
  configuration, manual runs, hooks and reference pages.

#### Notes

- No new environment variables; `/bin/notify-test` reuses
  `MAILX_RCPT`, `MAILX_ON_ERROR`, `WEBHOOK_URL`,
  `WEBHOOK_HEADER_AUTH`, `WEBHOOK_TIMEOUT`, `WEBHOOK_ON_ERROR`,
  `METRICS_DIR` and `HOOK_TIMEOUT`.
- Exit codes: `0` (requested test notification(s) delivered, or
  dry-run completed), `1` (at least one requested delivery failed),
  `2` (configuration / argument error such as no targets or missing
  requested target).
- Internal SemVer policy: MINOR rather than PATCH because
  `/bin/notify-test` is a new in-container helper with its own JSON
  schema, Prometheus textfile and hook family.

### 2.9.0-0.18.1 (2026-05-13)

This release adds an **audited operator counterpart** to the entrypoint
auto-init probe (`RESTIC_CHECK_REPOSITORY_STATUS`). Operators who keep
the probe disabled — the recommended posture on shared remotes where a
transient TLS / DNS / auth hiccup must never look like "repo doesn't
exist, let's call init" — now have a first-class bootstrap command that
runs the same probe explicitly, prints the planned `restic init`
command, requires a typed confirmation (or `--yes`) and writes the
familiar log / JSON / metrics / mail / webhook / hook surface.

#### Added

- **`/bin/init-repo` operator-driven bootstrap wrapper.**
  Explicit `restic init` with a pre-flight `restic cat config` probe
  (the same exit-10 contract the entrypoint uses) so an existing
  repository is never accidentally re-initialised. `--dry-run` prints
  the masked repository URL, the resolved init flags, and a one-line
  verdict (`would CREATE` / `would REFUSE — already exists` / probe
  error) without mutating anything; the JSON / Prometheus / mail /
  webhook / hook artefacts are still emitted so monitoring stays
  consistent. Without `--dry-run` the helper requires either an
  interactive TTY plus a typed-word confirmation (`init`) or an
  explicit `--yes` / `-y` flag — without one of those, a non-TTY run
  aborts with exit `2` to prevent surprise init runs from a container
  restart or CI replay. Extra restic-init flags come from the new
  `RESTIC_INIT_ARGS` env var (shell-word split, analogous to
  `RESTIC_FORGET_ARGS` / `RESTIC_PRUNE_ARGS`) and from any positional
  arguments after `--`. Emits the standard worker surface:
  `/var/log/init-repo-last.log`, `/var/log/last-init-repo.json` (with
  `dry_run`, `assume_yes`, `confirmed`, `repo_existed`,
  `probe_exit_code`, `init_args`), `restic_init_repo.prom` when
  `METRICS_DIR` is set, mail subject (`[OK|FAIL N] Init-repo …`) and
  webhook payload, plus `pre-init-repo` / `post-init-repo "$rc"`
  hooks. Reachable via `docker exec … /bin/init-repo` and the
  entrypoint shortcut `docker run … init-repo`. Registered in
  `/bin/doctor` alongside the other hook families and JSON
  summaries; `RESTIC_INIT_ARGS` joins the masked-env table dumped by
  doctor.
- **`RESTIC_INIT_ARGS` env-var.** Stable knob for repository version
  pinning (`--repository-version=2`) or chunker matching
  (`--copy-chunker-params=<path>`) at create time. Only consulted by
  `/bin/init-repo`; the cron-driven workers ignore it.
- **Documentation: `/bin/init-repo` operations page**
  ([`docs/operations/init-repo.md`](https://marc0janssen.github.io/restic-backup-helper/operations/init-repo.html))
  with mermaid flowchart, probe-verdict matrix, the
  type-to-confirm prompt rendering, dry-run output anatomy, JSON
  schema and cross-links from
  [Manual runs](https://marc0janssen.github.io/restic-backup-helper/operations/manual-runs.html),
  [Diagnostics](https://marc0janssen.github.io/restic-backup-helper/operations/diagnostics.html),
  [Environment variables](https://marc0janssen.github.io/restic-backup-helper/configuration/environment-variables.html),
  [Hooks](https://marc0janssen.github.io/restic-backup-helper/configuration/hooks.html)
  and the JSON / Prometheus reference pages.

#### Notes

- No behaviour change for the entrypoint auto-init probe. The new
  helper is purely additive; `RESTIC_CHECK_REPOSITORY_STATUS=ON`
  keeps its existing semantics. The recommended deployment pattern
  on shared remotes is now `RESTIC_CHECK_REPOSITORY_STATUS=OFF` plus
  a one-shot `/bin/init-repo --yes` (or interactive `/bin/init-repo`)
  for the first bootstrap.
- Exit codes:
  `0` (init succeeded, dry-run completed, or operator cancelled at
  the prompt), `1` (real `restic init` failure), `2` (configuration
  error: missing env, no TTY without `--yes`, wrong password / other
  probe error), `3` (repository already exists — idempotent, no
  mutation attempted).
- Internal SemVer policy: MINOR rather than PATCH because
  `/bin/init-repo` is a new in-container helper with its own JSON
  schema, Prometheus textfile, hook family and a new public env-var
  (`RESTIC_INIT_ARGS`).

### 2.8.0-0.18.1 (2026-05-13)

This release adds a **pre-flight source inventory** so operators can
answer "what will actually get backed up next tick?" without taking a
repository lock or running a probe backup. `/bin/sources-report` reads
`BACKUP_ROOT_DIR` and parses every `--files-from` / `--exclude-file`
reference out of `RESTIC_JOB_ARGS`, then reports readability, type,
file count and (optional) size per source plus pattern counts and
missing-entry counts per files-from / exclude-file. Catches the four
silent-drift failure modes that doctor's boolean readability check
cannot: missing mounts that look "fine, just smaller", stale entries
inside `--files-from` files, mistyped exclude-file paths that restic
silently treats as "no excludes", and host-migration mismatches where
the path list inherited from another host doesn't resolve yet.

#### Added

- **`/bin/sources-report` operator-driven pre-flight inventory.**
  Read-only. Default scope is the exact same contract `/bin/backup`
  feeds restic: `BACKUP_ROOT_DIR` (positional path) plus every
  `--files-from`, `--files-from-verbatim`, `--files-from-raw`,
  `--exclude-file` and `--iexclude-file` discovered inside
  `RESTIC_JOB_ARGS`. The CLI adds `--source PATH` and `--files-from
  FILE` for ad-hoc inspection (repeatable); `--no-size` skips the
  `du -sk` / `find -type f` probes for slow / remote sources;
  `--depth N` caps directory traversal depth. Emits the standard
  worker surface: human-readable `/var/log/sources-report-last.log`
  with per-source / per-files-from / per-exclude-file tables;
  `/var/log/last-sources-report.json` with flat aggregates plus
  nested `sources`, `files_from` and `exclude_files` arrays (each
  source carries `{path, readable, type, files, bytes}`; each
  files-from carries `{path, readable, lines, missing_entries}`);
  `restic_sources_report.prom` when `METRICS_DIR` is set; mail
  subject (`[OK|FAIL N] Sources report …`) and webhook payload; the
  `pre-sources-report` / `post-sources-report "$rc"` hook pair.
  Reachable via `docker exec … /bin/sources-report` and the
  entrypoint shortcut `docker run … sources-report`. Registered in
  `/bin/doctor` alongside the other hook families and JSON
  summaries. The size figure is intentionally **unfiltered**
  (`du -sk` without applying restic excludes); exclude files are
  inventoried separately so operators can reason about expected
  exclusions without this helper having to re-implement restic's
  matcher.
- **`collect_arg_paths` helper promoted to `app/lib.sh`.**
  Internal: the RESTIC_JOB_ARGS parser previously private to
  `/bin/doctor` is now a library function shared with
  `/bin/sources-report`, so both helpers tokenise `--files-from`
  and `--exclude-file` identically. Pure refactor; no behaviour
  change for `/bin/doctor`.
- **Documentation: `/bin/sources-report` operations page**
  ([`docs/operations/sources-report.md`](https://marc0janssen.github.io/restic-backup-helper/operations/sources-report.html))
  with mermaid flowchart, scope discovery semantics, estimate
  caveats (size is unfiltered; exclude-file inventory is separate),
  JSON schema, exit-code table and cross-links from
  [Backup worker](https://marc0janssen.github.io/restic-backup-helper/workers/backup.html),
  [Manual runs](https://marc0janssen.github.io/restic-backup-helper/operations/manual-runs.html),
  [Diagnostics](https://marc0janssen.github.io/restic-backup-helper/operations/diagnostics.html),
  [Environment variables](https://marc0janssen.github.io/restic-backup-helper/configuration/environment-variables.html),
  [Hooks](https://marc0janssen.github.io/restic-backup-helper/configuration/hooks.html)
  and the JSON / Prometheus reference pages.

#### Notes

- No new environment variables; `/bin/sources-report` reuses
  `BACKUP_ROOT_DIR`, `RESTIC_JOB_ARGS`, `MAILX_*`, `WEBHOOK_*`,
  `METRICS_DIR` and `HOOK_TIMEOUT` exactly like the other operator
  wrappers.
- Exit code is `0` even when individual sources are unreadable; the
  `errors_count` aggregate (and the per-row `readable` flags in the
  JSON) carry that signal. Wire alerts on
  `restic_sources_report_last_errors_count > 0` for loud CI
  behaviour. The non-zero exit `2` is reserved for configuration
  errors (no sources to inspect, invalid `--depth`).
- Internal SemVer policy: MINOR rather than PATCH because
  `/bin/sources-report` is a new in-container helper with its own
  JSON schema (including nested `sources` / `files_from` /
  `exclude_files` arrays), Prometheus textfile and hook family.

### 2.7.0-0.18.1 (2026-05-13)

This release adds an audited operator counterpart to the safer
`RESTIC_AUTO_UNLOCK=OFF` default: `/bin/unlock`. The workers still
never auto-clear repository locks on failure (so a multi-host
deployment can't silently wipe another host's legitimate exclusive
lock), and operators now have a first-class wrapper to clear a stale
lock once they have independently confirmed it.

#### Added

- **`/bin/unlock` operator-driven manual `restic unlock` wrapper.**
  Pairs with the safer `RESTIC_AUTO_UNLOCK=OFF` default (which has
  not auto-cleared locks on worker failure since 1.12.0): when a job
  fails because the repository is locked, the helper logs a hint and
  lets the operator decide whether the lock is stale or legitimate.
  `/bin/unlock` removes stale **exclusive** locks by default
  (matching `restic unlock` 0.13+ semantics); `--remove-all` widens
  to non-exclusive locks too (use only when no concurrent reader is
  in flight); `--dry-run` lists current locks via `restic list
  locks` without invoking `restic unlock`. Emits the standard
  worker surface: masked `/var/log/unlock-last.log`,
  `/var/log/last-unlock.json` (with `remove_all`, `dry_run`,
  `locks_before`, `locks_after`), `restic_unlock.prom` when
  `METRICS_DIR` is set, mail subject (`[OK|FAIL N] Unlock …`) and
  webhook payload, plus `pre-unlock` / `post-unlock "$rc"` hook
  pair. Reachable via `docker exec … /bin/unlock` and the
  entrypoint shortcut `docker run … unlock`. Registered in
  `/bin/doctor` alongside the other hook families and JSON
  summaries.
- **Documentation: `/bin/unlock` operations page**
  ([`docs/operations/unlock.md`](https://marc0janssen.github.io/restic-backup-helper/operations/unlock.html))
  with mermaid state machine, when-to-use / when-not-to-use
  guidance, dry-run / remove-all recipes, and cross-links from
  [Backup → multi-host repositories and exit 11](https://marc0janssen.github.io/restic-backup-helper/workers/backup.html#restic-auto-unlock),
  [Forget worker](https://marc0janssen.github.io/restic-backup-helper/workers/forget.html),
  [Troubleshooting](https://marc0janssen.github.io/restic-backup-helper/operations/troubleshooting.html)
  and the JSON / Prometheus reference pages.

#### Notes

- No new environment variables; `/bin/unlock` reuses
  `RESTIC_REPOSITORY`, `RESTIC_PASSWORD[_FILE]`, `RESTIC_CACERT`,
  `MAILX_*`, `WEBHOOK_*`, `METRICS_DIR` and `HOOK_TIMEOUT` exactly
  like the other operator wrappers.
- `RESTIC_AUTO_UNLOCK=OFF` remains the default and is **not**
  changed by this release. `/bin/unlock` is the audited operator
  path, not an automatic one.
- Internal SemVer policy: MINOR rather than PATCH because
  `/bin/unlock` is a new in-container helper with its own JSON
  schema, Prometheus textfile and hook family.

### 2.6.0-0.18.1 (2026-05-13)

This release focuses on operator ergonomics and build-time tooling on
top of the 2.5.0 retention work: a read-only `/bin/cron-list`
schedule inspector inside the container, and a fully reworked `--base
<restic-tag>` CLI flow for the build scripts (Docker Hub-aware
resolution of `newest` / `prerelease`, existence verification before
any file is mutated, and a drift-fix in the private-registry build
script). No behavioural changes to the backup, forget, prune, check
or replicate workers — those keep 2.5.0 semantics byte-for-byte.

#### Added

- **`/bin/cron-list` read-only schedule inspector.** Prints `TZ`, the
  current container time, the rendered root crontab from
  `/var/spool/cron/crontabs/root` when present (or an environment
  preview before cron starts), and a readable per-job summary for
  `backup`, `check`, `replicate`, `forget`, `prune` and
  `rotate_log`. Available via `docker exec … /bin/cron-list` and the
  entrypoint shortcut `docker run … cron-list`.

#### Changed

- **Build scripts accept `--base <restic-tag>`.** `./build.sh`,
  `./build-testing.sh` and `./build-testing-local.sh` now support a
  CLI override for `VERSION_RESTIC` (also accepted as
  `--base=<restic-tag>`), matching the build-script ergonomics used in
  `nzbgetvpn`. Precedence remains CLI > non-empty exported variables >
  env file > defaults. This is a per-build override only: the scripts
  still do not bump `VERSION` or rewrite README release metadata; use
  `scripts/update-restic-base.sh` for the full Restic-base release bump.
  `--base` (and `VERSION_RESTIC` from env) is validated as a concrete
  Restic version like `0.18.1` (optional pre-release suffix allowed).
  The sentinel value **`newest`** (alias **`latest`**) is resolved to
  the concrete version inside `restic/restic:latest` via
  `docker run --rm restic/restic:latest version` **before** the image
  tag, Dockerfile FROM rewrite or build-arg is computed, so a
  published tag can never contain the literal `newest` or `latest`.
  For beta/rc bases, **`--base prerelease`** (aliases **`rc`** /
  **`beta`**) resolves via the Docker Hub `restic/restic` tags API to
  the newest published image tag that looks like a Restic rc/beta
  version, then uses that concrete version everywhere. Any other
  non-version input hard-fails up front with a clear error.
- **`--base <tag>` is verified against Docker Hub before any files
  are mutated.** After resolving `newest` / `latest` /
  `prerelease` / `rc` / `beta` (and after the format check),
  `finalize_restic_base_tag` calls
  `docker buildx imagetools inspect restic/restic:<tag>`; if the
  tag does not exist (typo, future version, removed tag), the build
  aborts with a clear error **before** the Dockerfile is rewritten
  or the image tag is computed. Closes the failure mode where a
  non-existent `--base 0.19.0` would still produce a published
  image tagged `…-0.19.0-dev` while the base layer was silently the
  previously-pulled `restic/restic:0.18.1`.
- **`./build-testing-local.sh` now patches `Dockerfile FROM` to
  match `--base` / `VERSION_RESTIC`** (already the behaviour of
  `./build.sh` and `./build-testing.sh`). Previously the
  private-registry script left `Dockerfile FROM` untouched, so
  `--base 0.18.2` would build against whatever the Dockerfile
  already pointed at while still tagging the pushed image
  `…-0.18.2-dev` — a silent drift between tag suffix and actual
  base. Combined with the existence check above, the suffix in the
  image tag is now guaranteed to reflect the Restic version in the
  base layer.
- **`./build-testing-local.sh` now pushes `:develop` instead of
  `:testing`.** The moving alias tag is renamed to match the
  convention used by `./build-testing.sh` (which has always pushed
  `:develop`) so private-registry deployments can reuse the same
  Compose / Kubernetes manifests as the public testing image without
  per-tag renames. The versioned `:<release>` tag (for example
  `:2.6.0-0.18.1-dev`) is unchanged. **Action for users of the
  private-registry script:** update any `image:` references in your
  manifests from `…:testing` to `…:develop`, or pin to the versioned
  `:<release>` tag (recommended).

#### Notes

- No behavioural changes to backup, forget, prune, check or replicate
  workers. Cron-list is read-only; the build-script changes only
  affect how images are produced and tagged, not what the image
  contains at runtime.
- Internal SemVer policy: MINOR rather than PATCH because
  `/bin/cron-list` is a new in-container helper script and `--base`
  is a new CLI surface for the build flow.

### 2.5.0-0.18.1 (2026-05-13)

This release hardens retention handling for repositories shared by
multiple hosts. Three changes that compose: a new standalone forget
worker (`FORGET_CRON`), a soft-skip semantic for restic exit code 11
in the existing inline path, and a separate `forget_exit_code` field
in `last-backup.json` so retention problems stay visible in
monitoring even when the backup itself is fine.

#### Added

- **`/bin/forget` standalone retention worker, scheduled via the new
  `FORGET_CRON` env var.** Mirrors the existing `/bin/prune` shape:
  own `flock` on `/var/run/forget.lock`, own per-run log
  (`/var/log/forget-last.log`), own JSON summary
  (`/var/log/last-forget.json`), own Prometheus textfile
  (`restic_forget.prom` when `METRICS_DIR` is set), own mail subject
  (`[OK|FAIL N] Forget …`) and webhook payload, own `pre-forget` /
  `post-forget "$rc"` hook pair. Reuses `RESTIC_FORGET_ARGS`
  verbatim (no duplicate retention env var), inherits the same
  exit-11 soft-skip semantics as the inline path. The recommended
  pattern for repositories shared by multiple hosts: when
  `FORGET_CRON` is set, `/bin/backup` automatically **skips** its
  inline post-backup forget (cron log records `⏭ Skipping inline
  forget: FORGET_CRON is set …`) so the repository's exclusive
  forget-lock is only ever taken inside this dedicated maintenance
  window — eliminates the exit-11 race entirely. Empty
  `RESTIC_FORGET_ARGS` is loud (`❌ No retention policy
  configured`, exit `2`) so the misconfiguration cannot silently
  succeed.
- **`forget_exit_code` field in `last-backup.json`.** When
  `RESTIC_FORGET_ARGS` triggers a post-backup forget (inline path),
  the helper now records the forget result separately as
  `forget_exit_code: <0|11|other>` alongside the existing
  `exit_code` for the backup itself. Monitoring can alert on
  persistent `forget_exit_code: 11` (= retention is permanently
  losing the lock race) without false-flagging the backup as a
  whole. The value is automatically promoted to a
  `restic_backup_last_forget_exit_code` gauge in
  `restic_backup.prom` because `write_metrics_for_job` numerically
  promotes JSON extras. The standalone worker exposes the same
  number as its own top-level `exit_code` plus a
  `restic_forget_last_exit_code` gauge.
- **`pre-forget.sh` / `post-forget.sh` hook pair**, registered in
  `/bin/doctor` alongside the existing hook families and
  documented in [Hooks](https://marc0janssen.github.io/restic-backup-helper/configuration/hooks.html).
- **Documentation: `/bin/forget` worker page**
  ([`docs/workers/forget.md`](https://marc0janssen.github.io/restic-backup-helper/workers/forget.html))
  with mermaid state machine, sample configurations (multi-host
  dedicated window, single-host no-change, centralised retention
  owner) and exit-code reference. Cross-linked from
  [Backup worker → Multi-host repositories and exit 11](https://marc0janssen.github.io/restic-backup-helper/workers/backup.html#multi-host-repositories-and-exit-11),
  [Prune worker](https://marc0janssen.github.io/restic-backup-helper/workers/prune.html),
  [Troubleshooting](https://marc0janssen.github.io/restic-backup-helper/operations/troubleshooting.html)
  and the JSON / Prometheus reference pages.
- **`--retry-lock=DURATION` recipe baked into all example configs.**
  Every YAML example that ships `RESTIC_FORGET_ARGS`
  (`README.md`, `README-containers.md`, `scripts/docker-compose.yml`,
  `examples/compose/cloud-reference.yml`,
  `examples/compose/multi-job.yml`,
  `examples/kubernetes/restic-backup-helper.yaml`,
  `docs/deployment/docker-compose.md`,
  `docs/deployment/kubernetes.md`,
  `docs/deployment/multiple-jobs.md`, `docs/workers/backup.md`,
  `docs/workers/prune.md`) now leads with
  `--retry-lock=5m --keep-daily 7 …`, so operators copy-pasting from
  the docs pick up the multi-host-safe pattern by default.

#### Changed

- **`backup`: treat post-backup `restic forget` exit code 11 as an
  informational skip instead of a hard failure.** Exit 11 means
  "failed to lock repository" — on a repository shared by multiple
  hosts this is the benign outcome when two backups finish at the
  same time and both try to acquire the exclusive lock that
  `restic forget` needs. Only one wins; the other previously logged
  `❌ Forget Failed with Status 11` and (if `RESTIC_AUTO_UNLOCK=ON`)
  proceeded to `restic unlock`, which on a multi-host repository
  would have cleared the other host's legitimate lock and allowed
  two concurrent mutations. The worker now logs `⏭ Forget skipped:
  repository was locked by another host (exit 11). Retention will
  catch up on the next backup tick.`, leaves the backup's exit code
  at `0`, and **never** runs `restic unlock` on exit 11 regardless
  of `RESTIC_AUTO_UNLOCK`. All other non-zero forget exits keep
  their existing fail-loud handling (log, optional auto-unlock,
  copy error log). Same semantic applies inside the new standalone
  `/bin/forget` worker.
- **`backup` skips its inline forget when `FORGET_CRON` is set.**
  Compat path is opt-in: keeping `FORGET_CRON` empty preserves the
  legacy inline-forget behaviour byte-for-byte.

#### Notes

- `FORGET_CRON` empty (= default) keeps single-host and existing
  setups byte-for-byte unchanged. The new worker only runs when an
  operator explicitly schedules it.
- Internal SemVer policy: this release adds a new env variable, a
  new worker, a new hook pair, a new JSON summary, a new metric
  family and a behaviour change (inline forget is skipped when
  `FORGET_CRON` is set) — MINOR rather than PATCH.

### 2.4.0-0.18.1 (2026-05-12)

#### Added

- **`/bin/mount-snapshot` FUSE-mount helper.** Wraps `restic mount` with the
  same flag vocabulary as `/bin/restore` and `/bin/snapshot-export`: defaults
  `--target` to **`/fusemount`** — a dedicated, container-internal directory
  created at image build (`mkdir -p /fusemount` in the Dockerfile) so the
  FUSE mount never collides with `/bin/restore` output or a host bind-mount
  on `/restore`. Scopes the visible snapshot tree to this container's
  `--host "$HOSTNAME"` and `--tag "$RESTIC_TAG"` so cross-host repositories
  stay tidy, supports repeatable `--path`, opt-in `--allow-other`, and an
  explicit `--repo-wide` override. Refuses to mount on `/data`,
  `BACKUP_ROOT_DIR` or other system/source directories unless `--force` is
  passed (the FUSE mount would otherwise hide the backup source while
  active). An `EXIT` trap calls `fusermount -u` / `umount` as a
  belt-and-braces unmount so Ctrl+C, SIGTERM or a restic crash never leaves
  a stale FUSE mount behind. The recommended browsing workflow is
  `docker exec` / `docker cp` from a second terminal while the helper is
  running; the new
  [Browsing the mount from the host](https://marc0janssen.github.io/restic-backup-helper/operations/mount-snapshot.html#browsing-the-mount-from-the-host)
  documentation section explains the three knobs (`user_allow_other`,
  bind-mount `propagation: rshared`, host-side shared mount peer group)
  needed if you do want the FUSE tree visible on the host filesystem path.
- **Mount-snapshot observability.** The helper writes
  `/var/log/mount-snapshot-last.log`, `/var/log/last-mount-snapshot.json`,
  optional `/hooks/pre-mount-snapshot.sh` and
  `/hooks/post-mount-snapshot.sh "$rc"`, mails/webhooks through the existing
  notification helpers, and emits `restic_mount_snapshot.prom` when
  `METRICS_DIR` is configured. `docker run … mount-snapshot` works as an
  entrypoint pass-through without starting cron first. `/bin/doctor` now
  enumerates the new hook pair and the new JSON summary in its read-only
  diagnostics bundle.
- **Mount-snapshot FUSE pre-flight + targeted hint.** The helper now
  pre-flights every distinct cause of the opaque
  `fusermount: exit status 1 / mount failed: Permission denied`
  failure before invoking restic, by checking:

    1. `/dev/fuse` — existence, character-device kind, r/w access.
    2. `/usr/bin/fusermount` — presence in PATH, on-disk setuid bit.
    3. `CapEff` in `/proc/self/status` — bit 21 (`CAP_SYS_ADMIN`,
       mask `0x200000`).
    4. `NoNewPrivs` in `/proc/self/status` — `1` means the kernel
       ignores the setuid bit on `fusermount` at exec time, so FUSE
       fails even with `CAP_SYS_ADMIN` and `/dev/fuse` correctly set.
    5. `/proc/self/attr/current` — the active AppArmor profile.
       Ubuntu/Debian (and any host shipping Docker's default AppArmor
       template) load `docker-default (enforce)`, which denies
       `mount(2)` regardless of `CAP_SYS_ADMIN`; FUSE bubbles up the
       same opaque `Permission denied`. The helper aborts when the
       profile is enforcing and tells the operator to add
       `security_opt: [apparmor:unconfined]` for that container.

  Each abort names the specific knob (`--cap-add SYS_ADMIN` /
  `cap_add: [SYS_ADMIN]` / `securityContext.capabilities.add:
  [SYS_ADMIN]`, `--device /dev/fuse` /
  `devices: [/dev/fuse:/dev/fuse]`, **not**
  `security_opt: [no-new-privileges:true]`, `security_opt:
  [apparmor:unconfined]` / `securityContext.appArmorProfile.type:
  Unconfined`, `apk add fuse`) so operators see the actual fix
  instead of a post-mortem grep. When `restic mount` itself does
  fail, the per-run log is still scanned for `fusermount` /
  `Permission denied` markers and a numbered five-knob hint is
  appended to `cron.log`. Documentation gains a dedicated
  Troubleshooting section under
  [Mount snapshot](https://marc0janssen.github.io/restic-backup-helper/operations/mount-snapshot.html#troubleshooting),
  and `examples/compose/cloud-reference.yml` now sets
  `security_opt: [apparmor:unconfined]` with an explanatory comment.

### 2.3.0-0.18.1 (2026-05-12)

#### Added

- **`/bin/forget-preview` retention preview helper.** Runs `restic forget --dry-run`
  using the configured `RESTIC_FORGET_ARGS` so operators can validate a
  retention policy before the real post-backup forget runs. By default the
  preview is scoped to `--host "$HOSTNAME"` and `--tag "$RESTIC_TAG"` so
  shared repositories stay safe; repository-wide previews require an explicit
  `--repo-wide` flag. Supports `--host`, `--tag`, `--policy` and `--extra`.
- **Forget preview observability.** The helper writes
  `/var/log/forget-preview-last.log`, `/var/log/last-forget-preview.json`,
  optional `/hooks/pre-forget-preview.sh` and
  `/hooks/post-forget-preview.sh "$rc"`, mails/webhooks through the existing
  notification helpers, and emits `restic_forget_preview.prom` when
  `METRICS_DIR` is configured. `docker run … forget-preview` now works as an
  entrypoint pass-through without starting cron first.

### 2.2.2-0.18.1 (2026-05-12)

#### Added

- **Material for MkDocs documentation site** under `docs/`. The site
  splits the README content into navigable tabs (Getting started,
  Concepts, Configuration, Workers, Operations, Deployment, Reference)
  and adds material-specific affordances: dark/light palette toggle,
  search, code-tabs, mermaid diagrams (for the boot flow, hook
  lifecycle, replicate dispatch and repository state machine),
  admonitions for warnings/tips and per-page git-revision-date stamps.
  Includes `mkdocs.yml`, `docs/requirements.txt` (pinned
  `mkdocs-material>=9.5,<10` + `mkdocs-git-revision-date-localized-plugin`)
  and `docs/stylesheets/extra.css` for small tweaks on top of the
  Material defaults.
- **GitHub Pages workflow** at `.github/workflows/docs.yml`. Builds the
  site with `mkdocs build --strict` on every PR / push touching
  `docs/`, `mkdocs.yml`, `CHANGELOG.md` or the workflow itself, and
  deploys to GitHub Pages from `main` only. PR builds upload the Pages
  artifact for review but do not flip the live site.
- **`.gitignore` excludes** `site/` (MkDocs build output) and `.cache/`
  so the docs build does not leak into commits.

#### Fixed

- **Docs links to release-pinned image tags** in the anonymized
  `examples/compose/cloud-reference.yml` and the docs site landing
  examples are bumped to `2.2.2-0.18.1` to keep CI's version-guard happy.

### 2.2.1-0.18.1 (2026-05-11)

#### Fixed

- **`shellcheck` clean build for `/bin/snapshot-export`.** The `cleanup()` function (invoked via the `EXIT` trap) now carries a combined `# shellcheck disable=SC2317,SC2329` directive so static analysis no longer flags the trap-only branches as unreachable. The single `copyErrorLog` call site now passes `"${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"` explicitly, matching the function's documented signature, resolving SC2119 and making the intent self-documenting. No runtime behaviour change; CI `ci-quality-checks.sh` shellcheck step now passes for `app/snapshot_export.sh`.

### 2.2.0-0.18.1 (2026-05-11)

#### Added

- **`/bin/snapshot-export` archive helper.** Restores a selected snapshot (default `latest`) into a temporary work directory and packages the result as a `tar.gz` archive under `/restore` by default, or a caller-supplied `--output` path. Supports `--id`, `--tag`, `--host`, repeatable `--include` / `--exclude`, `--dry-run`, `--verify`, `--verbose`, `--work-dir`, `--keep-workdir` and `--force`. The helper refuses to overwrite an existing archive unless forced, treats include filters that restore 0 files/dirs as exit `3`, and cleans its temporary tree unless told to keep it.
- **Snapshot export observability.** The new helper writes `/var/log/snapshot-export-last.log`, `/var/log/last-snapshot-export.json`, optional `/hooks/pre-snapshot-export.sh` and `/hooks/post-snapshot-export.sh "$rc"`, mails/webhooks through the existing notification helpers, and emits `restic_snapshot_export.prom` when `METRICS_DIR` is configured. `docker run … snapshot-export --id <snapshot>` now works as an entrypoint pass-through without starting cron first.

### 2.1.0-0.18.1 (2026-05-11)

#### Added

- **`/bin/doctor` read-only diagnostics.** Prints release and tool versions, masked effective environment values, password / config / cache / metrics path checks, `RESTIC_JOB_ARGS` file references, a non-mutating `restic cat config` repository probe, effective `REPLICATE_*` values with legacy `SYNC_*` deprecation warnings, replicate job-file validation with masked endpoints, hook executable status, recent `last-*.json` summaries and the tail of `/var/log/cron.log`. The command exits non-zero only when it finds hard errors such as missing repository settings, unreadable required secrets/config, empty `RESTIC_TAG`, no backup paths, or a failed repository probe.
- **Entrypoint pass-through for doctor.** `docker run … doctor` and `docker run … /bin/doctor` now execute the diagnostics directly instead of starting cron first; `docker exec <container> /bin/doctor` works unchanged for already-running containers.

### 2.0.0-0.18.1 (2026-05-11)

#### Changed (breaking)

- **Rclone "sync/bisync" surface renamed to "replicate".** The worker now lives at `app/replicate.sh` and is exposed as `/bin/replicate`; cron uses `/var/run/replicate.lock`; logs moved from `/var/log/sync-last.log` / `sync-error-last.log` / `sync-mail-last.log` to `/var/log/replicate-last.log` / `replicate-error-last.log` / `replicate-mail-last.log`; the structured summary moved from `/var/log/last-sync.json` to `/var/log/last-replicate.json`; Prometheus textfile output is now `restic_replicate.prom`; hooks are now `/hooks/pre-replicate.sh` and `/hooks/post-replicate.sh`; the JSON/webhook job name is now `replicate`; mail subjects use `Replicate` instead of `Sync`.
- **Config sample renamed from `config/sync_jobs.txt` to `config/replicate_jobs.txt`.** The installed default is now `REPLICATE_JOB_FILE=/config/replicate_jobs.txt`. Existing deployments mounting an old file must either rename the mounted file or set `REPLICATE_JOB_FILE=/config/sync_jobs.txt` explicitly. No runtime symlink is created for the config file by design.
- **Environment variable names moved from `SYNC_*` to `REPLICATE_*`.** Use `REPLICATE_CRON`, `REPLICATE_JOB_FILE`, `REPLICATE_JOB_ARGS`, `REPLICATE_VERBOSE` and `REPLICATE_BISYNC_CHECK_ACCESS`. The rclone per-job mode value `bisync` is unchanged; `SOURCE;DESTINATION;bisync`, `SOURCE;DESTINATION;sync` and `SOURCE;DESTINATION;copy` remain valid job-file rows.

#### Added

- **Compatibility bridge for old deployments.** `/bin/bisync` is now a symlink to `/bin/replicate`, and legacy `SYNC_*` environment variables are mapped to their `REPLICATE_*` replacements when the new names are unset. Both paths log deprecation warnings and are scheduled for removal in 3.0.0.

#### Deprecated

- **`SYNC_*` env vars and `/bin/bisync` alias.** Kept for compatibility in 2.x, removed in 3.0.0. New deployments should use `REPLICATE_*` and `/bin/replicate`.

### 1.18.0-0.18.1 (2026-05-11)

#### Added

- **`/bin/restore --yes` (`-y`)** runs the whole flow fully non-interactively: the snapshot picker, the target prompt, the dry-run prompt **and** the final `Proceed?` confirmation are all skipped. Missing answers fall back on the same defaults the cron/CI path uses (`latest` snapshot when `--id` is not given, `/restore` target when `--target` is not given, no dry-run). Lets an operator inside `docker exec -ti …` launch a one-shot restore — e.g. `restore --id 5a3f2c8b --target /restore --verbose --yes` — without dropping back to `< /dev/null` to defeat the TTY check. Implementation: `INTERACTIVE` is forced `OFF` when `ASSUME_YES=ON` so every conditional prompt in the script naturally falls through to its default. The flag is logged as `ASSUME_YES: ON` in `restore-last.log` so audit trails can tell "operator typed y" apart from "operator passed --yes". The "About to run: restic restore …" preview line is now printed unconditionally so the operator still sees the exact command even when no Proceed prompt follows.
- **`/bin/restore --verbose` (`-v`)** streams restic's output live while the restore is running. Two things make it actually visible: (a) the wrapper passes `--verbose=2` to restic — the only level at which restic emits `restored /path/...`, `skipped …`, `unchanged …` per-file lines for the restore command (`--verbose=1` is essentially a no-op for restore); (b) restic is wrapped in `script(1)` (newly-added `util-linux` apk package) so its native in-place progress bar (`[time] X%, MiB/s, ETA …`) renders too — without the PTY allocation, restic's tty-detect would see our `tee`-to-log pipe and suppress the bar. Combined output is tee'd to `/var/log/restore-last.log`; the file therefore contains ANSI escape codes and `\r` overwrites from the bar — view with `cat` on a terminal or strip with `col -bp`. `set -o pipefail` is already in effect and `script -e` propagates the child's exit, so the pipeline's exit code keeps reflecting restic's (not tee's) when restic fails. `SHELL=/bin/bash` is forced for the `script -c` invocation so bash's `%q` quoting (used to safely serialise the args array) round-trips reliably; the Restic Alpine base ships `/bin/ash` as the default `$SHELL`, which doesn't grok bash-specific escapes.
- **`util-linux` apk package** added to the image solely for `script(1)`; consumed by `/bin/restore --verbose` to wrap restic in a pseudo-TTY so the native in-place progress bar renders. Approx. +6 MB image size; gated to the verbose code path so non-verbose restores and the other workers are unaffected. The `col` binary in the same package is referenced in docs as the standard way to strip the resulting ANSI / `\r` noise from `/var/log/restore-last.log`.

#### Fixed

- **`/bin/restore` snapshot ordering.** Interactive mode and `--list` are now sorted **newest-first**: the second awk pass in `list_snapshots_table` collects matching snapshots into an array and emits them in reverse order with a renumbered 1-based index in its `END` block, so row 1 is the most recent snapshot and `print_snapshot_table 10` shows "the 10 most recent" instead of "the 10 oldest". The interactive prompt now caps its `index 1-N` range at the number of rows actually displayed and, when the filter matched more snapshots than fit on screen, prints a one-line hint pointing operators to `/bin/restore --list` (or the short-id form) for older snapshots.
- **`/bin/restore` snapshot parsing.** Added `n` and `rest` (and `content` in `jget_array`) to the function-local parameter lists of the inline awk parsers so they cannot clobber the body block's `n` counter that indexes the buffered `out[]` array. Without this, each `jget` call rewrote the global `n` to `index(blob, key)`, causing later records to overwrite earlier `out[n]` entries — visible as a mostly-empty interactive list (only the last one or two snapshots populated) once the new newest-first buffering was introduced.
- **`lib.sh::parse_restic_restore_stats` is `\r`-tolerant.** When `/bin/restore --verbose` wraps restic in a PTY (so the in-place progress bar renders), the resulting `restore-last.log` contains the final progress-bar update glued onto the Summary line with a `\r` separator. The helper now `tr '\r' '\n'`s the log before grepping for `^Summary:`, so `last-restore.json`, the webhook payload and the mail subject still get correct `files_restored` / `bytes_restored` / `elapsed_human` values.

#### Changed

- **Universal `q` / `quit` cancel in interactive `/bin/restore`.** Operators can now abort at any of the four interactive prompts (snapshot index, target path, "Dry-run first?", "Proceed?") by typing `q` or `quit`. The new `cancel_interactive_restore` helper records `exit_code=130` + `cancelled=true` in `/var/log/last-restore.json` regardless of how far into the flow the cancel happens, falling back to "now" when the start epoch has not been set yet. Prompt labels updated accordingly (`[…, q=quit]`, `[Y/n/q]`, `[y/N/q]`) and the per-run log file is now cleared before the first prompt so a cancel does not append to stale content.
- **`--include` zero-match detection in `/bin/restore`.** If a restore is invoked with one or more `--include` filters and restic's summary reports `0` restored files/dirs, the wrapper now treats the run as a clear failure (`exit_code=3`, `include_zero_match=true` in `last-restore.json` / webhook payload, `[FAIL 3]` mail subject with `include matched 0`). This catches the common path-prefix mistake where the snapshot contains `/host/home/...` but the operator typed `/home/...`, avoiding a silently green "restored nothing" run.
- **Interactive mode in `/bin/restore` is now TTY-driven only.** Previously *any* flag (including `--verbose` or `--force`) forced the non-interactive code path, so e.g. `restore --verbose --force` would skip every prompt and run immediately. The interactive flow is now triggered purely by `[ -t 0 ] && [ -t 1 ]`, and flags only suppress the *individual* prompt whose answer they already supply: `--id` skips the snapshot picker, `--target` skips the target prompt, `--dry-run` skips the dry-run prompt, and the new `--yes` / `-y` skips the final "Proceed? [y/N/q]" confirmation. All other flags (`--verbose`, `--force`, `--verify`, `--tag`, `--host`, `--since`, `--include`, `--exclude`, `--owner`) leave every prompt intact. Without a TTY (cron, CI, `docker exec` without `-t`) the wrapper continues to skip all prompts and defaults to `latest`. The `HAD_FLAGS` variable was retired in favour of explicit `TARGET_EXPLICIT` / `DRY_RUN_EXPLICIT` markers that the parser sets on the two flags that *replace* a prompt answer.

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
