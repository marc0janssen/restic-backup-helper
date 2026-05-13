# Restore test (disaster-recovery rehearsal)

`/bin/restore-test` is the disaster-recovery counterpart of `restic
check`. `restic check` proves the **repository is healthy** (manifests,
blobs and pack files are internally consistent). `restore-test` proves
the **bytes can actually come back**: it picks a snapshot, restores it
(or a small canary sub-path) into an isolated temp directory, asserts
the restored tree is non-empty (and optionally that one or more canary
files match a known SHA-256), then removes the tempdir again.

Run it from cron (e.g. nightly or weekly) so a silent failure on the
restore path — a permission regression on the backend, a misconfigured
`RESTIC_PASSWORD_FILE`, a broken bind-mount under `/restore` — surfaces
**before** you need a real restore.

## Quick start

```shell
# Default: latest snapshot for this host+tag, full restore into an
# auto-mktemp tempdir under /tmp/restore-test.XXXXXX, file-count floor
# of 1, no checksum verification, cleaned up on success.
docker exec restic-backup-helper /bin/restore-test

# Restore only a canary sub-path of the snapshot (much faster on huge
# repos), and assert the restored copy of one specific file matches a
# known SHA-256 digest. The canary path is the snapshot-absolute path
# as you would see it in `restic ls latest`.
docker exec restic-backup-helper /bin/restore-test \
    --path /data/canary \
    --canary "/data/canary/sentinel.txt=2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"

# Dry-run: ask restic what it would restore, write the JSON / metrics
# audit trail, but skip the verification step and never create files.
docker exec restic-backup-helper /bin/restore-test --dry-run

# Keep the restored tree on disk for manual inspection, into a specific
# target. With --target you control where the bytes land; without it
# the helper picks an auto-tempdir.
docker exec restic-backup-helper /bin/restore-test \
    --target /restore/rehearsal --keep --force
```

## Options

| Flag | Purpose |
| --- | --- |
| `--id HEX` | Snapshot ID to restore. Defaults to `latest`. |
| `--tag TAG` | Filter snapshots by tag (default: `$RESTIC_TAG`). |
| `--host HOST` | Filter snapshots by host (default: container `$HOSTNAME`). |
| `--path PATH` | Restore only this sub-path of the snapshot (`restic --include`). Repeatable. Defaults to the full snapshot. |
| `--target PATH` | Explicit restore target. Defaults to `mktemp -d /tmp/restore-test.XXXXXX`. Explicit targets must be empty (or pass `--force`). |
| `--keep` | Do not remove the restored tree after verification. Default is to clean up. |
| `--force` | Allow restoring into a non-empty explicit `--target`. |
| `--canary PATH=SHA256` | Assert that the restored copy of `PATH` matches the given lowercase SHA-256 hex digest. Repeatable. |
| `--canary-file FILE` | Read canaries from a `sha256sum`-format file ("`<sha256>  <path>`"), one per line. Comments (`#`) and blank lines are skipped. Useful when paths contain `=` or whitespace. |
| `--min-files N` | Fail unless at least `N` files were restored. Default: `1`. Set `0` to disable. |
| `--verify` | Pass `--verify` to restic so per-file hashes are verified against the snapshot manifest during the restore. Slower; catches silent corruption. |
| `--dry-run` | Run `restic restore --dry-run` only. Skips verification and tempdir creation. |
| `--yes` / `-y` | Reserved for future interactive guard; safe to keep in cron scripts today. |

## Environment-variable equivalents

| Env var | Equivalent flag | Notes |
| --- | --- | --- |
| `RESTORE_TEST_PATH` | `--path` | Whitespace-separated list of paths. |
| `RESTORE_TEST_TARGET` | `--target` | Rare; the auto-tempdir is the safer default. |
| `RESTORE_TEST_CANARY` | `--canary` | Whitespace-separated `PATH=SHA256` entries. Use `RESTORE_TEST_CANARY_FILE` when paths contain `=` or whitespace. |
| `RESTORE_TEST_CANARY_FILE` | `--canary-file` | Path to a `sha256sum`-format manifest. |
| `RESTORE_TEST_KEEP` | `--keep` | Set to `ON` to enable. |
| `RESTORE_TEST_MIN_FILES` | `--min-files` | Default `1`. |
| `RESTORE_TEST_VERIFY` | `--verify` | Set to `ON` to enable. |

## Behaviour

- **Always non-mutating w.r.t. the repository.** The helper only calls
  `restic restore`, never `forget`, `prune` or `init`.
- **Always isolated from operator data.** Without `--target` the helper
  uses `mktemp -d /tmp/restore-test.XXXXXX`. With `--target` it refuses
  to restore into `/`, `/data` or `BACKUP_ROOT_DIR`.
- **Cleanup is bounded.** Auto-tempdirs (`/tmp/restore-test.XXXXXX`) are
  removed on exit unless `--keep` is set. Operator-supplied targets are
  **never** auto-removed — a rehearsal that surfaces a problem stays
  on disk for inspection. The on-disk verdict is recorded in JSON as
  `cleanup_status` (`cleaned`, `kept`, `cleanup-failed`, `absent`).
- **Verification has two layers.** The file-count floor (`--min-files`,
  default `1`) catches a restore that silently produced nothing
  (e.g. `--path` matched zero files in the snapshot). The canary
  layer (`--canary` / `--canary-file`) catches per-file corruption that
  `restic check` would miss because the bytes are internally consistent
  but happen to be the wrong bytes.
