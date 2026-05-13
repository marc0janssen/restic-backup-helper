# Prometheus metrics reference

When `METRICS_DIR` is set, every worker writes a `restic_<job>.prom`
text file alongside its `last-<job>.json`. This page is the canonical
reference for the metric names and labels. See
[Configuration → Prometheus metrics](../configuration/metrics.md) for
setup and example PromQL.

## Files produced

One file per worker that has run at least once. Files are overwritten
each run and written via `*.tmp` + `mv` so a scrape never sees a
partial document.

```text
${METRICS_DIR}/
├── restic_backup.prom
├── restic_check.prom
├── restic_forget.prom            # only when FORGET_CRON is set
├── restic_prune.prom
├── restic_replicate.prom
├── restic_restore.prom
├── restic_snapshot_export.prom
├── restic_forget_preview.prom
├── restic_mount_snapshot.prom
├── restic_unlock.prom              # only when /bin/unlock has been run
├── restic_sources_report.prom      # only when /bin/sources-report has been run
├── restic_init_repo.prom           # only when /bin/init-repo has been run
├── restic_notify_test.prom         # only when /bin/notify-test has been run
└── restic_restore_test.prom        # only when /bin/restore-test has been run
```

## Always-emitted gauges

For each `<job>` ∈ `backup`, `check`, `forget`, `prune`, `replicate`,
`restore`, `snapshot_export`, `forget_preview`, `mount_snapshot`,
`unlock`, `sources_report`, `init_repo`, `notify_test`, `restore_test`:

| Metric | Type | Description |
| --- | --- | --- |
| `restic_<job>_last_exit_code{hostname="…"}` | gauge | Exit code of the most recent run. |
| `restic_<job>_last_success{hostname="…"}` | gauge | `1` when exit code was `0`, else `0`. |
| `restic_<job>_last_duration_seconds{hostname="…"}` | gauge | Wall-clock duration of the run. |
| `restic_<job>_last_started_timestamp{hostname="…"}` | gauge | Unix epoch seconds at start. |
| `restic_<job>_last_finished_timestamp{hostname="…"}` | gauge | Unix epoch seconds at finish. |

The `hostname` label comes from the container's hostname (set
explicitly in Compose / Kubernetes with `hostname:`). Run one container
per logical job so the label is unique. The label value is escaped
before writing, so unusual hostnames containing quotes, backslashes or
newlines do not break the textfile format.

## Worker-specific gauges

Extra numeric fields in `last-<job>.json` are emitted as
`restic_<job>_last_<key>`. Non-numeric extras (human-formatted byte
strings like `"1.234 MiB"`, the masked `repository`) are intentionally
skipped to keep the textfile strictly typed for Prometheus.

| Worker | Metric | Source |
| --- | --- | --- |
| `backup` | `restic_backup_last_files_new` | `files_new` |
| `backup` | `restic_backup_last_files_changed` | `files_changed` |
| `backup` | `restic_backup_last_files_unmodified` | `files_unmodified` |
| `backup` | `restic_backup_last_dirs_new` | `dirs_new` |
| `backup` | `restic_backup_last_dirs_changed` | `dirs_changed` |
| `backup` | `restic_backup_last_dirs_unmodified` | `dirs_unmodified` |
| `backup` | `restic_backup_last_bytes_added` | `bytes_added` (when numeric) |
| `backup` | `restic_backup_last_bytes_stored` | `bytes_stored` (when numeric) |
| `backup` | `restic_backup_last_forget_exit_code` | `forget_exit_code` — inline forget result (`0` ok, `11` skipped because another host held the exclusive lock, other = restic failure). Only emitted when an inline forget actually ran (i.e. `RESTIC_FORGET_ARGS` set **and** `FORGET_CRON` empty). |
| `forget` | `restic_forget_last_exit_code` | Top-level `exit_code` of the dedicated worker (`0`, `2` for empty policy, `11` for multi-host lock race, other = restic failure). Same alerting target as `restic_backup_last_forget_exit_code` for deployments that opted into `FORGET_CRON`. |
| `replicate` | `restic_replicate_last_replicate_jobs_processed` | `replicate_jobs_processed` |
| `replicate` | `restic_replicate_last_replicate_jobs_failed` | `replicate_jobs_failed` |
| `restore`, `snapshot_export`, `restore_test` | `restic_<job>_last_files_restored` | `files_restored` |
| `restore`, `snapshot_export`, `restore_test` | `restic_<job>_last_bytes_restored` | `bytes_restored` (when numeric) |
| `snapshot_export` | `restic_snapshot_export_last_archive_size_bytes` | `archive_size_bytes` |
| `restore_test` | `restic_restore_test_last_canary_total` | `canary_total` |
| `restore_test` | `restic_restore_test_last_canary_passed` | `canary_passed` |
| `restore_test` | `restic_restore_test_last_canary_failed` | `canary_failed` |

