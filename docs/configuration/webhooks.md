# Webhooks

When `WEBHOOK_URL` is set, every worker POSTs the same JSON document as
`/var/log/last-<job>.json` to that endpoint after each run. The webhook
sink is **additive** with the file sink — pick either or both depending
on your monitoring stack.

## Quick configuration

```yaml
environment:
  WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
  WEBHOOK_HEADER_AUTH: "Bearer hunter2"     # optional
  WEBHOOK_TIMEOUT: "15"                      # default 10s
  WEBHOOK_ON_ERROR: "OFF"                    # default; ON = only on failure
```

| Variable | Default | Behaviour |
| --- | --- | --- |
| `WEBHOOK_URL` unset | – | No-op; nothing is posted. |
| `WEBHOOK_URL` set, `WEBHOOK_ON_ERROR=OFF` (default) | – | POST after every run regardless of exit code. |
| `WEBHOOK_URL` set, `WEBHOOK_ON_ERROR=ON` | – | POST only when the job exited with a non-zero code. |
| `WEBHOOK_HEADER_AUTH` set | – | Added as `Authorization: <value>` (`Bearer …`, `Token …`, …). Value is **never** echoed to logs. |
| `WEBHOOK_TIMEOUT` (default `10`) | – | Curl `--max-time` in seconds; a hung endpoint cannot block a backup. |

!!! info "Webhooks never fail the worker"

    Failures (curl non-zero exit, HTTP non-2xx, timeout) are logged as
    errors but **never propagate** to the worker's exit code. A flaky
    webhook endpoint cannot turn an otherwise-successful backup into a
    failed one.

!!! tip "Validate the webhook path explicitly"

    Run [`/bin/notify-test --webhook`](../operations/notify-test.md) to
    send a labelled test payload through the same `notify_webhook`
    helper. Unlike real workers, delivery failures affect the test
    helper's exit code so bad URLs, auth headers and timeouts are visible
    before the next backup.

## What is in the body

The POST body is the same JSON written to `/var/log/last-<job>.json`. Per
worker, the fields are listed in [JSON summaries](../reference/json-summaries.md);
the common subset every worker always emits is:

```json
{
  "job": "backup",
  "hostname": "backup-node",
  "release": "2.14.1-0.18.1",
  "started_at": "2026-05-11T02:00:00+0200",
  "finished_at": "2026-05-11T02:05:12+0200",
  "started_epoch": 1762828800,
  "finished_epoch": 1762829112,
  "duration_seconds": 312,
  "exit_code": 0,
  "repository": "s3:https://s3.example.com/***@bucket/restic"
}
```

The `repository` field is **masked** (`mask_repository`) — userinfo
between `://` and `@` becomes `***` before printing, posting or mailing.
Configured `rclone:` remotes hide their credentials in `rclone.conf` and
never appear in the URL at all.

## Compatible endpoints

Tested out of the box with:

| Endpoint | URL pattern | Notes |
| --- | --- | --- |
| [healthchecks.io](https://healthchecks.io) | `https://hc-ping.com/<uuid>` | Body is logged but not parsed; healthchecks only cares about HTTP status and timing. Set one check per worker if you want separate alerts. |
| Slack incoming webhook | `https://hooks.slack.com/services/T…/B…/…` | Slack expects `{"text": "…"}` — point at a small bridge (e.g. an [Apprise](https://github.com/caronc/apprise) endpoint) if you want the full JSON parsed, or write a [pre/post hook](hooks.md) that calls Slack with a custom body. |
| Discord incoming webhook | `https://discord.com/api/webhooks/…` | Same caveat as Slack. |
| Mattermost incoming webhook | `https://mattermost.example.com/hooks/…` | Same caveat. |
| [Gotify](https://gotify.net) | `https://gotify.example.com/message?token=…` | Accepts the JSON as-is via Gotify's plugin filter, or wrap in a hook. |
| [ntfy](https://ntfy.sh) | `https://ntfy.example.com/<topic>` | Supports JSON publishing via custom headers; consider a small hook for rich formatting. |
| [Apprise](https://github.com/caronc/apprise) receivers | `http://apprise.example.com/notify/<key>` | Apprise translates the JSON to whichever channel its config defines. |
| Custom HTTPS endpoint | Anything that accepts `Content-Type: application/json` POST | Most flexible; you control the schema. |

The helper's webhook stack is **stateless** — every run produces a
self-contained document. There is no retry queue: if the endpoint is
down at the moment of POST, the run is logged as a webhook failure and
the next cron tick posts the next document.

## Healthchecks.io recipe

1. Create a check per worker you care about. Most users start with one
   per host for `backup`; add `check` / `replicate` later.
2. Configure the schedule on the check side to match `BACKUP_CRON`.
3. Set `WEBHOOK_URL` to the `https://hc-ping.com/<uuid>` URL.
4. Leave `WEBHOOK_ON_ERROR=OFF` (default) so healthchecks knows the run
   happened on time even when it succeeds.

`hc-ping.com` interprets:

- An HTTP `200` POST as `success`.
- A POST to `<uuid>/fail` as `fail` — the helper does not flip the URL
  for you; if you only want failure pings, use the `/fail` form
  directly and combine with `WEBHOOK_ON_ERROR=ON`.

## Slack / Discord with a wrapping hook

Slack/Discord/Mattermost incoming webhooks want their own envelopes
(`{"text": "…"}`). The simplest pattern is to keep the helper's webhook
pointed at an HTTP collector (or leave it unset) and emit Slack messages
from a `/hooks/post-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
rc="${1:-0}"
[ "${rc}" -eq 0 ] && exit 0
[ -n "${SLACK_WEBHOOK_URL:-}" ] || exit 0
text=$(cat /var/log/last-backup.json | jq -r '"\(.hostname) backup failed (rc=\(.exit_code)) after \(.duration_seconds)s"')
curl -fsS -m 10 -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg t "${text}" '{text:$t}')" "${SLACK_WEBHOOK_URL}"
```

Combine with `WEBHOOK_URL` pointing at healthchecks.io for the green
heartbeat, and the hook for the red escalation.

## Privacy

- The **webhook URL** is logged as `scheme://host/…` only — per-recipient
  secrets in path/query (healthchecks UUIDs, Slack/Discord tokens, ntfy
  topics) never appear in `cron.log` or in `last-<job>.json`.
- The `WEBHOOK_HEADER_AUTH` value is never echoed; logs only mention
  "auth header set".
- The POST body itself can contain sensitive metadata (paths, hostname,
  release). If your endpoint is shared with third parties, treat the
  payload as operationally sensitive.

## See also

- [JSON summaries](../reference/json-summaries.md) — what is in each
  webhook body.
- [Mail notifications](mail.md) — push-based, human-readable alternative.
- [Hooks](hooks.md) — fan-out to channel-specific formats from a single
  source of truth.
