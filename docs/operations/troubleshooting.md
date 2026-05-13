# Troubleshooting

Common symptoms and what to check first. When in doubt, run
[`/bin/doctor`](diagnostics.md) — it rolls up most of the checks below
into a single command.

## Backup behaviour

??? failure "Backup exits immediately with `Missing RESTIC_TAG`"

    `RESTIC_TAG=""` (explicitly empty) is a hard failure since 1.14.0.
    Pick something meaningful (`daily`, `${HOSTNAME}-data`, …) so
    snapshots can be filtered later.

??? failure "Backup logs success but `restic snapshots` shows zero / tiny snapshots"

    Walk this list:

    1. Confirm the host volume backing `BACKUP_ROOT_DIR` is actually
       mounted into the container:
       ```shell
       docker exec restic-backup-helper ls -la "$BACKUP_ROOT_DIR"
       ```
    2. When you use `--files-from` or `--exclude-file` in
       `RESTIC_JOB_ARGS`, verify those files exist **inside the
       container** and contain real, in-container paths.
    3. Inspect `last-backup.json` for `files_new` and `bytes_added`:
       ```shell
       docker exec restic-backup-helper cat /var/log/last-backup.json
       ```
    4. Run `restic snapshots latest --json` for the canonical file/byte
       counts.

    A misspelled bind mount, an `--files-from` referring to host paths
    the container cannot see, or an over-broad `--exclude-file` all
    produce a successful but empty backup.

??? failure "Empty or wrong backup content"

    Set `BACKUP_ROOT_DIR` and/or `RESTIC_JOB_ARGS` paths intentionally;
    empty both yields a degenerate `restic backup` invocation that
    snapshots… nothing.

## Container startup

??? failure "Container exits with `Repository probe failed for '…' with exit code N`"

    Restic could reach the repository service but the repository itself
    is unhealthy. Restic exit codes you may see:

    | Code | Cause |
    | --- | --- |
    | `12` | Wrong password. |
    | other | Network, DNS, TLS, auth or upstream service error. |

    Read the restic stderr in the container log; the entrypoint
    deliberately refuses to run `restic init` for any non-`10` exit so
    that a transient failure cannot silently re-init a healthy remote.

    As a last resort, set `RESTIC_CHECK_REPOSITORY_STATUS=OFF` to
    bypass the probe — you lose the auto-init safety net but unblock
    troubleshooting.

??? failure "TLS / certificate errors against the repository or a corporate proxy"

    Mount the PEM bundle into the container and set `RESTIC_CACERT` to
    its path. The flag is appended to every restic invocation
    automatically; `config-check` will fail when the path is
    unreadable.

??? failure "NFS mount fails at startup"

    The container aborts with exit `1` when `NFS_TARGET` is set but the
    mount fails. Check:

    - The NFS server hostname resolves from inside the container.
    - The container has `cap_add: [SYS_ADMIN]`.
    - The export allows the container's outbound IP.

## Notifications

??? failure "Webhook never reaches the endpoint and the cron log is silent"

    Confirm `WEBHOOK_URL` is set inside the container:

    ```shell
    docker exec restic-backup-helper env | grep WEBHOOK
    ```

    Container logs only show `scheme://host/...`. Test connectivity from
    inside the container:

    ```shell
    docker exec -ti restic-backup-helper curl -fsS \
      -X POST -H 'Content-Type: application/json' \
      -d '{"test":true}' "$WEBHOOK_URL"
    ```

??? failure "Hook never returns / blocks the next cron run"

    Set `HOOK_TIMEOUT` to a positive integer (seconds). The hook is
    wrapped in `timeout`; exit `124` is logged as a timeout but does
    not fail the underlying restic job.

??? failure "Mail goes nowhere and `cron.log` does not mention msmtp"

    Check that `MAILX_RCPT` is set, then verify msmtp config:

    ```shell
    docker exec restic-backup-helper ls -la /etc/msmtprc
    docker exec restic-backup-helper sendmail -t <<EOF
    From: test@example.com
    To: ${MAILX_RCPT}
    Subject: msmtp test

    Test body.
    EOF
    ```

    `msmtp` refuses to read a config that is group- or world-readable;
    `chmod 600` on the host file.

## Locking and overlapping ticks

??? failure "Restic reports `unable to create lock in backend: repository is already locked`"

    List the locks first and confirm whose they are before clearing:

    ```shell
    docker exec restic-backup-helper restic list locks
    docker exec restic-backup-helper /bin/unlock --dry-run
    docker exec restic-backup-helper /bin/unlock
    ```

    Since 1.12.0 the helper no longer auto-unlocks after a failure
    (safer for multi-host repos). Set `RESTIC_AUTO_UNLOCK=ON` to
    restore the previous behaviour **only if you back up from one
    host**.

    Prefer the audited [`/bin/unlock`](unlock.md) wrapper over a raw
    `restic unlock`: it masks the repository URL, writes
    `last-unlock.json`, runs `pre-unlock` / `post-unlock` hooks and
    fires the same mail / webhook plumbing as the cron-driven workers.

