# Prometheus metrics

When `METRICS_DIR` points at a writable directory inside the container,
every worker also writes a `restic_<job>.prom` text file alongside the
`last-<job>.json`. Mount that directory into the host and point a
node-exporter `--collector.textfile.directory` at it — no push gateway
required.

## Enabling

```yaml
environment:
  METRICS_DIR: /var/log/textfile_collector
volumes:
  - ./metrics:/var/log/textfile_collector
```

Then on the host:

```shell
node_exporter --collector.textfile.directory=./metrics
```

That's the whole setup. Files are written via `*.tmp` + `mv`, so a
node-exporter scrape never observes a partially-written file.

## Files produced

One file per worker that has run at least once. Files are overwritten
each run.

```text
${METRICS_DIR}/
├── restic_backup.prom
├── restic_check.prom
├── restic_prune.prom
├── restic_replicate.prom
├── restic_restore.prom
└── restic_snapshot_export.prom
```

## Always-emitted gauges

Per worker `<job>` ∈ `backup`, `check`, `prune`, `replicate`, `restore`,
`snapshot_export`:

| Metric | Meaning |
| --- | --- |
| `restic_<job>_last_exit_code{hostname="…"}` | Exit code of the most recent run. |
| `restic_<job>_last_success{hostname="…"}` | `1` when exit code was `0`, else `0`. |
| `restic_<job>_last_duration_seconds{hostname="…"}` | Wall-clock duration of the run. |
| `restic_<job>_last_finished_timestamp{hostname="…"}` | Unix epoch seconds at which the run ended. |
| `restic_<job>_last_started_timestamp{hostname="…"}` | Unix epoch seconds at which the run started. |

The `hostname` label comes from the container hostname (set explicitly in
Compose / Kubernetes with `hostname:`). Set one container per host so the
label is unique.

## Worker-specific extras

Extra numeric fields in `last-<job>.json` are emitted as
`restic_<job>_last_<key>`. Non-numeric extras (human-formatted byte
strings like `"1.234 MiB"`, the masked `repository`) are intentionally
skipped to keep the textfile strictly typed for Prometheus.

| Worker | Extra metrics |
| --- | --- |
| `backup` | `restic_backup_last_files_new`, `_files_changed`, `_files_unmodified`, `_dirs_new`, `_dirs_changed`, `_dirs_unmodified`, `_bytes_added`, `_bytes_stored` (when restic produced bytes as a number). |
| `replicate` | `restic_replicate_last_replicate_jobs_processed`, `_replicate_jobs_failed`. |
| `restore`, `snapshot_export` | `restic_restore_last_files_restored`, `_bytes_restored` (when restic produced them as numbers). |

## Useful PromQL

### Time since last successful backup

```promql
time() - restic_backup_last_finished_timestamp{hostname="backup-node"} > 26 * 3600
```

Fires when no backup has finished in the last 26 hours (a typical
threshold for a daily 02:00 cron with some slack).

### Backup failed yesterday

```promql
restic_backup_last_success{hostname="backup-node"} == 0
```

### Restic check skipped or stale

```promql
time() - restic_check_last_finished_timestamp{hostname="backup-node"} > 8 * 24 * 3600
```

If you schedule `CHECK_CRON` weekly, this alert means it has been skipped
or repeatedly failing for over a week.

### Replicate jobs failing

```promql
restic_replicate_last_replicate_jobs_failed > 0
```

### Backup running long

```promql
restic_backup_last_duration_seconds > 6 * 3600
```

Combine with the `time()` filter to catch a runaway backup that finished
recently rather than alerting on every historical long run.

## Example alert rules

```yaml
groups:
  - name: restic-backup-helper
    rules:
      - alert: BackupOverdue
        expr: time() - restic_backup_last_finished_timestamp > 26*3600
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Backup overdue on {{ $labels.hostname }}"
          description: "Last successful backup was over 26h ago."

      - alert: BackupFailed
        expr: restic_backup_last_success == 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Backup failed on {{ $labels.hostname }}"
          description: "Exit code {{ $value }}; see /var/log/last-backup.json."

      - alert: ReplicateJobsFailed
        expr: restic_replicate_last_replicate_jobs_failed > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "{{ $value }} replicate jobs failed on {{ $labels.hostname }}"
          description: "See /var/log/last-replicate.json for details."
```

## Compose `metrics` profile

The reference [`scripts/docker-compose.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/scripts/docker-compose.yml)
ships a `metrics` Compose profile that adds a `node-exporter` sidecar
bound to `127.0.0.1:9100` and scraping the `backup-logs` volume's
`textfile_collector/` subdirectory:

```shell
docker compose --profile metrics up
curl -fsS http://127.0.0.1:9100/metrics | grep restic_backup_last
```

No host-level node-exporter required.

## See also

- [JSON summaries](../reference/json-summaries.md) — the source of every
  numeric metric.
- [Webhooks](webhooks.md) — push-based alternative.
- [Filesystem layout](../concepts/filesystem-layout.md) — where the
  files live inside the container.
