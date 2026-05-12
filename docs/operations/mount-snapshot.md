# Mount snapshot

`/bin/mount-snapshot` is an operator-friendly wrapper around
`restic mount`. It exposes every matching snapshot as a read-only FUSE
filesystem under `<target>/snapshots/<id>/...` plus a
`<target>/snapshots/latest` symlink to the newest matching snapshot, so
you can `cd`, `ls`, `cat`, `tar`, `rsync` your way to any file from any
backup without doing a full restore.

It is **operator-initiated** and never cron-driven by itself.

## Why it exists

Plain `restic mount` works, but it is easy to:

- mount on top of `/data` (your backup source) and watch the next
  scheduled backup archive zero bytes,
- accidentally show every snapshot from every host because you forgot to
  pass `--host` / `--tag` on a shared repository,
- leave a stale FUSE mount behind when restic crashes or the operator
  forgets to Ctrl+C cleanly.

`/bin/mount-snapshot` makes the safe behaviour the default:

- mounts on `/fusemount` by default — a container-internal path that
  never collides with `/bin/restore` output (which writes to
  `/restore`) or with a host bind-mount on `/restore`,
- refuses to mount on `/data` / `BACKUP_ROOT_DIR` / system dirs
  unless `--force` is given,
- scopes the visible tree to `--host "$HOSTNAME"` and
  `--tag "$RESTIC_TAG"` so a multi-host repository only shows this
  container's snapshots,
- traps `EXIT` and calls `fusermount -u` (with `umount` fallback) so
  SIGINT, SIGTERM or a restic crash always unmounts cleanly,
- requires explicit `--repo-wide` before exposing every host's
  snapshots.

## Quick start

```shell
# Mount this host's snapshots read-only under /fusemount.
# Open another shell to browse; Ctrl+C in the original shell unmounts.
docker exec -ti restic-backup-helper /bin/mount-snapshot

# Use a different mountpoint (must be empty or pass --force).
docker exec -ti restic-backup-helper /bin/mount-snapshot --target /tmp/browse

# Explicit repository-wide view (every host, every tag).
docker exec -ti restic-backup-helper /bin/mount-snapshot --repo-wide

# Limit to snapshots that include a specific path (repeatable).
docker exec -ti restic-backup-helper /bin/mount-snapshot \
  --path /data/documents --path /data/photos

# One-shot via docker run (FUSE needs the cap, the device and AppArmor=unconfined).
docker run --rm -it \
  --cap-add SYS_ADMIN --device /dev/fuse \
  --security-opt apparmor=unconfined \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  mount-snapshot
```

