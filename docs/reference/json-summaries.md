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
| `job` | string | One of `backup`, `check`, `prune`, `replicate`, `restore`, `snapshot-export`. |
| `hostname` | string | Container hostname. Set explicitly in Compose / Kubernetes for stable labels. |
| `release` | string | `${VERSION}-${restic_base}` baked at build time, e.g. `2.2.2-0.18.1`. |
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
  "release": "2.2.2-0.18.1",
  "started_at": "2026-05-11T02:00:00+0200",
  "finished_at": "2026-05-11T02:05:12+0200",
  "started_epoch": 1762828800,
  "finished_epoch": 1762829112,
  "duration_seconds": 312,
  "exit_code": 0,
  "repository": "s3:https://s3.example.com/***@bucket/restic",
  "backup_root_dir": "/data",
  "restic_tag": "backup-node-data",
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

### `last-replicate.json`

| Field | Type | Description |
| --- | --- | --- |
| `replicate_jobs_processed` | integer | Number of job rows parsed and dispatched. |
| `replicate_jobs_failed` | integer | Number that failed (counting recoveries). |

```json
{
  "job": "replicate",
  "hostname": "backup-node",
  "release": "2.2.2-0.18.1",
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
  "release": "2.2.2-0.18.1",
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
