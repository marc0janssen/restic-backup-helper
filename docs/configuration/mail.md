# Mail notifications

The image ships with **msmtp** wired as `/usr/sbin/sendmail` so any tool
that talks `mail(1)` (notably the worker scripts) can relay through your
SMTP provider. Mount your `msmtprc` and set `MAILX_RCPT` — that's the
whole setup.

## Quick configuration

```yaml
environment:
  MAILX_RCPT: ops@example.com
  MAILX_ON_ERROR: "ON"           # OFF (default) = mail every run
volumes:
  - ./config/msmtprc:/etc/msmtprc:ro
```

| Variable | Default | Description |
| --- | --- | --- |
| `MAILX_RCPT` | *(empty)* | Recipient address. Empty = mail disabled. |
| `MAILX_ON_ERROR` | `OFF` | When `ON`, backup / check / prune / restore / snapshot-export / forget-preview / mount-snapshot only mail on **failure**. Replicate mails only when at least one job recorded an error. |

!!! tip "Validate without waiting for a failure"

    Run [`/bin/notify-test --mail`](../operations/notify-test.md) after
    editing `msmtprc`, rotating SMTP passwords or changing `MAILX_RCPT`.
    The test uses the same `notify_mail` helper as real workers, but
    delivery failures affect the helper exit code so CI can catch them.

## Sample `msmtprc`

A minimal config that uses TLS to a third-party SMTP relay. Adjust the
account block to your provider.

```ini
# /etc/msmtprc — keep mode 0600 inside the container.
defaults
    auth            on
    tls             on
    tls_starttls    on
    tls_trust_file  /etc/ssl/certs/ca-certificates.crt
    logfile         /var/log/msmtp.log

account default
    host            smtp.example.com
    port            587
    from            backup-bot@example.com
    user            backup-bot@example.com
    password        keep-this-out-of-git
```

!!! warning "Mode 0600 inside the container"

    msmtp refuses to read its config when it is world- or group-readable.
    Mount your config with `:ro` and ensure the host file is `chmod 600`.
    The container runs as root, so `chown` is not strictly required.

## Subjects

Mail subjects (since 1.15.0) follow the pattern
`[OK|FAIL <code>] <Job> <hostname> · <duration> · <details>`, so a glance
at the inbox tells you status, host, run length and the headline metric:

| Worker | Example subject |
| --- | --- |
| Backup | `[OK] Backup larak · 5m12s · 1.234 MiB new (snap a1b2c3d4)` |
| Backup (failed) | `[FAIL 12] Backup larak · 7s · /data` |
| Check | `[OK] Check larak · 1m4s · rclone:jottacloud:backups` |
| Prune | `[OK] Prune larak · 2h14m · rclone:jottacloud:backups` |
| Replicate | `[OK] Replicate larak · 12m · 3 jobs (0 failed)` |
| Restore | `[OK] Restore larak · 1m12s · 4523 files (567.89 MiB) → /restore` |
| Restore (dry-run) | `[OK] Restore larak · 4s · DRY-RUN · 4523 files (567.89 MiB) → /restore` |
| Snapshot export | `[OK] Snapshot export larak · 1m12s · 4523 files (567.89 MiB) → /restore/snapshot-export-….tar.gz` |
| Forget preview | `[OK] Forget preview larak · 2s · rclone:jottacloud:backups` |
| Mount snapshot | `[OK] Mount snapshot larak · 12m · /restore` |

`<details>` is whichever short metric makes sense for the worker:

- **Backup**: `<bytes-added> new (snap <short-id>)` or `<paths>` on failure.
- **Check / Prune / Forget preview**: repository URL (masked).
- **Replicate**: `N jobs (X failed)`.
- **Restore / Snapshot-export**: `<files-restored> files (<bytes-restored>) → <target>`.
- **Mount snapshot**: `<target>` (the mountpoint).

If you filter mail by subject regex, lock onto `^\[(OK|FAIL \d+)\] ` —
both the OK-with-no-code and the FAIL-with-explicit-code forms are
covered.

## Body

The body is the contents of `/var/log/<worker>-mail-last.log` (or the
error log when the run failed). That means you can mail-archive the
exact log line `cron.log` would have shown, while the structured
`last-<job>.json` lives next to it for monitoring.

## Sending only on errors

`MAILX_ON_ERROR=ON` matches what most operators want once the helper is
boring: silence on green, page on red. It applies to:

- `/bin/backup`
- `/bin/check`
- `/bin/prune`
- `/bin/restore`
- `/bin/snapshot-export`
- `/bin/forget-preview`
- `/bin/mount-snapshot`

`/bin/replicate` is slightly different: it always mails when at least
one **job** in the batch fails, regardless of `MAILX_ON_ERROR`, because
the worker's overall exit code is `0` for partial failures. If you do
not want partial-failure mail, set `MAILX_RCPT` to empty for the
replicate use case (typically one worker per host) or wrap the helper
output in a pre/post-replicate hook.

## Local end-to-end testing with mailhog

The reference [`scripts/docker-compose.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/scripts/docker-compose.yml)
ships a `dev` profile that adds a [`mailhog`](https://github.com/mailhog/MailHog)
SMTP catcher (port 1025 SMTP, 8025 web UI). Point your `msmtprc` at
`host mailhog`, `port 1025`, no auth, no TLS to round-trip-test
subjects and bodies without a real relay:

```ini
account dev
    host            mailhog
    port            1025
    tls             off
    auth            off
    from            backup-bot@example.com
```

```shell
docker compose --profile dev up
# Open http://127.0.0.1:8025 to see every email the workers send.
```

## See also

- [Webhooks](webhooks.md) — push-based alternative or addition.
- [Diagnostics](../operations/diagnostics.md) — confirm `MAILX_RCPT`,
  `MAILX_ON_ERROR` and `/etc/msmtprc` readability.
- [Backup worker](../workers/backup.md) — the worker that mails most
  often.