Once the mount is up, in another shell, browse via `docker exec` and
stream content out via `docker exec ... cat > host_file` or
`docker exec ... tar -cf - | tar -xf -`. See [Common
recipes](#common-recipes) below for a comprehensive set of patterns.

!!! danger "`docker cp` does not see FUSE mounts inside the container"

    `docker cp restic-backup-helper:/fusemount/...` will fail with
    `Could not find the file ... in container` — even when
    `docker exec restic-backup-helper ls /fusemount/...` works fine.
    Reason: `docker cp` reads the container's filesystem **via the
    Docker daemon**, which does not traverse mount-namespace changes
    made by processes inside the container. A FUSE mount established
    by `restic mount` lives in the container's own mount namespace, so
    only `docker exec`-spawned processes can see it. All recipes below
    therefore use `docker exec` with stdout / pipes, or copy through a
    non-FUSE staging path before `docker cp`.

## Common recipes

All recipes assume `/bin/mount-snapshot` is running in another
terminal (terminal 1):

```shell
docker exec -ti restic-backup-helper mount-snapshot
# blocks on: "📂 Mounting at '/fusemount'. ..."
```

Run the following from a separate host shell (terminal 2) while
terminal 1 is alive.

### Browse the latest snapshot

```shell
# Top-level tree of the newest matching snapshot (host + tag scoped).
docker exec restic-backup-helper ls /fusemount/snapshots/latest

# Inspect inside a specific subtree.
docker exec restic-backup-helper ls -la /fusemount/snapshots/latest/data/etc
docker exec restic-backup-helper find /fusemount/snapshots/latest/data/documents -name '*.pdf'

# Read a single file inline (no copy).
docker exec restic-backup-helper cat /fusemount/snapshots/latest/data/etc/hostname
docker exec restic-backup-helper less /fusemount/snapshots/latest/var/log/auth.log
```

### Pick a specific snapshot ID

`/fusemount/snapshots/` exposes one subdirectory per matching snapshot,
named after the short ID. Useful when "latest" is not what you want:

```shell
# List every snapshot id visible under the current filter.
docker exec restic-backup-helper ls /fusemount/snapshots/

# Browse a specific one.
docker exec restic-backup-helper ls /fusemount/snapshots/5a3f2c8b/data
```

`/fusemount/hosts/<hostname>/...` and `/fusemount/tags/<tag>/...` give
the same data sliced by host and tag — handy with `--repo-wide` mounts.

### Copy a single file out to the host

`docker cp` does **not** work on `/fusemount/...` paths (see the
warning above). Use `docker exec ... cat > host_file` instead — it
runs in the container's mount namespace so it sees the FUSE tree, and
the bytes are streamed over stdout to the host shell:

```shell
docker exec restic-backup-helper cat \
  /fusemount/snapshots/latest/data/etc/hostname \
  > ./hostname

docker exec restic-backup-helper cat \
  /fusemount/snapshots/5a3f2c8b/data/documents/report.pdf \
  > ./report.pdf
```

If you prefer `docker cp` semantics (preserves the source filename and
metadata), copy through a non-FUSE staging path first:

```shell
docker exec restic-backup-helper cp \
  /fusemount/snapshots/latest/data/etc/hostname /tmp/hostname
docker cp restic-backup-helper:/tmp/hostname ./hostname
docker exec restic-backup-helper rm /tmp/hostname
```

### Copy a whole directory tree to the host

`tar` over `docker exec` is the canonical pattern — it works through
FUSE, preserves modes/owners, and never lands a scratch copy on the
container filesystem:

```shell
# In-place tar over a pipe; result on host is ./documents/...
docker exec restic-backup-helper tar \
  -C /fusemount/snapshots/latest/data -cf - documents \
  | tar -C ./ -xf -
```

### Stream a tar.gz archive straight to the host

```shell
docker exec restic-backup-helper tar \
  -C /fusemount/snapshots/latest/data -czf - documents \
  > ./documents.tar.gz
```

Compare with `/bin/snapshot-export`: the helper is the right choice
when you want the full job plumbing (`last-snapshot-export.json`,
hooks, mail/webhook/metrics). The tar-stream above is the right choice
when you just want a quick archive of an arbitrary subtree from an
already-mounted snapshot.

### Diff a file between two snapshots

```shell
docker exec restic-backup-helper diff -u \
  /fusemount/snapshots/5a3f2c8b/data/etc/nginx/nginx.conf \
  /fusemount/snapshots/latest/data/etc/nginx/nginx.conf
```

### Diff two directory trees between snapshots

```shell
docker exec restic-backup-helper diff -qr \
  /fusemount/snapshots/5a3f2c8b/data/etc \
  /fusemount/snapshots/latest/data/etc
```

### Search for a file across snapshots

```shell
# Find every snapshot that has '/data/important.conf'.
docker exec restic-backup-helper sh -c \
  'for s in /fusemount/snapshots/*/; do
     [ -f "$s/data/important.conf" ] && echo "${s}"
   done'

# grep across the latest snapshot, host-side terminal.
docker exec restic-backup-helper grep -RIn 'TODO' /fusemount/snapshots/latest/data/etc 2>/dev/null
```

### Recover a single file without running `/bin/restore`

If you only need one or two files back and do not want the full job
plumbing of the restore worker:

```shell
# In-container: stage from FUSE to /restore (often a host bind-mount).
docker exec restic-backup-helper cp \
  /fusemount/snapshots/latest/data/etc/nginx/nginx.conf \
  /restore/nginx.conf

# Or stream the file directly to the host shell (no /restore needed).
docker exec restic-backup-helper cat \
  /fusemount/snapshots/latest/data/etc/nginx/nginx.conf \
  > ./nginx.conf
```

For full-snapshot restores the dedicated [`/bin/restore`](restore.md)
worker remains the right tool — it manages target validation,
metrics, hooks and post-restore notifications. The recipes above are
for the cherry-pick-a-file case.

### Repository-wide mount (cross-host inspection)

```shell
# Terminal 1
docker exec -ti restic-backup-helper mount-snapshot --repo-wide

# Terminal 2
docker exec restic-backup-helper ls /fusemount/hosts            # every host with snapshots
docker exec restic-backup-helper ls /fusemount/tags             # every tag
docker exec restic-backup-helper ls /fusemount/snapshots        # every snapshot id
```

### Path-filtered mount (only snapshots covering a directory)

```shell
docker exec -ti restic-backup-helper mount-snapshot \
  --path /data/documents --path /data/photos
# Only snapshots that include BOTH paths show up under /fusemount/snapshots/.
```

!!! warning "FUSE needs four things in place"

    `restic mount` will fail with `fusermount: mount failed: Permission
    denied` (or `fusermount: exit status 1`) unless **all** of the
    following are true:

    1. `--cap-add SYS_ADMIN` is set (compose: `cap_add: [SYS_ADMIN]`).
    2. `--device /dev/fuse` is set (compose:
       `devices: [/dev/fuse:/dev/fuse]`).
    3. `security_opt: [no-new-privileges:true]` is **not** set — that
       flag strips the setuid bit on `/usr/bin/fusermount`.
    4. The active AppArmor profile is `unconfined`, **not**
       `docker-default (enforce)`. On Ubuntu/Debian hosts (Docker's
       default AppArmor template) you must add
       `security_opt: [apparmor:unconfined]`.

    `/bin/mount-snapshot` pre-flights all four of these and refuses
    early with a targeted error message naming the exact knob, so you
    do not have to interpret restic's generic `Permission denied`.
    See [Troubleshooting](#troubleshooting) below for the diagnostic
    commands and per-orchestrator fixes.

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--target PATH` | `/fusemount` | Mountpoint; created if missing, must be writable and empty (or pass `--force`). The default is container-internal so it never collides with `/bin/restore` output or a host bind-mount on `/restore`. |
| `--tag TAG` | `$RESTIC_TAG` | Filter the visible snapshots by tag. Ignored with `--repo-wide`. |
| `--host HOST` | container `$HOSTNAME` | Filter the visible snapshots by host. Ignored with `--repo-wide`. |
| `--path PATH` | – | Only expose snapshots that include this path (repeatable). |
| `--repo-wide` | off | Do not add host/tag filters; expose every snapshot in the repository. |
| `--allow-other` | off | Pass restic's `--allow-other` so other UIDs (e.g. host bind-mount consumers) can read the tree. Requires `user_allow_other` in `/etc/fuse.conf`. |
| `--force` | off | Allow mounting on a non-empty target or a refused path (`/data`, `BACKUP_ROOT_DIR`, …). |
| `--help` | – | Print usage and exit. |

## What it does

```mermaid
flowchart TD
    A[mount-snapshot] --> B[pre-mount-snapshot hook]
    B --> C{Validate repo auth +<br/>target safety}
    C --> D[Build restic mount cmd]
    D --> E{--repo-wide?}
    E -- no --> F[Append --host HOSTNAME<br/>and --tag RESTIC_TAG]
    E -- yes --> G[No host/tag filters]
    F --> H[restic mount &lt;target&gt;]
    G --> H
    H -. blocks until SIGINT/SIGTERM .-> I[EXIT trap:<br/>fusermount -u || umount]
    I --> J[Write last-mount-snapshot.json]
    J --> K[Optional restic_mount_snapshot.prom]
    K --> L{MAILX_RCPT? WEBHOOK_URL?}
    L --> M[mail + webhook]
    M --> N[post-mount-snapshot hook with "$rc"]
```

## Scope defaults

Default command shape:

```shell
restic mount --host "$HOSTNAME" --tag "$RESTIC_TAG" /fusemount
```

This mirrors what `/bin/backup` writes (`--tag "$RESTIC_TAG"`), and
protects shared repositories: one host's mount session does not
accidentally expose another host's snapshots unless you deliberately
opt in with `--repo-wide`.

`<target>/snapshots/latest` always points at the newest snapshot
matching the active filters, so scripts can hard-code the path without
discovering snapshot IDs first.

## Why `/fusemount` instead of `/restore`?

`/restore` is owned by `/bin/restore`: the restore worker writes real
files there, and operators commonly bind-mount the host path
`/srv/<stack>/restore` onto `/restore` so restored files appear on the
host filesystem. Using `/restore` as a FUSE mountpoint at the same
time causes two distinct problems:

- the FUSE mount **hides** any existing `/bin/restore` output while
  active, and any in-flight write from `/bin/restore` would silently
  go into the FUSE layer instead of the host bind-mount;
- on a host bind-mount, the FUSE mount is **not visible** from the
  host filesystem by default (mount-namespace propagation is
  `rprivate`), so the bind-mount path on the host stays empty and
  operators wonder where their snapshots went.

`/fusemount` sidesteps both: it is a plain container-internal
directory, never bind-mounted, exclusively used by
`/bin/mount-snapshot`. Browse it with `docker exec` / `docker cp` (see
[Quick start](#quick-start)). If you do need the FUSE tree visible on
the host filesystem path, see [Browsing the mount from the
host](#browsing-the-mount-from-the-host) below.

## Browsing the mount from the host

The simplest and most portable approach is to **never expose the FUSE
tree on the host filesystem**: while `mount-snapshot` is running, do
all browsing/extraction via `docker exec` with stdout streams (`cat`
or `tar -cf -`) piped into a host shell. No host-side configuration
required.

```shell
# Terminal 1 - keep this running
docker exec -ti restic-backup-helper mount-snapshot

# Terminal 2 - browse + extract while terminal 1 is alive
docker exec restic-backup-helper ls /fusemount/snapshots/latest
docker exec restic-backup-helper cat /fusemount/snapshots/latest/data/file.txt > ./file.txt
docker exec restic-backup-helper tar -C /fusemount/snapshots/latest/data -cf - documents | tar -C ./ -xf -
```

!!! danger "`docker cp` does not work on FUSE paths"

    `docker cp` reads the container filesystem via the Docker daemon
    and bypasses mount-namespace changes made inside the container, so
    `docker cp restic-backup-helper:/fusemount/...` fails with `Could
    not find the file` even when the same path is listable via
    `docker exec ls`. Use `docker exec ... cat > host_file` or
    `docker exec ... tar -cf - | tar -xf -` instead. See [Common
    recipes → Copy a single file out to the host](#copy-a-single-file-out-to-the-host)
    for the full pattern.

If you do need the FUSE tree to appear on the host filesystem (e.g. so
a third application can read it directly), you need three things
together — none of them on its own is enough:

1. **`user_allow_other`** in `/etc/fuse.conf` inside the container,
   plus `--allow-other` on the mount-snapshot command.
2. **Bind-mount propagation `rshared`** on the volume (compose
   long-form `bind: propagation: rshared`).
3. **Host-side shared mount peer group**: the volume's source path on
   the host must itself be on a shared mount subtree. Verify with
   `findmnt -no PROPAGATION /srv/<path>` (must be `shared`, not
   `private`), and make it persistent with a small `systemd` unit
   running `mount --make-rshared` before `docker.service`.

Mount the volume on `/fusemount` (not `/restore`) when you go this
route, so the FUSE-mount lives on a dedicated path:

```yaml
volumes:
  - type: bind
    source: /srv/example/restic-cloud/fusemount
    target: /fusemount
    bind:
      propagation: rshared
```

## Refused targets

Without `--force`, the helper refuses to mount on:

- `/`, `/bin`, `/sbin`, `/usr`, `/etc`, `/lib`, `/lib64`
- `/var`, `/var/log`, `/var/run`, `/var/spool`, `/var/spool/cron`
- `/run`, `/proc`, `/sys`, `/dev`, `/tmp`
- `/data`, `/host`, `/config`, `/hooks`, `/mnt`, `/mnt/restic`
- the configured `BACKUP_ROOT_DIR`
- any non-empty directory (FUSE would hide existing contents).

The mountpoint always becomes inaccessible to other processes for the
duration of the mount, so refusing the backup source loudly is friendlier
than silently letting the next scheduled backup archive 0 bytes.

## Clean unmount

`restic mount` itself unmounts on a clean Ctrl+C / SIGTERM. As a
belt-and-braces guarantee, `/bin/mount-snapshot` registers an `EXIT`
trap that tries `fusermount -u "$target"` and falls back to
`umount "$target"`. This covers the rare case where restic crashes hard
and leaves a stale FUSE mount that future `docker exec` sessions would
otherwise see.

If you ever need to unmount from outside the container:

```shell
docker exec restic-backup-helper fusermount -u /fusemount
# or, as a last resort
docker exec restic-backup-helper umount /fusemount
```

## Audit trail

The helper writes:

- `/var/log/mount-snapshot-last.log`
- `/var/log/mount-snapshot-error-last.log` on failure
- `/var/log/last-mount-snapshot.json`
- `restic_mount_snapshot.prom` when `METRICS_DIR` is configured

Hooks:

```text
/hooks/pre-mount-snapshot.sh                # informational; failure does not abort the mount
/hooks/post-mount-snapshot.sh "$exit_code"  # always called after unmount with the restic exit code as $1
```

Mail and webhook notifications use the same `MAILX_*` and `WEBHOOK_*`
settings as the cron-driven workers.

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Mount session ended cleanly (operator pressed Ctrl+C / sent SIGTERM, restic unmounted). |
| `2` | Configuration error: missing repository credentials, empty host/tag filter without `--repo-wide`, refused target, missing `/dev/fuse` or `fusermount`, or invalid CLI argument. |
| `1` | Target validation failed (not writable, not empty without `--force`, …). |
| other | Restic returned a failure (e.g. repository unreachable). Inspect `/var/log/mount-snapshot-error-last.log`. |

## Troubleshooting

### `fusermount: mount failed: Permission denied` / `fusermount: exit status 1`

The container is missing one or more pieces of the FUSE plumbing.
`/bin/mount-snapshot` pre-flights all of them by reading
`/proc/self/status` and the device node directly, so the *abort
message* tells you exactly which knob is wrong before `restic mount`
is ever called:

- `❌ /dev/fuse is missing…` → add `--device /dev/fuse` (compose:
  `devices: [/dev/fuse:/dev/fuse]`; Kubernetes: a `hostPath` `/dev/fuse`
  volume plus `volumeDevices`).
- `❌ CAP_SYS_ADMIN is not in this container's effective capability
  set (CapEff=0x…)` → add `--cap-add SYS_ADMIN` (compose:
  `cap_add: [SYS_ADMIN]`; Kubernetes:
  `securityContext.capabilities.add: [SYS_ADMIN]`). A world-readable
  `/dev/fuse` is **not** sufficient on its own; the `mount()` syscall
  needs this capability.
- `❌ This container is running with no-new-privileges (NoNewPrivs=1
  …)` → drop `security_opt: [no-new-privileges:true]` for this
  container, or run `/bin/mount-snapshot` from a **separate** short
  container without that flag. With `no-new-privileges` the kernel
  ignores the setuid bit on `/usr/bin/fusermount` at exec time, so
  FUSE fails with the same `Permission denied` even with
  `CAP_SYS_ADMIN` and `/dev/fuse` correctly in place.
- `❌ AppArmor profile 'docker-default (enforce)' …` → on Ubuntu /
  Debian hosts (and any host shipping Docker's default AppArmor
  template) the `docker-default` profile denies the `mount(2)` syscall
  even when `CAP_SYS_ADMIN` is granted. Add `security_opt:
  [apparmor:unconfined]` (compose), `--security-opt apparmor=unconfined`
  (docker run), the
  `container.apparmor.security.beta.kubernetes.io/<container>:
  unconfined` annotation (Kubernetes ≤1.29) or
  `securityContext.appArmorProfile.type: Unconfined` (Kubernetes ≥1.30)
  for this container. Verify with `cat /proc/self/attr/current` —
  `unconfined` is what you want; `docker-default (enforce)` is what
  blocks FUSE.

You can verify all four signals manually from inside the container:

```shell
docker exec restic-backup-helper sh -c '
  ls -la /dev/fuse                       # must exist, must be character device, 0666
  ls -la /usr/bin/fusermount             # must be setuid (-rwsr-xr-x)
  grep -E "^(CapEff|NoNewPrivs):" /proc/self/status
  cat /proc/self/attr/current            # must be "unconfined"
'
# Expected:
#   CapEff:    00000000a82625fb   ← bit 21 (CAP_SYS_ADMIN) set
#   NoNewPrivs: 0
#   unconfined
```

Docker Compose:

```yaml
services:
  restic-backup:
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse:/dev/fuse
    security_opt:
      - apparmor:unconfined        # required on Ubuntu/Debian hosts; harmless elsewhere
```

Docker run:

```shell
docker run \
  --cap-add SYS_ADMIN \
  --device /dev/fuse \
  --security-opt apparmor=unconfined \
  … marc0janssen/restic-backup-helper:latest
```

Kubernetes:

```yaml
securityContext:
  capabilities:
    add: ["SYS_ADMIN"]
  allowPrivilegeEscalation: true
  appArmorProfile:
    type: Unconfined               # k8s ≥1.30 native field
# For k8s ≤1.29, set this annotation on the Pod instead:
# metadata.annotations:
#   container.apparmor.security.beta.kubernetes.io/<container>: unconfined
```

…plus a `hostPath` volume mounting `/dev/fuse` into the pod.

### `fusermount` exists but is not setuid

A typical symptom is `ls -la /usr/bin/fusermount` showing
`-rwxr-xr-x` (no `s`). `/bin/mount-snapshot` will print:

```text
⚠️ /usr/bin/fusermount is not setuid (no 's' bit). This usually means
the container was started with 'no-new-privileges:true' …
```

That option strips the setuid bit at exec time, so even with
`CAP_SYS_ADMIN` and `/dev/fuse` correctly in place, `fusermount` can no
longer talk to the kernel module and the mount fails with `Permission
denied`. Options:

- Drop `security_opt: [no-new-privileges:true]` / `--security-opt
  no-new-privileges:true` for this container.
- Keep the hardened cron-driven container as-is and run
  `/bin/mount-snapshot` from a **separate**, short-lived container
  started without `no-new-privileges`.

### `/dev/fuse` exists but is not read/writable

```text
❌ /dev/fuse exists but is not read/write accessible. The container
likely lacks 'CAP_SYS_ADMIN' …
```

`/dev/fuse` was forwarded into the container but the container has no
capability to use it. Add `SYS_ADMIN` as documented above.

### Mountpoint still appears mounted after a crash

If `restic mount` was killed hard (`docker kill`, OOM, host reboot)
before `/bin/mount-snapshot` could run its `EXIT` trap, the mountpoint
inside the next container may still be a stale FUSE entry. Force-clean
from inside the container:

```shell
docker exec restic-backup-helper fusermount -u /fusemount
# or, as a last resort
docker exec restic-backup-helper umount /fusemount
```

A subsequent `/bin/mount-snapshot` will succeed once the mountpoint is
empty again.

## See also

- [Restore worker](../workers/backup.md) — full / partial restores when
  you want a writable copy instead of a read-only browse.
- [Snapshot export](../operations/manual-runs.md) — package a snapshot
  as a `tar.gz` archive for offline transfer.
- [JSON summaries](../reference/json-summaries.md) — schema for
  `last-mount-snapshot.json`.