The `bytes_*` metrics are only emitted when the underlying JSON field
is a number. Restic's textual `bytes_added="1.234 MiB"` is **not**
mapped to a metric — preserve the typed view for Prometheus and consult
the JSON for the human-formatted variant.

## Sample `.prom` file

```text
# HELP restic_backup_last_exit_code Exit code of the most recent backup run.
# TYPE restic_backup_last_exit_code gauge
restic_backup_last_exit_code{hostname="backup-node"} 0
# HELP restic_backup_last_success 1 if the most recent backup succeeded, 0 otherwise.
# TYPE restic_backup_last_success gauge
restic_backup_last_success{hostname="backup-node"} 1
# HELP restic_backup_last_duration_seconds Wall-clock duration of the most recent backup run.
# TYPE restic_backup_last_duration_seconds gauge
restic_backup_last_duration_seconds{hostname="backup-node"} 312
# HELP restic_backup_last_started_timestamp Unix epoch at which the most recent backup started.
# TYPE restic_backup_last_started_timestamp gauge
restic_backup_last_started_timestamp{hostname="backup-node"} 1762828800
# HELP restic_backup_last_finished_timestamp Unix epoch at which the most recent backup finished.
# TYPE restic_backup_last_finished_timestamp gauge
restic_backup_last_finished_timestamp{hostname="backup-node"} 1762829112
# HELP restic_backup_last_files_new Files added by the most recent backup run.
# TYPE restic_backup_last_files_new gauge
restic_backup_last_files_new{hostname="backup-node"} 12
# HELP restic_backup_last_files_changed Files changed by the most recent backup run.
# TYPE restic_backup_last_files_changed gauge
restic_backup_last_files_changed{hostname="backup-node"} 4
# HELP restic_backup_last_files_unmodified Files unmodified in the most recent backup run.
# TYPE restic_backup_last_files_unmodified gauge
restic_backup_last_files_unmodified{hostname="backup-node"} 21034
```

## node-exporter scrape

```shell
node_exporter --collector.textfile.directory=/var/log/textfile_collector
```

For Compose: `docker compose --profile metrics up` spins a sidecar
that scrapes the volume directly — see [Docker Compose](../deployment/docker-compose.md).

## Useful PromQL

| Question | Query |
| --- | --- |
| Time since last successful backup | `time() - restic_backup_last_finished_timestamp{hostname="backup-node"}` |
| Did the latest backup fail? | `restic_backup_last_success{hostname="backup-node"} == 0` |
| Backup running long | `restic_backup_last_duration_seconds > 6*3600` |
| Replicate partial failure | `restic_replicate_last_replicate_jobs_failed > 0` |
| Restore zero-match warning | `restic_restore_last_files_restored == 0 and restic_restore_last_success == 1` (look at `last-restore.json` `include_zero_match` to confirm) |
| Restore rehearsal failed | `restic_restore_test_last_success == 0` (drill into `/var/log/last-restore-test.json` to see whether it was a canary mismatch vs file-count floor vs restic error) |
| Restore rehearsal stale | `time() - restic_restore_test_last_finished_timestamp > 7*86400` (no successful rehearsal in the last 7 days) |

## Stability promise

Metric names and label sets are part of the public API surface.
Adding new metrics is a **MINOR** bump; renaming or removing a metric
is a **MAJOR** bump.
