# Sources report

`/bin/sources-report` is a **read-only pre-flight inventory** of the
paths your backup will actually read. It answers four questions in one
go, before `BACKUP_CRON` ever ticks:

1. Is `BACKUP_ROOT_DIR` mounted, readable, and the kind of thing I
   think it is?
2. Are the `--files-from` files referenced in `RESTIC_JOB_ARGS`
   readable, non-empty, and do their listed entries actually exist on
   disk inside the container?
3. Are the `--exclude-file` files readable, and how many pattern lines
   are in each?
4. Roughly how big is the data set (file count + bytes)? — so the
   estimated backup window stays a planning number rather than a
   surprise.

It is **operator-initiated** and never cron-driven by itself.

## Why it exists

Backups silently widen or narrow when:

- a bind-mount disappears (`BACKUP_ROOT_DIR` becomes an empty
  directory and the next backup looks "fine, just smaller"),
- a `--files-from` file accumulates stale entries (rows that point at
  paths the operator removed months ago — those backups silently skip
  parts of the dataset),
- an `--exclude-file` is mistyped in `RESTIC_JOB_ARGS` and restic
  silently treats the missing pattern source as "no excludes",
- a freshly cloned host inherits a list of paths that don't exist
  there yet.

`/bin/doctor` catches these as boolean
`readable / not-readable / missing` warnings. `/bin/sources-report`
goes one step further: it tells you **how much data is behind each
source**, so a `--files-from` typo that drops 80 % of the dataset is
visible at a glance instead of "discovered" three retention cycles
later.

## Quick start

```shell
# Default scope: BACKUP_ROOT_DIR + every --files-from / --exclude-file
# discovered in RESTIC_JOB_ARGS.
docker exec -ti restic-backup-helper /bin/sources-report

# Fast mode for slow / remote sources (NFS, SFTP, cloud mounts):
# skip `du -sk` and file-count, only check readability + type.
docker exec -ti restic-backup-helper /bin/sources-report --no-size

# Ad-hoc inspection of an extra path that isn't in BACKUP_ROOT_DIR /
# RESTIC_JOB_ARGS yet. Repeatable.
docker exec -ti restic-backup-helper /bin/sources-report \
  --source /mnt/new-dataset --source /mnt/backup-staging

# One-shot via docker run (no cron startup) — useful in CI smoke jobs.
docker run --rm \
  --env-file restic.env \
  -v /srv/documents:/data:ro \
  -v ./config:/config:ro \
  marc0janssen/restic-backup-helper:latest \
  sources-report --no-size
```

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--source PATH` | – | Add an ad-hoc path to inspect. Repeatable. By default the report covers `BACKUP_ROOT_DIR` plus every `--files-from` referenced in `RESTIC_JOB_ARGS`. |
| `--files-from FILE` | – | Add a `--files-from` file to inspect. Repeatable. By default the report scans `RESTIC_JOB_ARGS` for them. |
| `--no-size` | off | Skip size estimation (`du -sk` + `find -type f`). Only check readability, type and the line counts of `--files-from` / `--exclude-file`. Recommended on slow / remote sources. |
| `--depth N` | unlimited | Cap directory traversal depth at `N` levels when counting files. No effect with `--no-size`. Useful on very large trees. |
| `--help` | – | Print usage and exit. |

## What it does

```mermaid
flowchart TD
    A[sources-report] --> B[pre-sources-report hook]
    B --> C{Compose scope}
    C --> C1[BACKUP_ROOT_DIR<br/>+ --source flags]
    C --> C2[--files-from in RESTIC_JOB_ARGS<br/>+ --files-from flags]
    C --> C3[--exclude-file in RESTIC_JOB_ARGS]
    C1 --> D{per source}
    D --> D1[stat: type<br/>readable?]
    D1 --> D2{--no-size?}
    D2 -- no --> D3[du -sk + find -type f]
    D2 -- yes --> D4[skip sizing]
    C2 --> E{per files-from}
    E --> E1[readable?<br/>count non-comment lines<br/>check each entry exists]
    C3 --> F{per exclude-file}
    F --> F1[readable?<br/>count pattern lines]
    D3 --> G[Aggregate totals]
    D4 --> G
    E1 --> G
    F1 --> G
    G --> H[Render log table]
    H --> I[Write last-sources-report.json<br/>with nested sources / files_from / exclude_files arrays]
    I --> J[Optional restic_sources_report.prom]
    J --> K{MAILX_RCPT? WEBHOOK_URL?}
    K --> L[mail + webhook]
    L --> M[post-sources-report hook with "$rc"]
```

## Scope discovery

The default scope mirrors exactly what `/bin/backup` would feed
restic:

```text
sources       = BACKUP_ROOT_DIR (if set)
              + each --source PATH from the CLI
files_from    = every --files-from / --files-from-verbatim /
                --files-from-raw value found in RESTIC_JOB_ARGS
              + each --files-from FILE from the CLI
exclude_files = every --exclude-file / --iexclude-file value found in
                RESTIC_JOB_ARGS
