# Docker Compose

A reference Compose stack that exercises every option exposed by the
image. Trim what you don't need; the **only** strictly required keys
are `RESTIC_REPOSITORY`, a password (`RESTIC_PASSWORD_FILE` or
`RESTIC_PASSWORD`), `RESTIC_TAG`, `BACKUP_CRON` and a backup source
mounted into the container.

!!! warning "Secrets do not belong in committed YAML"

    Real credentials live in a gitignored `.env`, a Docker secret file,
    or an orchestrator secret store — **never** inline in this file.

## Reference stack

```yaml
# docker-compose.yml — reference stack with all options; trim to taste.
# Required at runtime at minimum: RESTIC_REPOSITORY, a password, RESTIC_TAG, BACKUP_CRON.

services:
  restic-backup:
    image: marc0janssen/restic-backup-helper:latest
    container_name: restic-backup-helper
    hostname: backup-node            # appears in mail subjects, JSON summaries, webhook payloads
    restart: unless-stopped

    # Needed for `restic mount` (FUSE) and reading source paths under tight ACLs.
    cap_add:
      - DAC_READ_SEARCH
      - SYS_ADMIN
    devices:
      - /dev/fuse

    env_file:
      - restic.env                   # non-secret defaults; gitignored

    environment:
      # ─── Restic core ───────────────────────────────────────────────────────────
      RESTIC_REPOSITORY: ${RESTIC_REPOSITORY:?set in restic.env or shell}
      RESTIC_PASSWORD_FILE: /run/secrets/restic_password
      RESTIC_TAG: ${RESTIC_TAG:-daily}
      RESTIC_CACHE_DIR: /.cache/restic
      # RESTIC_CACERT: /config/ca-bundle.pem        # private CA / corp proxy
      RESTIC_CHECK_REPOSITORY_STATUS: "ON"
      # RESTIC_AUTO_UNLOCK: "ON"                    # opt-in; one writer only

      # ─── Backup job ────────────────────────────────────────────────────────────
      BACKUP_CRON: "0 2 * * *"
      BACKUP_ROOT_DIR: /data
      RESTIC_JOB_ARGS: "--exclude-file /config/exclude_files.txt --one-file-system"
      RESTIC_FORGET_ARGS: "--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --keep-yearly 10"

      # ─── Optional: scheduled integrity check ───────────────────────────────────
      CHECK_CRON: "37 3 * * 0"
      # RESTIC_CHECK_ARGS: "--read-data-subset 5%"

      # ─── Optional: standalone prune ────────────────────────────────────────────
      PRUNE_CRON: "0 4 * * 0"
      RESTIC_PRUNE_ARGS: "--max-unused 10%"

      # ─── Optional: Rclone replicate ────────────────────────────────────────────
      RCLONE_CONFIG: /config/rclone.conf
      REPLICATE_JOB_FILE: /config/replicate_jobs.txt
      REPLICATE_JOB_ARGS: "--exclude-from /config/exclude_sync.txt"
      REPLICATE_CRON: "*/30 * * * *"
      REPLICATE_VERBOSE: "ON"

      # ─── Mail (msmtp) ──────────────────────────────────────────────────────────
      MAILX_RCPT: ops@example.com
      MAILX_ON_ERROR: "ON"

      # ─── Webhook ───────────────────────────────────────────────────────────────
      WEBHOOK_URL: https://hc-ping.com/00000000-0000-0000-0000-000000000000
      WEBHOOK_TIMEOUT: "15"
      WEBHOOK_ON_ERROR: "OFF"

      # ─── Hooks ─────────────────────────────────────────────────────────────────
      HOOK_TIMEOUT: "300"

      # ─── Log rotation ──────────────────────────────────────────────────────────
      ROTATE_LOG_CRON: "0 0 * * 6"
      CRON_LOG_MAX_SIZE: "1048576"
      MAX_CRON_LOG_ARCHIVES: "5"

      # ─── Locale ────────────────────────────────────────────────────────────────
      TZ: Europe/Amsterdam

    secrets:
      - restic_password

    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config:ro
      - ./config/msmtprc:/etc/msmtprc:ro
      - ./hooks:/hooks:ro
      - backup-logs:/var/log
      - restic-cache:/.cache/restic
      - /srv/documents:/data:ro
      # - /mnt/restic:/mnt/restic            # uncomment for local/NFS repo
      # - ./restore:/restore                  # restic restore --target /restore
      # - ~/.ssh:/root/.ssh:ro                # sftp: backends only

    healthcheck:
      test: ["CMD-SHELL", "restic cat config >/dev/null 2>&1 || exit 1"]
      interval: 15m
      timeout: 30s
      start_period: 1m
      start_interval: 10s

    command: ["tail", "-fn0", "/var/log/cron.log"]

secrets:
  restic_password:
    file: ./restic.password                  # gitignored; chmod 600

volumes:
  backup-logs:
  restic-cache:
```