??? failure "Cron tick logs `⏭ <job> skipped: previous run still active`"

    The previous backup/check/replicate/rotate is still holding its
    local `flock`. Confirm the long-running PID inside the container:

    ```shell
    docker exec restic-backup-helper ps -ef
    ```

    Either wait, kill it, or widen the cron interval. If the lock
    process is gone but the flock is somehow still held, restart the
    container.

??? failure "Backup log shows `⏭ Forget skipped: repository was locked by another host (exit 11)`"

    On a repository shared by multiple hosts, two `restic backup` runs
    that finish at the same time both try to acquire the exclusive
    lock that `restic forget` requires. Only one wins; the other
    returns restic exit `11` ("failed to lock repository") almost
    immediately. Since 2.4.1 the backup worker treats this as an
    informational skip:

    - the backup itself still exits `0`,
    - `last-backup.json` records `forget_exit_code: 11` alongside
      `exit_code: 0` so monitoring can spot persistent skipping,
    - **`restic unlock` is intentionally NOT run** on exit `11`
      regardless of `RESTIC_AUTO_UNLOCK`, because the lock that
      blocked the run is another host's legitimate exclusive lock.
      If you have independently confirmed the lock is stale, use
      [`/bin/unlock`](unlock.md) to clear it explicitly.

    Retention is cumulative, so a single skipped forget is harmless —
    the next backup tick will catch up. Three increasingly thorough
    ways to avoid the skip:

    1. **Move retention to a dedicated worker via `FORGET_CRON`**
       (since 2.5.0, the recommended pattern for multi-host repos).
       When set, `/bin/backup` skips its inline post-backup forget
       and the standalone `/bin/forget` worker owns the exclusive
       lock window. The exit-11 race disappears because backups no
       longer try to take the forget-lock:
       ```yaml
       FORGET_CRON: "30 1 * * *"
       RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
       ```
       Stagger `FORGET_CRON` between hosts (or run it from a single
       maintenance-owner container) so the dedicated windows do not
       converge in turn. Full details in [Forget worker](../workers/forget.md).
    2. **Add `--retry-lock=DURATION` to `RESTIC_FORGET_ARGS`** (restic
       ≥ 0.16). Restic waits up to that duration for the lock instead
       of returning exit `11` — works both for the inline path and
       inside the dedicated worker:
       ```yaml
       RESTIC_FORGET_ARGS: "--retry-lock=5m --keep-daily 7 --keep-weekly 8 --keep-monthly 12"
       ```
    3. **Stagger `BACKUP_CRON` between hosts** so the two backup
       windows do not converge on the same forget moment. For example
       `5 */4 * * *` on host A vs. `35 */4 * * *` on host B.

    A persistent `forget_exit_code: 11` across many runs (look at
    `last-backup.json` history or the
    `restic_backup_last_forget_exit_code` Prometheus gauge — emitted
    automatically because the value is numeric) means the schedules
    are colliding every tick — staggering the cron usually fixes it
    without restic flags.

    See also [Backup worker → Multi-host repositories and exit 11](../workers/backup.md#multi-host-repositories-and-exit-11).

## Time and timezones

??? failure "Cron fires at the wrong local time"

    Set `TZ` and restart the container. busybox `crond` reads `TZ` from
    its process environment at startup, so changing `TZ` *after* the
    container has started does **not** affect the running cron daemon.

??? failure "Mail subject timestamps are off"

    The subject uses the container's `TZ`. Set `TZ=UTC` if you prefer
    everything in UTC and have multi-region operators.

## Rclone and replicate

??? failure "Rclone auth keeps breaking after a token refresh"

    Ensure `rclone.conf` is on a **writable** mount. Some providers
    (Google Drive, Jottacloud, OneDrive, …) write back to
    `rclone.conf` when the access token is refreshed. A read-only
    bind-mount means rclone cannot persist the refreshed token and
    must re-authenticate on every run.

??? failure "Bisync recovery deleted data on the destination"

    The default bisync recovery (copy both → `bisync --resync`) can
    propagate one-sided deletes. Two safety knobs:

    - Set `REPLICATE_BISYNC_CHECK_ACCESS=ON` and seed an
      `RCLONE_TEST` marker file on both endpoints. Rclone aborts loudly
      when the marker is missing.
    - Switch to `MODE=sync` or `MODE=copy` in your job file when you
      don't actually need bidirectional behaviour. One-way modes skip
      the destructive copy-both recovery.

    See [Replicate worker](../workers/replicate.md#bisync-recovery-hardening).

## Permissions

??? failure "Permission denied reading source paths"

    Either:

    - Match UID/GID of the host filesystem on the mounted volume (the
      container runs as root by default, so this typically only
      happens with rootless Docker or restrictive SELinux/AppArmor).
    - Add `cap_add: [DAC_READ_SEARCH]` so the container can bypass
      DAC restrictions for reading (does not allow writes).

??? failure "Permission denied writing `/restore` after a restore"

    The restore wrapper does **not** chown by default. Add
    `--owner UID:GID` to set ownership of the restored tree, or write a
    `/hooks/post-restore.sh` that does whatever you need.

??? failure "`/bin/mount-snapshot` exits with `fusermount: mount failed: Permission denied`"

    `restic mount` (FUSE) needs **all** of the following on the
    container that runs the helper, and `/bin/mount-snapshot`
    pre-flights every one of them — the abort message names the
    specific knob that is wrong:

    - `--cap-add SYS_ADMIN` (compose: `cap_add: [SYS_ADMIN]`; Kubernetes:
      `securityContext.capabilities.add: [SYS_ADMIN]`). The helper
      checks `CapEff` in `/proc/self/status` for bit 21
      (`0x200000`); when the bit is missing it aborts with the
      observed `CapEff` value so you can spot which capability set
      you ended up with.
    - `--device /dev/fuse` (compose: `devices: [/dev/fuse:/dev/fuse]`;
      Kubernetes: a `hostPath` `/dev/fuse` volume plus
      `volumeDevices`).
    - `/usr/bin/fusermount` must keep its setuid bit at runtime.
      Starting the container with `--security-opt
      no-new-privileges:true` (compose: `security_opt:
      [no-new-privileges:true]`) leaves the on-disk bit alone but
      tells the kernel to ignore it at exec; the helper reads
      `NoNewPrivs` from `/proc/self/status` and aborts when it is
      `1`.
    - The AppArmor profile must allow `mount(2)`. On Ubuntu/Debian
      hosts (and any host shipping Docker's default AppArmor
      template) the active profile is `docker-default (enforce)`,
      which **denies `mount(2)` even with `CAP_SYS_ADMIN`**, so FUSE
      fails with the same `Permission denied`. The helper reads
      `/proc/self/attr/current` and aborts when the profile is
      enforcing; add `security_opt: [apparmor:unconfined]` (compose),
      `--security-opt apparmor=unconfined` (docker run),
      `container.apparmor.security.beta.kubernetes.io/<container>:
      unconfined` annotation (Kubernetes ≤1.29) or
      `securityContext.appArmorProfile.type: Unconfined` (Kubernetes
      ≥1.30) for this container.
    - The image must ship the `fuse` apk package so that
      `/usr/bin/fusermount` exists at all. The current helper image
      installs it in the Dockerfile; if you are seeing
      `❌ /usr/bin/fusermount is missing from PATH` your image is
      older than the package addition — rebuild from the current
      sources or `apk add --no-cache fuse` for a one-shot smoke test.

    If you keep the cron-driven container hardened with
    `no-new-privileges:true` or `apparmor=docker-default`, run
    `mount-snapshot` from a **separate** short-lived container without
    those flags, with `--cap-add SYS_ADMIN --device /dev/fuse
    --security-opt apparmor=unconfined` and your normal repository
    env. See [Mount snapshot →
    Troubleshooting](mount-snapshot.md#troubleshooting).

## Networking

??? failure "Pull / push fails via corporate proxy to a private registry or LAN host"

    Add the registry hostname or LAN ranges to `NO_PROXY` /
    `no_proxy`:

    ```shell
    NO_PROXY=192.168.0.0/16,.internal,myregistry.local
    ```

    Verify TLS to internal registries; corporate CAs need to be on the
    host (for `docker pull`) **and** inside the container (via
    `RESTIC_CACERT` for repository TLS).

## When you've tried everything

1. Run `/bin/doctor` and read every section. It is designed to surface
   the 90% of problems above without you having to remember which env
   var / path / hook to check first.
2. Run `docker exec restic-backup-helper tail -n 200 /var/log/cron.log`
   for the cron-side narrative.
3. Open an issue at
   [github.com/marc0janssen/restic-backup-helper/issues](https://github.com/marc0janssen/restic-backup-helper/issues)
   with the doctor output, the relevant `last-<job>.json`, and the
   tail of `cron.log`. Sensitive values are already masked by the
   helper.