```

So the report is grounded in the same env-driven contract as the
backup itself; you don't have to keep two lists in sync.

## Estimate semantics

- **Size figure is unfiltered.** `du -sk` is run on each source
  without applying restic's exclude rules. The report lists exclude
  files separately so you can reason about expected exclusions
  yourself; the helper deliberately does **not** re-implement
  restic's matcher.
- **`du -sk` is POSIX-portable.** Works on both BusyBox `du` (Alpine
  default) and GNU `coreutils` `du`. Kilobytes are multiplied by
  `1024` to get the bytes figure in the JSON.
- **File count uses `find -type f`.** Symlinks pointing at directories
  are not followed (matches what restic actually stores).
- **`--depth N` caps `find` depth.** Useful on huge trees, at the
  cost of an under-count for deeper hierarchies — the JSON `files`
  field reflects the cap, not the true number.
- **`--no-size` reports `-1` for `files` and `bytes`.** The JSON
  encodes `-1` rather than `0` so consumers can distinguish "skipped"
  from "really empty".

## Audit trail

The helper writes:

- `/var/log/sources-report-last.log` — human-readable table + per-source
  / per-files-from / per-exclude-file details.
- `/var/log/sources-report-error-last.log` — copied on failure.
- `/var/log/last-sources-report.json` — flat aggregates plus nested
  `sources`, `files_from`, `exclude_files` arrays.
- `restic_sources_report.prom` — when `METRICS_DIR` is configured.

Hooks:

```text
/hooks/pre-sources-report.sh                # informational; failure does not abort the report
/hooks/post-sources-report.sh "$exit_code"  # always called with the report exit code as $1
```

Mail and webhook notifications use the same `MAILX_*` and `WEBHOOK_*`
settings as the cron-driven workers.

## JSON summary

In addition to the common fields (`job`, `hostname`, `release`,
`started_at`, `finished_at`, `duration_seconds`, `exit_code`):

| Field | Type | Description |
| --- | --- | --- |
| `backup_root_dir` | string | Value of `BACKUP_ROOT_DIR` at report time. |
| `sources_count` | integer | Number of unique source paths inspected (BACKUP_ROOT_DIR + `--source`). |
| `files_from_count` | integer | Number of `--files-from` files inspected. |
| `exclude_files_count` | integer | Number of `--exclude-file` files inspected. |
| `total_files` | integer | Sum of `find -type f` counts across all sized sources. `0` when `--no-size` was set. |
| `total_bytes` | integer | Sum of `du -sk * 1024` across all sized sources. `0` when `--no-size` was set. |
| `errors_count` | integer | Count of unreadable / missing entries (sources, `--files-from` files themselves, `--files-from` line contents, `--exclude-file` files). |
| `no_size` | string | `ON` / `OFF` mirroring `--no-size`. |
| `depth_limit` | string | `--depth N` value, or `unlimited`. |
| `sources` | array | Per-source detail: `{path, readable, type, files, bytes}`. `files` / `bytes` are `-1` when `--no-size` was set. |
| `files_from` | array | Per-file detail: `{path, readable, lines, missing_entries}`. |
| `exclude_files` | array | Per-file detail: `{path, readable, patterns}`. |

Example:

```json
{
  "job": "sources-report",
  "hostname": "backup-node",
  "release": "2.10.0-0.18.1",
  "started_at": "2026-05-13T15:30:00+0200",
  "finished_at": "2026-05-13T15:30:08+0200",
  "duration_seconds": 8,
  "exit_code": 0,
  "backup_root_dir": "/data",
  "sources_count": 2,
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

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Report produced. Individual unreadable entries are signalled via `errors_count` in the JSON (and the log) but do not by themselves trigger a non-zero exit. |
| `2` | Configuration error: no sources to inspect (`BACKUP_ROOT_DIR` empty, no `--source`, no `--files-from` discovered or passed), or invalid `--depth`. |

The "always exit `0` even with unreadable entries" choice is
intentional: this is a **report**, not a gate. Wire alerts on
`restic_sources_report_last_errors_count > 0` if you want loud CI
behaviour.

## When to use it

- **Before configuring a new backup**, especially when you reuse an
  existing `--files-from` from another host or a documentation
  template.
- **After editing `RESTIC_JOB_ARGS`** in your env file.
- **As a CI smoke step.** Cheap pre-flight: catches missing mounts,
  unreadable secrets, silently-empty `--files-from` files, and
  size deltas the next backup will produce. Combine with
  `/bin/doctor` for a complete pre-flight bundle.
- **After a host migration or a Docker Compose reshuffle**, to
  confirm bind-mounts still resolve where the env says they should.

## See also

- [Backup worker](../workers/backup.md) — same `BACKUP_ROOT_DIR` /
  `RESTIC_JOB_ARGS` contract; this helper inspects it without taking
  a lock.
- [Forget preview](forget-preview.md) — same operator-driven pattern,
  for retention policy.
- [Diagnostics (doctor)](diagnostics.md) — overlapping path checks at
  a coarser granularity; doctor reports readability without sizes.
- [JSON summaries](../reference/json-summaries.md) — schema for
  `last-sources-report.json`.
- [Prometheus metrics](../reference/prometheus-metrics.md) —
  `restic_sources_report_*` gauges.
- [Hooks](../configuration/hooks.md) — `pre-sources-report` /
  `post-sources-report` registration.
