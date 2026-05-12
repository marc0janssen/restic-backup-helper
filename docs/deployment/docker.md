# Docker run

A single `docker run` is enough to get a working scheduled backup. This
page is for operators who want one-liner deployments without Compose or
Kubernetes.

## Minimal

```shell
docker run -d \
  --name restic-backup-helper \
  --restart unless-stopped \
  --hostname backup-node \
  -e RESTIC_REPOSITORY='s3:https://s3.amazonaws.com/my-bucket/restic' \
  -e RESTIC_PASSWORD='use-a-strong-secret' \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /srv/backup-src:/data:ro \
  -v restic-config:/config \
  marc0janssen/restic-backup-helper:latest
```

## With Docker secrets-style file

```shell
echo 'use-a-strong-secret' > /etc/restic/restic.password
chmod 600 /etc/restic/restic.password

docker run -d \
  --name restic-backup-helper \
  --restart unless-stopped \
  --hostname backup-node \
  -e RESTIC_REPOSITORY='s3:https://s3.amazonaws.com/my-bucket/restic' \
  -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /etc/restic/restic.password:/run/secrets/restic_password:ro \
  -v /srv/backup-src:/data:ro \
  -v /var/lib/restic-config:/config \
  -v /var/lib/restic-cache:/.cache/restic \
  -v /var/log/restic:/var/log \
  marc0janssen/restic-backup-helper:latest
```

Persisting `/.cache/restic` and `/var/log` speeds up subsequent runs
and keeps `last-*.json` summaries across container recreations.

## With FUSE (`restic mount`)

```shell
docker run -d \
  --name restic-backup-helper \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  -e RESTIC_REPOSITORY='s3:…' \
  -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /etc/restic/restic.password:/run/secrets/restic_password:ro \
  -v /srv/backup-src:/data:ro \
  marc0janssen/restic-backup-helper:latest
```

`SYS_ADMIN` + `/dev/fuse` are required for `restic mount` and for
mounting NFS via `NFS_TARGET`. They are *not* required for plain
`restic backup`.

## With NFS-mounted repository

```shell
docker run -d \
  --name restic-backup-helper \
  --cap-add SYS_ADMIN \
  -e NFS_TARGET='nfs-server.lan:/export/restic' \
  -e RESTIC_REPOSITORY='/mnt/restic' \
  -e RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
  -e RESTIC_TAG='daily' \
  -e BACKUP_CRON='0 2 * * *' \
  -e BACKUP_ROOT_DIR='/data' \
  -v /etc/restic/restic.password:/run/secrets/restic_password:ro \
  -v /srv/backup-src:/data:ro \
  marc0janssen/restic-backup-helper:latest
```

The entrypoint runs `mount -o nolock -v "$NFS_TARGET" /mnt/restic` on
boot. The container aborts with exit `1` if the mount fails so jobs
never run against an empty `/mnt/restic`.

## Healthchecks

Pick how hard you want Docker to probe the repository:

=== "Weak (verifies binary only)"

    ```shell
    docker run -d \
      --health-cmd 'restic version' \
      --health-interval 5m \
      --health-timeout 10s \
      --health-retries 3 \
      … marc0janssen/restic-backup-helper:latest
    ```

=== "Strong (verifies repo reachability)"

    ```shell
    docker run -d \
      --health-cmd 'restic cat config >/dev/null 2>&1 || exit 1' \
      --health-interval 15m \
      --health-timeout 30s \
      --health-start-period 1m \
      … marc0janssen/restic-backup-helper:latest
    ```

The strong probe fails when credentials or repository reachability
break — same probe the entrypoint uses on boot.

## What to read next

- [Docker Compose](docker-compose.md) — the same setup as a Compose
  file with profiles and secrets.
- [Multiple backup jobs](multiple-jobs.md) — one host, many backup
  trees on different schedules.
- [Hardening](hardening.md) — `cap_drop`, `read_only: true` + tmpfs,
  `no-new-privileges`.
