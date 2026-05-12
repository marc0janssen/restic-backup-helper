# Backup backends

Restic supports a wide range of repository backends. This page summarises
the most common ones in the context of the helper image — what to set,
what to mount and what to watch out for. For the full Restic backend
matrix see the [Restic preparing-a-new-repository guide](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html).

## Local repository

The simplest possible setup: a local disk (likely a mounted host directory)
under `/mnt/restic`:

```yaml
environment:
  RESTIC_REPOSITORY: /mnt/restic
volumes:
  - /srv/restic:/mnt/restic     # host directory holding the repo
```

You can also use a named Docker volume:

```yaml
volumes:
  - restic-repo:/mnt/restic
```

!!! warning "Don't back up the repo to itself"

    Set `BACKUP_ROOT_DIR` to a path that does **not** include the
    repository's mount point, or pass `--exclude /mnt/restic` via
    `RESTIC_JOB_ARGS`. Otherwise each backup will try to back up the
    repository, which is both pointless and a great way to fill your
    disk.

## NFS

When you want the repo to live on an NFS export, let the entrypoint mount
it for you so the container's `RESTIC_REPOSITORY=/mnt/restic` stays
unchanged and the mount is verified at startup:

```yaml
cap_add:
  - SYS_ADMIN
environment:
  NFS_TARGET: "nfs-server.lan:/export/restic"
  RESTIC_REPOSITORY: /mnt/restic
```

If the mount fails the container aborts with exit `1` — jobs never run
against an empty `/mnt/restic`.

## SFTP

Restic needs **non-interactive** SSH authentication. Mount your private
key read-only:

```yaml
environment:
  RESTIC_REPOSITORY: "sftp:user@host:/path/to/repo"
volumes:
  - ~/.ssh:/root/.ssh:ro
```

Tips:

- Ensure `~/.ssh/known_hosts` contains the server's host key fingerprint
  to avoid an interactive prompt on first connect.
- Use a per-deployment SSH key (`ssh-keygen -f restic-key -N ""`) so a
  compromised container does not expose your operator key.

## S3 and S3-compatible

Standard Restic syntax; the helper does not interpose:

```yaml
environment:
  RESTIC_REPOSITORY: "s3:https://s3.amazonaws.com/my-bucket/restic"
  AWS_ACCESS_KEY_ID: AKIA...
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:?}
  AWS_DEFAULT_REGION: eu-central-1
```

For S3-compatible providers (MinIO, Backblaze B2 via S3, Wasabi, Cloudflare
R2, …) point the URL at the custom endpoint. Many providers want
`AWS_DEFAULT_REGION=auto` or a provider-specific region.

!!! tip "Object-lock buckets"

    Object-locked buckets work but make repository init and `restic
    forget --prune` more involved. Test your retention policy against
    an object-locked test bucket before pointing production at one.

## Backblaze B2 (native)

```yaml
environment:
  RESTIC_REPOSITORY: "b2:my-bucket:/restic"
  B2_ACCOUNT_ID: ${B2_ACCOUNT_ID:?}
  B2_ACCOUNT_KEY: ${B2_ACCOUNT_KEY:?}
```

## Rclone remote

Use `rclone:<remote>:<path>` style URLs and supply `RCLONE_CONFIG`. Some
providers refresh tokens inside `rclone.conf`; keep that file on a
**writable** mount or rclone cannot persist the refreshed token:

```yaml
environment:
  RESTIC_REPOSITORY: "rclone:jottacloud:backups"
  RCLONE_CONFIG: /config/rclone.conf
volumes:
  - ./config:/config       # writable: rclone may refresh tokens
```

The walkthrough for Jottacloud lives at
[micro.mjanssen.nl/2025/03/25/escaping-usa-tech-bye-bye](https://micro.mjanssen.nl/2025/03/25/escaping-usa-tech-bye-bye.html).

## OpenStack Swift

Use `swift:container:/path` style URLs and populate the standard `OS_*`
variables (`OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, etc.). See the
[full list](environment-variables.md#openstack-swift-swift-repository).

```yaml
environment:
  RESTIC_REPOSITORY: "swift:restic:/backups"
  OS_AUTH_URL: https://auth.example.com/v3
  OS_PROJECT_NAME: backups
  OS_USERNAME: backup-bot
  OS_PASSWORD_FILE: /run/secrets/swift_password   # if your IAM supports it
  OS_REGION_NAME: NL-AMS
```

## Choosing a backend

| Concern | Local / NFS | SFTP | S3 / B2 / Swift | Rclone-wrapped |
| --- | --- | --- | --- | --- |
| Latency | Lowest | Moderate | High | Highest |
| Cost | Disk only | Server | Per-GB + egress | Provider-specific |
| Append-only / immutability | Filesystem ACLs | Filesystem ACLs | Object lock | Provider feature |
| Multi-host writers | Lock contention; manage carefully | Same | Designed for it | Same |
| Restore performance | Excellent | Good | Good with cache | Good with cache |
| First-time setup | `chmod 755`, mount | Provision SSH key | Provision IAM keys | Configure rclone remote |

!!! info "Multi-host repositories"

    When more than one host writes to the same Restic repository, **keep
    `RESTIC_AUTO_UNLOCK=OFF`** (the default since 1.12.0). Otherwise a
    failed run on host A can auto-unlock the repo while host B is in the
    middle of a snapshot, corrupting host B's backup.

## Verifying the choice

After deploying, run the doctor and the repository probe:

```shell
docker exec -ti restic-backup-helper /bin/doctor
docker exec -ti restic-backup-helper restic cat config
docker exec -ti restic-backup-helper restic snapshots --json | jq '.[].time' | tail -5
```

`/bin/doctor` masks the userinfo segment of the repository URL when it
prints it, so it is safe to paste the diagnostic output into an issue or
support chat. See [Diagnostics](../operations/diagnostics.md).
