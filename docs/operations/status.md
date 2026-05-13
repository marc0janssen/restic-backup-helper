# Status / health summary

`/bin/status` is the quick daily operator view. It is intentionally much
lighter than [`/bin/doctor`](diagnostics.md): it **only reads local
container state** and never calls `restic`, `rclone`, hooks, mail,
webhooks or repository probes.

Use it for "is this container broadly healthy?" checks:

- release, hostname, timezone and masked repository;
- rendered crontab (or environment-derived preview in one-shot mode);
- enabled / disabled schedule state for `backup`, `check`, `forget`,
  `prune`, `replicate` and `rotate_log`;
- latest `last-*.json` files under `/var/log`;
- age and exit code for scheduled `backup`, `check`, `forget`, `prune`
  and `replicate` runs;
- compact `OK` / `WARN` / `FAIL` verdict.

`/bin/health-summary` is a symlink alias for the same command.

## Quick start

```shell
docker exec -ti restic-backup-helper /bin/status

# Same command through the entrypoint dispatcher.
docker run --rm --env-file restic.env \
  marc0janssen/restic-backup-helper:latest \
  status

# Alias, useful when the name reads better in runbooks.
docker exec -ti restic-backup-helper /bin/health-summary
```

Example text output:

```text
restic-backup-helper status: OK
release:            2.14.0-0.18.1
hostname:           backup-node
time:               2026-05-13 Wed 23:25:00 CEST
repository:         rclone:jottacloud:backups
warnings/failures:  0/0

== Schedules ==
crontab source:     /var/spool/cron/crontabs/root (3 line(s))
  job        state    cron
  backup     enabled  0 */6 * * *
  check      enabled  30 2 * * *
  forget     disabled -
  prune      enabled  0 3 * * 0
  replicate  disabled -
  rotate_log enabled  0 0 * * 6

== Core Job Ages ==
  job        status     exit     age        detail
  backup     ok         0        1h 12m     last exit 0, age 1h 12m
  check      ok         0        20h 3m     last exit 0, age 20h 3m
  forget     disabled   -        -          disabled
  prune      ok         0        3d 4h      last exit 0, age 3d 4h
  replicate  disabled   -        -          disabled
```

## Health rules

| Verdict | Meaning |
| --- | --- |
| `OK` | All enabled core jobs have a successful recent JSON summary. |
| `WARN` | An enabled core job has no `last-*.json` yet, looks stale for a simple cron expression, or a non-scheduled helper JSON reports a non-zero exit. |
| `FAIL` | An enabled core job (`backup`, `check`, `forget`, `prune`, `replicate`) has a non-zero last exit code. |

The status command treats helper failures (`restore`, `restore-test`,
`snapshot-export`, `notify-test`, etc.) as warnings, not hard failures,
because they are usually operator-triggered rather than cron-driven
service health. They are still visible in **Recent JSON** and
`findings[]`.

Staleness is intentionally conservative and only applied when the cron
expression is simple enough to understand:

- `*/N * * * *` (every N minutes)
- `M */N * * *` (every N hours)
- `M H * * *` (daily)
- `M H * * D` (weekly-ish)
- `M H D * *` (monthly-ish)

The warning threshold is three expected intervals plus ten minutes of
slack. Custom cron expressions still show age, but do not trigger stale
warnings.

## JSON mode

```shell
docker exec restic-backup-helper /bin/status --json | jq '.verdict, .findings'
docker run --rm --env-file restic.env marc0janssen/restic-backup-helper:latest health-summary --json
```

Schema: `restic-backup-helper.status/1`.

| Field | Type | Description |
| --- | --- | --- |
| `schema` | string | Constant `restic-backup-helper.status/1`. |
| `command` | string | Constant `status`. |
| `release` / `hostname` | string | Baked release and container hostname. |
| `generated_at` / `generated_epoch` | string / integer | Generation time in container timezone and Unix epoch. |
| `verdict` | string | `OK`, `WARN` or `FAIL`. |
| `warnings` / `failures` | integer | Count of generated findings by severity. |
| `exit_code` | integer | `0` for `OK` / `WARN`, `1` for `FAIL`. |
| `runtime` | object | `tz` and masked `repository`. |
| `crontab` | object | `source`, `path`, `line_count`. |
| `schedules[]` | array | One entry per known schedule (`job`, `enabled`, `cron`, `command`). |
| `jobs[]` | array | Core job health rows (`job`, `enabled`, `core`, `status`, `cron`, `path`, `present`, `exit_code`, `age_seconds`, `age_human`, `finished_at`, `detail`). |
| `recent_json[]` | array | One entry per known `/var/log/last-*.json` (`job`, `path`, `present`, `exit_code`, `age_seconds`, `age_human`). |
| `findings[]` | array | Compact `{level, message}` summary of WARN / FAIL conditions. |

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Verdict is `OK` or `WARN`. |
| `1` | Verdict is `FAIL` (at least one enabled core job has a non-zero last exit). |
| `2` | Bad CLI usage. |

## See also

- [Diagnostics (doctor)](diagnostics.md) — deeper support bundle with config checks and repository probe.
- [Cron list](diagnostics.md) — verbose crontab and schedule explanation.
- [JSON summaries](../reference/json-summaries.md) — per-worker `last-*.json` files consumed by `/bin/status`.
