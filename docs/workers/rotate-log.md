# Log-rotation worker

`/bin/rotate_log` is the helper's minimal `logrotate` replacement,
covering exactly one file: `/var/log/cron.log`. The full configuration
surface is documented at [Log rotation](../configuration/log-rotation.md).

## Why a dedicated worker

`logrotate` is not in the upstream `restic/restic` Alpine base. Pulling
it in just for one log file is over-engineering, so the helper rolls
its own: a single bash worker, wrapped in the same `locked_run` as
every other cron entry. The worker is always scheduled
(`ROTATE_LOG_CRON`, default Saturday 00:00).

## Behaviour

| Condition | Action |
| --- | --- |
| `cron.log` size ≤ `CRON_LOG_MAX_SIZE` | No-op; exit 0. |
| `cron.log` size > `CRON_LOG_MAX_SIZE` | Rename to `cron_log_<timestamp>`, `gzip` into a `.tar.gz`, recreate an empty `cron.log`. |
| Number of `.tar.gz` archives > `MAX_CRON_LOG_ARCHIVES` | Delete oldest extras. |

The worker writes nothing to `last-rotate-log.json` (no JSON summary)
and does not emit Prometheus metrics. It is intentionally boring.

See [Log rotation](../configuration/log-rotation.md) for variables,
manual rotation and integration with external log forwarders.