## Compose profiles

The reference [`scripts/docker-compose.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/scripts/docker-compose.yml)
ships two opt-in [Compose profiles](https://docs.docker.com/compose/profiles/):

| Profile | Adds | Why |
| --- | --- | --- |
| `metrics` | `node-exporter` sidecar bound to `127.0.0.1:9100`, scraping the `backup-logs` volume's `textfile_collector/` subdirectory. | Expose `restic_<job>_last_*` gauges over HTTP without a host-level node-exporter. |
| `dev` | `mailhog` SMTP catcher (port 1025 SMTP, 8025 web UI; both bound to `127.0.0.1`). | Local end-to-end test of `MAILX_RCPT` subjects/bodies without a real relay. |

```shell
docker compose up                              # only the restic-backup service
docker compose --profile metrics up            # + node-exporter sidecar
docker compose --profile dev up                # + mailhog SMTP catcher
docker compose --profile metrics --profile dev up  # both
```

The main `restic-backup` service has no `profiles:` key, so it is
always brought up regardless of which profile (if any) you pick.

## Healthchecks

=== "Weak (binary only)"

    ```yaml
    healthcheck:
      test: ["CMD", "restic", "version"]
      interval: 5m
      timeout: 10s
      retries: 3
    ```

    Confirms restic is callable. Does not verify repository
    reachability.

=== "Strong (repo reachability)"

    ```yaml
    healthcheck:
      test: ["CMD-SHELL", "restic cat config >/dev/null 2>&1 || exit 1"]
      interval: 15m
      timeout: 30s
      start_period: 1m
    ```

    Same probe the entrypoint uses on boot. Fails when credentials or
    repository reachability break.

=== "End-to-end read"

    ```yaml
    healthcheck:
      test: ["CMD-SHELL", "restic snapshots --json | head -c1 >/dev/null"]
      interval: 30m
      timeout: 1m
    ```

    `restic snapshots` is the heaviest probe; it forces an actual list
    of snapshots over the network. Use sparingly on metered links.

## Example anonymized stacks

The repo ships two reference stacks under
[`examples/compose/`](https://github.com/marc0janssen/restic-backup-helper/tree/develop/examples/compose):

| File | Purpose |
| --- | --- |
| [`examples/compose/cloud-reference.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/compose/cloud-reference.yml) | Heavily commented cloud-remote reference; every option documented inline. Strip what you don't need. |
| [`examples/compose/multi-job.yml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/compose/multi-job.yml) | Multiple-jobs pattern using YAML anchors for shared config. |

See [Multiple backup jobs](multiple-jobs.md) for the multi-job pattern
in detail.

## Pulling and updating

```shell
docker compose pull          # fetch the latest tag
docker compose up -d         # recreate the container
docker compose logs -f       # tail the cron log
```

`latest` and `develop` are moving targets. **Pin both helper and
Restic versions** in production by setting the image tag to the full
`<helper>-<restic>` form:

```yaml
services:
  restic-backup:
    image: marc0janssen/restic-backup-helper:2.3.0-0.18.1
```

See [Image tags](../reference/image-tags.md).
