# Quick start

The fastest path from zero to "container is backing up every night and yelling
when something breaks".

!!! warning "Do not commit secrets"

    Real `RESTIC_PASSWORD`, cloud API keys, SMTP passwords and webhook tokens
    must live in a gitignored `.env`, a Docker secret, or an orchestrator
    secret store — never inline in a committed `docker-compose.yml`.

## Minimal Docker run

```shell
docker run -d \
  --name restic-backup-helper \
  -e RESTIC_REPOSITORY='s3:https://s3.amazonaws.com/my-bucket/restic' \
  -e RESTIC_PASSWORD='use-a-strong-secret' \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /srv/backup-src:/data:ro \
  -v restic-config:/config \
  marc0janssen/restic-backup-helper:latest
```

What you just told the container:

- back up `/data` (mounted read-only from `/srv/backup-src`)
- at `02:00` every day in `Europe/Amsterdam` (the default `TZ`)
- to an S3 bucket
- tagging every snapshot `daily`

That's it — no further setup needed for the happy path. `restic init` is
automatic on first run if the repository does not yet exist (`restic cat
config` exits with code `10`; any other non-zero exit aborts startup so a
transient outage never silently re-initialises a healthy remote).

## Minimal Docker Compose

A more idiomatic shape with secrets and a named volume for logs:

```yaml
services:
  restic-backup:
    image: marc0janssen/restic-backup-helper:latest
    container_name: restic-backup-helper
    hostname: backup-node
    restart: unless-stopped
    environment:
      RESTIC_REPOSITORY: s3:https://s3.amazonaws.com/my-bucket/restic
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      RESTIC_TAG: daily
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      TZ: Europe/Amsterdam
    secrets:
      - restic_password
    volumes:
      - /srv/documents:/data:ro
      - ./config:/config:ro
      - backup-logs:/var/log
      - restic-cache:/.cache/restic

secrets:
  restic_password:
    file: ./restic.password

volumes:
  backup-logs:
  restic-cache:
```

`chmod 600 ./restic.password` and add it to `.gitignore`.

## Verify the install

Once the container is up, run any of the following from your host:

```shell
docker logs -f restic-backup-helper
docker exec -ti restic-backup-helper /bin/doctor
docker exec -ti restic-backup-helper /bin/backup
docker exec -ti restic-backup-helper restic snapshots
docker exec -ti restic-backup-helper cat /var/log/last-backup.json
```

- `docker logs` tails `/var/log/cron.log` — cron ticks, hook output, masked
  repository URLs and worker exit codes go there.
- `/bin/doctor` is the read-only support bundle: env, paths, repository
  probe, replicate validation, hook status, recent JSON summaries.
- `/bin/backup` runs the backup worker right now, with the same code path
  as the cron job.
- `last-backup.json` is the structured per-run summary; see
  [JSON summaries](../reference/json-summaries.md).

## Add notifications

Pick whichever combination you actually monitor:

=== "Mail (msmtp)"

    ```yaml
    environment:
      MAILX_RCPT: ops@example.com
      MAILX_ON_ERROR: "ON"
    volumes:
      - ./config/msmtprc:/etc/msmtprc:ro
    ```

    Mail subjects look like
    `[OK] Backup backup-node · 5m12s · 1.234 MiB new (snap a1b2c3d4)`
    or `[FAIL 12] Check backup-node · 7s · …`. See
    [Mail notifications](../configuration/mail.md).

=== "Webhook"

    ```yaml
    environment:
      WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
      WEBHOOK_TIMEOUT: "15"
      WEBHOOK_ON_ERROR: "OFF"   # POST every run; ON = only on failure
    ```

    The webhook POST body is the same JSON as `last-<job>.json`. Works
    out of the box with healthchecks.io, Slack, Discord, Gotify, ntfy
    and any custom JSON endpoint. See [Webhooks](../configuration/webhooks.md).

=== "Prometheus textfile"

    ```yaml
    environment:
      METRICS_DIR: /var/log/textfile_collector
    volumes:
      - ./metrics:/var/log/textfile_collector
    ```

    Point a `node-exporter --collector.textfile.directory` at `./metrics`.
    See [Prometheus metrics](../reference/prometheus-metrics.md).

## What to read next

- [Architecture](../concepts/architecture.md) — entrypoint, cron wiring,
  worker scripts, `locked_run`.
- [Filesystem layout](../concepts/filesystem-layout.md) — which paths matter
  and what to mount.
- [Backup worker](../workers/backup.md) — full configuration surface for the
  default cron job.
- [Hardening](../deployment/hardening.md) — `cap_drop`, `read_only: true` +
  tmpfs, `no-new-privileges`, Kubernetes `securityContext`.
