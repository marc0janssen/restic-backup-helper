# Notify test

`/bin/notify-test` sends a clearly-labelled test mail and/or webhook
through the **same `notify_mail` / `notify_webhook` helpers** used by
real workers. Use it to validate `msmtprc`, `MAILX_RCPT`, `WEBHOOK_URL`,
`WEBHOOK_HEADER_AUTH` and `WEBHOOK_TIMEOUT` before waiting for a real
backup failure.

## Quick start

```shell
# Test every configured target (mail if MAILX_RCPT is set, webhook if WEBHOOK_URL is set).
docker exec -ti restic-backup-helper /bin/notify-test

# Mail only.
docker exec -ti restic-backup-helper /bin/notify-test --mail

# Webhook only, with no delivery.
docker exec -ti restic-backup-helper /bin/notify-test --webhook --dry-run

# One-shot container entrypoint shortcut.
docker run --rm \
  --env-file restic.env \
  -v ./config/msmtprc:/etc/msmtprc:ro \
  marc0janssen/restic-backup-helper:latest \
  notify-test --mail --message "testing smtp relay after password rotation"
```

## Options

| Flag | Purpose |
| --- | --- |
| `--mail` | Test mail only. Fails with exit `2` when `MAILX_RCPT` is empty. |
| `--webhook` | Test webhook only. Fails with exit `2` when `WEBHOOK_URL` is empty. |
| `--all` | Test both targets. Missing config for either target is an exit-`2` configuration error. |
| `--dry-run` | Print what would be sent without invoking `mail` or `curl`. JSON, metrics and hooks are still written. |
| `--subject TEXT` | Override the default subject prefix / webhook detail (`Notify test`). |
| `--message TEXT` | Add an operator message to the log body and JSON payload. |

Default mode is `auto`: send to every configured target and fail with
exit `2` when neither `MAILX_RCPT` nor `WEBHOOK_URL` is set.

## Behaviour

- Mail delivery calls `notify_mail` with an explicit "send now"
  override, so `MAILX_ON_ERROR=ON` does not suppress the test mail.
- Webhook delivery calls `notify_webhook` with `WEBHOOK_ON_ERROR=OFF`
  for this call only, so `WEBHOOK_ON_ERROR=ON` does not suppress the
  test payload. The original value is still logged and written to JSON.
- Unlike real backup/check/prune jobs, delivery failures **do affect**
  `/bin/notify-test`'s exit code. That is the point of the helper:
  a broken SMTP relay, bad auth header, failing DNS lookup or webhook
  timeout should fail the test run.

## Audit trail

The helper writes:

- `/var/log/notify-test-last.log` — test body and delivery output.
- `/var/log/notify-test-mail-last.log` — verbose `mail -v` / msmtp output.
- `/var/log/notify-test-error-last.log` — copied on failure.
- `/var/log/last-notify-test.json` — see schema below.
- `restic_notify_test.prom` — when `METRICS_DIR` is configured.

Hooks:

```text
/hooks/pre-notify-test.sh                # informational; failure does not abort
/hooks/post-notify-test.sh "$exit_code"  # always called with the helper exit code as $1
```

## JSON summary

In addition to the common fields (`job`, `hostname`, `release`,
`started_at`, `finished_at`, `duration_seconds`, `exit_code`):

| Field | Description |
| --- | --- |
| `target_mode` | `auto`, `mail`, `webhook` or `all`. |
| `dry_run` | `ON` / `OFF`. |
| `mail_requested` / `webhook_requested` | Whether the helper attempted that target. |
| `mail_configured` / `webhook_configured` | Whether `MAILX_RCPT` / `WEBHOOK_URL` was set. |
| `mail_result` / `webhook_result` | `delivered`, `failed`, `dry-run` or `skipped`. |
| `mail_rc` / `webhook_rc` | Raw return code from `notify_mail` / `notify_webhook`. |
| `webhook_url` | Masked webhook URL (`scheme://host/...`). |
| `webhook_auth_header_set` | `ON` when `WEBHOOK_HEADER_AUTH` was present. |
| `mail_on_error` / `webhook_on_error` | Original policy values observed at runtime. |
| `webhook_timeout` | Effective `WEBHOOK_TIMEOUT` value passed to curl. |
| `subject` | Subject prefix / webhook detail. |
| `message` | Optional operator message. |
| `duration_so_far_seconds` | Runtime at the moment the JSON extras were rendered. |

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Requested test notification(s) delivered, or dry-run completed. |
| `1` | At least one requested delivery failed (`mailx` / msmtp / curl). |
| `2` | Configuration or argument error (no targets, missing requested target). |

## See also

- [Mail notifications](../configuration/mail.md) — msmtp / mailx setup.
- [Webhooks](../configuration/webhooks.md) — payloads, auth header and timeout knobs.
- [Hooks](../configuration/hooks.md) — `pre-notify-test` / `post-notify-test`.
- [JSON summaries](../reference/json-summaries.md) — `last-notify-test.json`.
- [Prometheus metrics](../reference/prometheus-metrics.md) — `restic_notify_test_*` gauges.
