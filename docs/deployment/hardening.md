# Hardening

The image **runs as root** and uses a writable root filesystem by
default. That is a deliberate trade-off; this page explains why and
what you can still tighten at the orchestration layer.

## Why root, FUSE, NFS

- **Cron-as-root**: busybox `crond` writes to
  `/var/spool/cron/crontabs/root` and reads `/etc/crontabs/root`;
  restoring snapshots commonly needs root to recreate UIDs/GIDs and
  ACLs faithfully.
- **FUSE (`restic mount`)**: requires `CAP_SYS_ADMIN` and access to
  `/dev/fuse`; that capability is meaningless without an effective UID
  0 inside the container.
- **NFS** (`NFS_TARGET`): the `mount` syscall in busybox needs
  `CAP_SYS_ADMIN`; the same constraint as FUSE.
- **Hooks**: user-supplied `/hooks/*.sh` scripts may need to read
  source files under tight ACLs; running as a non-root UID would break
  some perfectly reasonable backup setups.
- **Restic backends**: most cloud backends (`s3:`, `swift:`, `rclone:`)
  work fine as non-root, but `sftp:` plus `~/.ssh` mounts and local
  repository mounts under `/mnt/restic` typically end up needing root.

A separate "slim" image (no FUSE, no NFS, no cron, runs as UID 1000) is
on the backlog for users who can accept those trade-offs. The default
image keeps the boring, batteries-included behaviour.

## What you can tighten outside the image

Cap the blast radius **outside** the image — Docker / Compose /
Kubernetes are the right place for these knobs.

### Drop most kernel capabilities

```yaml
cap_drop:
  - ALL
cap_add:
  - DAC_READ_SEARCH   # source paths under tight ACLs
  - SYS_ADMIN         # FUSE / NFS mount / restic mount
```

The default Docker capability set is broader than the image needs.
Drop everything and re-add only what FUSE/NFS / strict ACL reads
actually require.

### Read-only root filesystem

```yaml
read_only: true
tmpfs:
  - /tmp
  - /run
  - /var/run
  - /var/spool/cron        # crond writes the rendered crontab here
  - /var/log               # last-*.json + cron.log; switch to a named volume to persist
  - /.cache/restic         # restic cache; mount a volume to keep it across restarts
```

Trade-offs to know:

- `/var/log` as tmpfs means `last-*.json`, `cron.log` archives and
  `*.prom` files are lost on container restart. Switch that one to a
  named volume if you scrape it externally (Prometheus textfile
  collector, log forwarder).
- `/.cache/restic` as tmpfs means every restart re-warms the restic
  cache (slower first backup after restart). A named volume is
  recommended for any non-trivial repository.

### No new privileges

```yaml
security_opt:
  - no-new-privileges:true
```

### Read-only source mounts

```yaml
volumes:
  - /srv/documents:/data:ro
  - ~/.ssh:/root/.ssh:ro     # only when using sftp:
```

`:ro` ensures a hostile hook script cannot mutate the backup source.

### Seccomp / AppArmor

The upstream Docker default profiles already block the riskiest
syscalls; an explicit profile path can tighten further but is
environment-specific. Start with the default and only add a custom
profile when you have evidence you need to.

## Kubernetes `securityContext`

```yaml
securityContext:
  runAsUser: 0
  runAsGroup: 0
  capabilities:
    drop: [ALL]
    add: [DAC_READ_SEARCH, SYS_ADMIN]
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
```

Combine with `emptyDir` mounts for `/tmp`, `/var/spool/cron`,
`/var/log` (or PVC for persistence) and `/.cache/restic`.

The included [Kubernetes manifest](kubernetes.md) already drops all
capabilities and re-adds only `DAC_READ_SEARCH` + `SYS_ADMIN`.

## What you should **not** tighten

- **Don't try to run as a non-root UID** inside the image. The cron
  daemon writes to `/var/spool/cron/crontabs/root`; restoring `chown
  -R` ownership commonly needs UID 0. Use the orchestration-layer
  knobs above instead.
- **Don't strip `SYS_ADMIN`** if you use FUSE (`restic mount`) or NFS
  (`NFS_TARGET`). The image will fall over in confusing ways.
- **Don't drop `DAC_READ_SEARCH`** if your backup source has tight
  ACLs that prevent root from reading without it.

## TL;DR

Don't try to make the image non-root or read-only **inside** the
container — tighten it at the orchestration layer with `cap_drop`,
`read_only` + tmpfs, `:ro` source mounts and `no-new-privileges`. You
keep the well-tested cron / FUSE / NFS behaviour and still meet most
CIS-style benchmarks.

## See also

- [Docker Compose](docker-compose.md) — reference Compose stack.
- [Kubernetes](kubernetes.md) — reference manifest.
- [Security](../security.md) — secret handling and credential masking.