- **Exit code is operator-actionable.** `0` means "restore worked, all
  configured canaries match"; any other exit means an action is
  required. The cron-driven `notify_mail` / `notify_webhook` plumbing
  fires accordingly.

## Audit trail

The helper writes:

- `/var/log/restore-test-last.log` — full restic stdout/stderr.
- `/var/log/restore-test-error-last.log` — copied on failure.
- `/var/log/last-restore-test.json` — see schema below.
- `restic_restore_test.prom` — when `METRICS_DIR` is configured.

Hooks (informational by default; pre-hook failure does not abort):

```text
/hooks/pre-restore-test.sh                # before the rehearsal
/hooks/post-restore-test.sh "$exit_code"  # always called with the helper exit code
```

## JSON summary (`/var/log/last-restore-test.json`)

In addition to the common envelope (`job`, `hostname`, `release`,
`started_at`, `finished_at`, `duration_seconds`, `exit_code`):

| Field | Description |
| --- | --- |
| `repository` | Masked repository URL. |
| `snapshot` | Snapshot selector passed to restic (`latest` or short/long ID). |
| `target` | Effective restore target. |
| `target_autotmp` | `ON` when the target was an auto-mktemp tempdir, `OFF` for `--target`. |
| `keep` | `ON` / `OFF`. |
| `dry_run` | `ON` / `OFF`. |
| `verify` | `ON` when restic was invoked with `--verify`. |
| `min_files` | Effective `--min-files` floor. |
| `min_files_met` | `"true"` / `"false"` — whether the file-count floor was satisfied. |
| `files_restored` | Restored regular files counted on disk. |
| `bytes_restored` | Restored bytes counted on disk (sum of regular-file sizes). |
| `verification` | `passed`, `failed` or `skipped` (`dry-run`). |
| `canary_total` / `canary_passed` / `canary_failed` | Flat counts. |
| `cleanup_status` | `cleaned`, `kept`, `cleanup-failed`, `absent`. |
| `include_paths_count` | Number of `--path` entries used (0 = full snapshot). |
| `tag_filter` / `host_filter` | Filters passed to restic, when set. |
| `restic_files_restored` / `restic_bytes_restored` / `restic_elapsed_human` | Parsed from restic's "Summary: Restored …" line, when present. |
| `include_zero_match` | `"true"` when `--path` matched zero files (exit `3`). |
| `canary_results[]` | Nested array; one object per canary with `path`, `expected_sha256`, `actual_sha256`, `status` (`passed`, `mismatch`, `missing`, `hash-failed`) and `message`. |

Example (canary success):

```json
{
  "job": "restore-test",
  "hostname": "backup-node",
  "release": "2.13.0-0.18.1",
  "started_at": "2026-05-13T22:55:00+0200",
  "finished_at": "2026-05-13T22:55:04+0200",
  "duration_seconds": 4,
  "exit_code": 0,
  "repository": "rclone:jottacloud:backups",
  "snapshot": "latest",
  "target": "/tmp/restore-test.aB12Cd",
  "target_autotmp": "ON",
  "keep": "OFF",
  "dry_run": "OFF",
  "verify": "OFF",
  "min_files": "1",
  "min_files_met": "true",
  "files_restored": "1",
  "bytes_restored": "9",
  "verification": "passed",
  "canary_total": "1",
  "canary_passed": "1",
  "canary_failed": "0",
  "cleanup_status": "cleaned",
  "include_paths_count": "0",
  "tag_filter": "backup-node-data",
  "host_filter": "backup-node",
  "restic_files_restored": "1",
  "restic_bytes_restored": "9 B",
  "restic_elapsed_human": "1.234s",
  "canary_results": [
    {
      "path": "/data/canary/sentinel.txt",
      "expected_sha256": "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
      "actual_sha256": "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
      "status": "passed",
      "message": ""
    }
  ]
}
```

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Restore + verification succeeded. |
| `1` | Restore failed, file-count floor not met, or at least one canary mismatched / went missing. |
| `2` | Configuration / argument error (bad `--canary` spec, refuses-to-restore-into-/data, …). |
| `3` | `restic restore` exited 0 but matched zero files for `--path` (snapshot path typo). |

## Scheduling

There is **no `RESTORE_TEST_CRON`** baked into the entrypoint by design:
restore rehearsals are read-mostly but they do consume backend bandwidth
and CPU, so operators should opt in deliberately rather than have the
container schedule them implicitly. Two common patterns:

- **Sidecar `cron` line** inside your orchestration of choice (Compose
  with another scheduler, Kubernetes `CronJob` calling `restore-test`,
  systemd timer on the host).
- **`docker exec` from a host cron** so the helper inherits a normal
  TTY-free environment and the JSON / metrics / mail / webhook audit
  trail still fires inside the container.

A weekly cadence (`@weekly`) tied to a small canary sub-path is the
common starting point; tighten or relax once you see how long the
rehearsal takes against your real backend.

## See also

- [Restore](restore.md) — operator-driven restore wrapper.
- [Snapshot export](snapshot-export.md) — package a snapshot as a tar.gz archive.
- [Diagnostics (doctor)](diagnostics.md) — surfaces `last-restore-test.json` in `recent_json[]`.
- [Hooks](../configuration/hooks.md) — `pre-restore-test` / `post-restore-test`.
- [JSON summaries](../reference/json-summaries.md) — `last-restore-test.json` schema.
- [Prometheus metrics](../reference/prometheus-metrics.md) — `restic_restore_test_*` gauges.
