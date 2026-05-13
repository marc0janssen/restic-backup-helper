# JSON summaries

Every worker writes a structured per-run summary under `/var/log` after
it finishes. They are intended for external monitoring without requiring
a push gateway: scrape the file or have your webhook endpoint receive
the same document.

Files are written via `*.tmp` + `mv` so a node-exporter / log forwarder
scrape never sees a partial document.

## Common fields (every worker)

| Field | Type | Description |
| --- | --- | --- |
| `job` | string | One of `backup`, `check`, `prune`, `forget`, `replicate`, `restore`, `snapshot-export`, `forget-preview`, `mount-snapshot`, `unlock`, `sources-report`, `init-repo`, `notify-test`. |
| `hostname` | string | Container hostname. Set explicitly in Compose / Kubernetes for stable labels. |
| `release` | string | `${VERSION}-${restic_base}` baked at build time, e.g. `2.11.0-0.18.1`. |
| `started_at` | string | ISO 8601 in container `TZ`. |
| `finished_at` | string | ISO 8601 in container `TZ`. |
| `started_epoch` | integer | Unix epoch seconds at start. |
| `finished_epoch` | integer | Unix epoch seconds at finish. |
| `duration_seconds` | integer | Wall-clock duration. |
| `exit_code` | integer | Worker exit code. `0` = success. |
| `repository` | string | Masked Restic repository URL (`mask_repository`). |

## Per-worker schemas

### `last-backup.json`

`/bin/backup` produces, in addition to the common fields:

| Field | Type | Description |
| --- | --- | --- |
| `backup_root_dir` | string | Value of `BACKUP_ROOT_DIR` at runtime. |
| `restic_tag` | string | The tag passed to `restic backup`. |
| `forget_exit_code` | integer \| omitted | Exit code of the post-backup `restic forget` when `RESTIC_FORGET_ARGS` is set. `0` = success, `11` = skipped because another host held the exclusive lock (multi-host race, harmless), other values = forget failure. Omitted when no forget was attempted. See [Backup worker → Multi-host repositories and exit 11](../workers/backup.md#multi-host-repositories-and-exit-11). |
| `snapshot_id` | string \| omitted | Short snapshot ID when restic produced one. |
| `files_new` | integer \| omitted | Files added in this snapshot. |
| `files_changed` | integer \| omitted | Files changed since the previous snapshot. |
| `files_unmodified` | integer \| omitted | Files that were unchanged. |
| `dirs_new` / `dirs_changed` / `dirs_unmodified` | integer \| omitted | Same for directories. |
| `bytes_added` | string \| omitted | Bytes added, human-formatted (`1.234 MiB`). |
| `bytes_stored` | string \| omitted | Bytes stored in this snapshot, human-formatted. |

Numeric extras only appear when restic actually printed them. Failed
backups before restic emitted its summary line will have only the
common fields and `exit_code`.

```json
{
  "job": "backup",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-11T02:00:00+0200",
  "finished_at": "2026-05-11T02:05:12+0200",
  "started_epoch": 1762828800,
  "finished_epoch": 1762829112,
  "duration_seconds": 312,
  "exit_code": 0,
  "repository": "s3:https://s3.example.com/***@bucket/restic",
  "backup_root_dir": "/data",
  "restic_tag": "backup-node-data",
  "forget_exit_code": 0,
  "snapshot_id": "a1b2c3d4",
  "files_new": 12,
  "files_changed": 4,
  "files_unmodified": 21034,
  "bytes_added": "1.234 MiB"
}
```

### `last-check.json`

Common fields only. `restic check` does not emit headline metrics worth
extracting; `repository` is the helpful one.

### `last-prune.json`

Common fields only.

### `last-forget.json`

`/bin/forget` (the standalone retention worker, activated by
`FORGET_CRON`) emits the common fields plus the masked `repository`
URL. The cumulative-and-idempotent nature of `restic forget` means
the JSON does not duplicate the inline path's `forget_exit_code`
field — here the top-level `exit_code` **is** the forget result:

- `0` = success
- `2` = `RESTIC_FORGET_ARGS` empty (misconfiguration; nothing to
  forget — set a policy or unset `FORGET_CRON`)
- `11` = skipped because another host held the exclusive lock
  (multi-host race, harmless; retention catches up on the next
  tick)
- other = restic failure (see `forget-error-last.log`).

Exit `11` is also auto-promoted to a `restic_forget_last_exit_code`
gauge in `restic_forget.prom` — monitoring can alert on persistent
`11` without false-flagging the dedicated worker run.

See [Forget worker](../workers/forget.md) for the full state machine.

### `last-forget-preview.json`

`/bin/forget-preview` produces, in addition to the common fields:

| Field | Type | Description |
| --- | --- | --- |
| `repo_wide` | string | `ON` when `--repo-wide` was used, otherwise `OFF`. |
| `policy_args` | string | Retention policy used (`RESTIC_FORGET_ARGS` or `--policy`). |
| `extra_args` | string | Extra restic forget args appended via `--extra`. |
| `host_filter` | string \| omitted | Host filter used for the preview; omitted when `repo_wide=ON`. |
| `tag_filter` | string \| omitted | Tag filter used for the preview; omitted when `repo_wide=ON`. |

It is always a dry-run wrapper; a successful preview does not delete
snapshots.

### `last-replicate.json`

| Field | Type | Description |
| --- | --- | --- |
| `replicate_jobs_processed` | integer | Number of job rows parsed and dispatched. |
| `replicate_jobs_failed` | integer | Number that failed (counting recoveries). |

```json
{
  "job": "replicate",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-11T09:00:00+0200",
  "finished_at": "2026-05-11T09:11:23+0200",
  "duration_seconds": 683,
  "exit_code": 0,
  "replicate_jobs_processed": 3,
  "replicate_jobs_failed": 0
}
```

### `last-restore.json`

| Field | Type | Description |
| --- | --- | --- |
| `snapshot` | string | Snapshot ID restored. |
| `target` | string | Restore target path. |
| `dry_run` | boolean | `true` when `--dry-run` was passed. |
| `cancelled` | boolean | `true` when the operator typed `q`/`quit` or hit Ctrl+C. |
| `include_zero_match` | boolean | `true` when `--include` matched 0 files/dirs. |
| `files_restored` | integer \| omitted | From restic's `Summary:` line. |
| `bytes_restored` | string \| omitted | Human-formatted bytes restored. |
| `elapsed_human` | string \| omitted | Human-formatted restore duration (from restic, may differ slightly from `duration_seconds`). |

Exit codes:

- `0` on success.
- `3` when `include_zero_match=true`.
- `130` when `cancelled=true`.

### `last-snapshot-export.json`

| Field | Type | Description |
| --- | --- | --- |
| `snapshot` | string | Snapshot ID exported. |
| `archive` | string | Final archive path (or `null` when `--dry-run`). |
| `work_dir` | string | Temporary work directory used (auto-generated or operator-supplied). |
| `dry_run` | boolean | `true` when `--dry-run` was passed. |
| `include_zero_match` | boolean | `true` when `--include` matched 0 files/dirs. |
| `archive_size_bytes` | integer \| omitted | Size of the archive on disk; only when not `--dry-run`. |
| `files_restored` / `bytes_restored` / `elapsed_human` | – | Same as restore. |

```json
{
  "job": "snapshot-export",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-11T15:30:00+0200",
  "finished_at": "2026-05-11T15:31:12+0200",
  "duration_seconds": 72,
  "exit_code": 0,
  "repository": "rclone:jottacloud:backups",
  "snapshot": "5a3f2c8b",
  "archive": "/restore/snapshot-export-5a3f2c8b-20260511-153000.tar.gz",
  "archive_size_bytes": 595132416,
  "work_dir": "/tmp/snapshot-export.pFKmAM",
  "dry_run": false,
  "include_zero_match": false,
  "files_restored": 4523,
  "bytes_restored": "567.89 MiB",
  "elapsed_human": "1m12s"
}
```

### `last-mount-snapshot.json`

`/bin/mount-snapshot` records one entry **per mount session**, written
after restic releases the FUSE mount:

| Field | Type | Description |
| --- | --- | --- |
| `target` | string | Mountpoint used (default `/restore`). |
| `repo_wide` | string | `ON` when `--repo-wide` was used, otherwise `OFF`. |
| `allow_other` | string | `ON` when `--allow-other` was used, otherwise `OFF`. |
| `host_filter` | string \| omitted | Host filter used; omitted when `repo_wide=ON`. |
| `tag_filter` | string \| omitted | Tag filter used; omitted when `repo_wide=ON`. |
| `path_filters` | string \| omitted | Space-separated list of `--path` values, when any were passed. |

`duration_seconds` measures the length of the mount session itself
(from "restic mount started" to "FUSE unmounted"); for ad-hoc operator
browsing this can be minutes-to-hours.

```json
{
  "job": "mount-snapshot",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-12T17:00:00+0200",
  "finished_at": "2026-05-12T17:12:31+0200",
  "duration_seconds": 751,
  "exit_code": 0,
  "repository": "rclone:jottacloud:backups",
  "target": "/restore",
  "repo_wide": "OFF",
  "allow_other": "OFF",
  "host_filter": "backup-node",
  "tag_filter": "backup-node-data"
}
```

### `last-unlock.json`

`/bin/unlock` (the operator-driven manual `restic unlock` wrapper)
emits the common fields plus:

| Field | Type | Description |
| --- | --- | --- |
| `repository` | string | Masked repository URL. |
| `remove_all` | string | `ON` when `--remove-all` was used, otherwise `OFF`. |
| `dry_run` | string | `ON` when `--dry-run` was used, otherwise `OFF`. |
| `locks_before` | string | Lock count from `restic list locks` before the unlock call. `"unknown"` when the listing itself failed. |
| `locks_after` | string | Lock count after the unlock call. Equals `locks_before` when `dry_run=ON`. |

```json
{
  "job": "unlock",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-13T13:25:00+0200",
  "finished_at": "2026-05-13T13:25:01+0200",
  "duration_seconds": 1,
  "exit_code": 0,
  "repository": "rclone:jottacloud:backups",
  "remove_all": "OFF",
  "dry_run": "OFF",
  "locks_before": "1",
  "locks_after": "0"
}
```

See [Unlock](../operations/unlock.md) for the full flag reference and
the safety story around `RESTIC_AUTO_UNLOCK=OFF`.

### `last-sources-report.json`

`/bin/sources-report` (the operator-driven pre-flight inventory) emits
the common fields plus a flat aggregate **and** three nested arrays
with per-source / per-files-from / per-exclude-file detail:

| Field | Type | Description |
| --- | --- | --- |
| `backup_root_dir` | string | Value of `BACKUP_ROOT_DIR` at report time. |
| `sources_count` | integer | Number of unique source paths inspected. |
| `files_from_count` | integer | Number of `--files-from` files inspected. |
| `exclude_files_count` | integer | Number of `--exclude-file` files inspected. |
| `total_files` | integer | Sum of `find -type f` counts across sized sources. `0` when `--no-size` was set. |
| `total_bytes` | integer | Sum of `du -sk * 1024` across sized sources. `0` when `--no-size` was set. |
| `errors_count` | integer | Unreadable / missing entries (sources, `--files-from` files themselves, entries inside `--files-from`, `--exclude-file` files). |
| `no_size` | string | `ON` / `OFF` mirroring `--no-size`. |
| `depth_limit` | string | `--depth N` value, or `unlimited`. |
| `sources` | array of `{path, readable, type, files, bytes}` | Per-source detail. `files` / `bytes` are `-1` when the source was skipped via `--no-size`. |
| `files_from` | array of `{path, readable, lines, missing_entries}` | Per-file detail. |
| `exclude_files` | array of `{path, readable, patterns}` | Per-file detail. |

```json
{
  "job": "sources-report",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-13T15:30:00+0200",
  "finished_at": "2026-05-13T15:30:08+0200",
  "duration_seconds": 8,
  "exit_code": 0,
  "backup_root_dir": "/data",
  "sources_count": 1,
  "files_from_count": 1,
  "exclude_files_count": 1,
  "total_files": 18247,
  "total_bytes": 9876543210,
  "errors_count": 0,
  "no_size": "OFF",
  "depth_limit": "unlimited",
  "sources": [
    {"path": "/data", "readable": true, "type": "directory", "files": 18247, "bytes": 9876543210}
  ],
  "files_from": [
    {"path": "/config/files-from.txt", "readable": true, "lines": 4, "missing_entries": 0}
  ],
  "exclude_files": [
    {"path": "/config/excludes.txt", "readable": true, "patterns": 12}
  ]
}
```

See [Sources report](../operations/sources-report.md) for the full
flag reference and estimate semantics (size is unfiltered;
exclude-file inventory is reported separately).

### `last-init-repo.json`

`/bin/init-repo` (the audited `restic init` wrapper) emits the
common fields plus:

| Field | Type | Description |
| --- | --- | --- |
| `repository` | string | Masked repository URL. |
| `dry_run` | string | `ON` when `--dry-run` was used, otherwise `OFF`. |
| `assume_yes` | string | `ON` when `--yes` / `-y` was used, otherwise `OFF`. |
| `confirmed` | string | `ON` when the operator typed `init` at the prompt OR when `--yes` was used; `OFF` when the prompt was declined / not reached. |
| `repo_existed` | string | `"true"` / `"false"` / `"unknown"` from the pre-init probe. |
| `probe_exit_code` | string | Raw exit code of `restic cat config`. `-1` when env validation failed before the probe ran. |
| `init_args` | string | The combined `RESTIC_INIT_ARGS` + CLI passthrough flag list (space-joined). |

```json
{
  "job": "init-repo",
  "hostname": "backup-node",
  "release": "2.11.0-0.18.1",
  "started_at": "2026-05-13T16:30:00+0200",
  "finished_at": "2026-05-13T16:30:02+0200",
  "duration_seconds": 2,
  "exit_code": 0,
  "repository": "rclone:jottacloud:backups",
  "dry_run": "ON",
  "assume_yes": "OFF",
  "confirmed": "OFF",
  "repo_existed": "false",
  "probe_exit_code": "10",
  "init_args": "--repository-version=2"
}
```

See [Init repo](../operations/init-repo.md) for the full flag
reference, the type-to-confirm prompt and the dry-run verdict
matrix.

### `last-notify-test.json`

`/bin/notify-test` (the operator-driven mail/webhook delivery test)
emits the common fields plus:

| Field | Type | Description |
| --- | --- | --- |
| `target_mode` | string | `auto`, `mail`, `webhook` or `all`. |
| `dry_run` | string | `ON` / `OFF`. |
| `mail_requested` | string | `ON` when mail delivery was selected. |
| `webhook_requested` | string | `ON` when webhook delivery was selected. |
| `mail_configured` | string | `ON` when `MAILX_RCPT` was set. |
| `webhook_configured` | string | `ON` when `WEBHOOK_URL` was set. |
| `mail_result` | string | `delivered`, `failed`, `dry-run` or `skipped`. |
| `webhook_result` | string | `delivered`, `failed`, `dry-run` or `skipped`. |
| `mail_rc` | string | Raw return code from `notify_mail`. |
| `webhook_rc` | string | Raw return code from `notify_webhook`. |
| `webhook_url` | string | Masked webhook URL (`scheme://host/...`). |
| `webhook_auth_header_set` | string | `ON` when `WEBHOOK_HEADER_AUTH` was present. |
| `mail_on_error` | string | Original `MAILX_ON_ERROR` value observed at runtime. |
| `webhook_on_error` | string | Original `WEBHOOK_ON_ERROR` value observed at runtime. |
| `webhook_timeout` | string | Effective `WEBHOOK_TIMEOUT` value. |
| `subject` | string | Subject prefix / webhook detail. |
| `message` | string | Optional operator message. |
| `duration_so_far_seconds` | string | Runtime at the moment the JSON extras were rendered. |

See [Notify test](../operations/notify-test.md) for target-selection
rules and why delivery failures affect this helper's exit code.

## Reading the files

```shell
docker exec restic-backup-helper cat /var/log/last-backup.json
docker exec restic-backup-helper cat /var/log/last-backup.json | jq '.duration_seconds, .files_new, .bytes_added'
```

The file is also POSTed to `WEBHOOK_URL` when set — see [Webhooks](../configuration/webhooks.md).

## Stability promise

Field names and types are part of the public API surface; we treat
changes the same way we treat env-var changes:

- Adding new fields is a **MINOR** bump.
- Renaming or removing a field is a **MAJOR** bump.

So a parser written today will still work for the entire 2.x lifecycle.
