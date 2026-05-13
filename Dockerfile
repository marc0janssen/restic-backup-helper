FROM restic/restic:0.18.1

# rclone is intentionally NOT installed via apk; install_rclone.sh fetches a
# checksum-verified upstream binary so the image always ships a current,
# reproducible rclone (Alpine's package version often lags upstream features
# needed for backends like Jottacloud / S3 / Drive).
#
# Why each apk package:
#   bash         worker scripts use bash 4+ syntax (${var,,}, etc.)
#   curl         used by install_rclone.sh for downloads/checksums and by
#                /bin/lib.sh::notify_webhook for HTTP webhook delivery
#   fuse         needed for `restic mount` (FUSE) when browsing snapshots
#   libcap       provides setcap helpers used by FUSE / NFS workflows
#   mailx + msmtp  /bin/lib.sh::notify_mail pipes the per-run log via mail(1);
#                msmtp is the SMTP relay (sendmail symlink set below)
#   sshpass      used by `sftp:` repositories that need non-key SSH auth
#   sudo         retained for hook scripts that need to drop privileges
#   tzdata       enables the TZ env var so cron fires in the operator's TZ
#   util-linux   ships `script(1)`, used by /bin/restore --verbose to wrap
#                restic in a pseudo-TTY so its native in-place progress bar
#                (`[time] X% files, MiB/s, ETA …`) renders even when the
#                wrapper tees stdout into restore-last.log. Without it the
#                tee pipe makes restic believe stdout is not a terminal and
#                the bar is suppressed.
#
# `apk upgrade` deliberately omitted: the Restic base image is rebuilt by
# upstream on a known cadence; running `apk upgrade` here makes the helper
# image non-reproducible across builds without adding meaningful security
# value beyond the base layer's existing patch level. CVE coverage is the
# Trivy/security-scan workflow's job and rebuilds against newer upstream tags.
RUN apk add --no-cache bash curl fuse libcap mailx msmtp sshpass sudo tzdata util-linux

# Optional pinning. Empty value (default) installs the latest stable rclone:
# version is resolved via downloads.rclone.org/version.txt, then the zip is
# downloaded from /v<version>/ and checksum-verified against the per-version
# SHA256SUMS. Pass --build-arg RCLONE_VERSION=1.74.1 to pin a specific version.
ARG RCLONE_VERSION=""
COPY /app/install_rclone.sh /install_rclone.sh
RUN RCLONE_VERSION="${RCLONE_VERSION}" bash /install_rclone.sh && rm -rf /install_rclone.sh

RUN mkdir -p /mnt/restic /var/spool/cron/crontabs /var/log /fusemount

ENV RESTIC_REPOSITORY="/mnt/restic"
ENV RESTIC_PASSWORD=""
ENV RESTIC_PASSWORD_FILE=""
ENV RESTIC_TAG="automated"
ENV RESTIC_CACHE_DIR="/.cache/restic"
ENV RESTIC_FORGET_ARGS=""
ENV RESTIC_JOB_ARGS=""
ENV RESTIC_CHECK_ARGS=""
ENV RESTIC_PRUNE_ARGS=""
ENV RESTIC_CHECK_REPOSITORY_STATUS="ON"
ENV RESTIC_CACERT=""
ENV RESTIC_AUTO_UNLOCK="OFF"
ENV NFS_TARGET=""
ENV BACKUP_CRON="0 */6 * * *"
ENV BACKUP_ROOT_DIR=""
ENV CHECK_CRON=""
ENV FORGET_CRON=""
ENV PRUNE_CRON=""
ENV RCLONE_CONFIG="/config/rclone.conf"
ENV REPLICATE_JOB_FILE="/config/replicate_jobs.txt"
ENV REPLICATE_JOB_ARGS=""
ENV REPLICATE_CRON=""
ENV REPLICATE_VERBOSE="ON"
ENV REPLICATE_BISYNC_CHECK_ACCESS="OFF"
# Deprecated compatibility aliases for the old sync/bisync surface; accepted
# by /entry.sh and /bin/replicate until 3.0.0. Prefer REPLICATE_* above.
ENV SYNC_JOB_FILE=""
ENV SYNC_JOB_ARGS=""
ENV SYNC_CRON=""
ENV SYNC_VERBOSE=""
ENV SYNC_BISYNC_CHECK_ACCESS=""
ENV METRICS_DIR=""
ENV ROTATE_LOG_CRON="0 0 * * 6"
ENV CRON_LOG_MAX_SIZE="1048576"
ENV MAX_CRON_LOG_ARCHIVES="5"
ENV HOOK_TIMEOUT="0"
ENV MAILX_RCPT=""
ENV MAILX_ON_ERROR="OFF"
ENV WEBHOOK_URL=""
ENV WEBHOOK_HEADER_AUTH=""
ENV WEBHOOK_TIMEOUT="10"
ENV WEBHOOK_ON_ERROR="OFF"
ENV OS_AUTH_URL=""
ENV OS_PROJECT_ID=""
ENV OS_PROJECT_NAME=""
ENV OS_USER_DOMAIN_NAME="Default"
ENV OS_PROJECT_DOMAIN_ID="Default"
ENV OS_USERNAME=""
ENV OS_PASSWORD=""
ENV OS_REGION_NAME=""
ENV OS_INTERFACE=""
ENV OS_IDENTITY_API_VERSION=3
ENV TZ=Europe/Amsterdam

# /data is the dir where you have to put the data to be backed up
VOLUME /data

# Copy the worker files
COPY /app/entry.sh /entry.sh
COPY /app/backup.sh /bin/backup
COPY /app/check.sh /bin/check
COPY /app/replicate.sh /bin/replicate
COPY /app/rotate_log.sh /bin/rotate_log
COPY /app/prune.sh /bin/prune
# Standalone retention worker; activates when FORGET_CRON is non-empty.
# When set, /bin/backup skips its inline post-backup `restic forget` so
# the repository's exclusive forget-lock is only taken by this dedicated
# maintenance window (avoids the multi-host exit-11 race). Reuses
# RESTIC_FORGET_ARGS verbatim.
COPY /app/forget.sh /bin/forget
# Read-only diagnostics: prints effective env, path checks, repo probe, hooks,
# replicate job-file validation and recent last-*.json/log context.
COPY /app/doctor.sh /bin/doctor
# Read-only cron diagnostics: prints rendered crontab, timezone and schedules.
COPY /app/cron_list.sh /bin/cron-list
# Operator export helper: restores a snapshot/subtree into a temporary workdir
# and packages it as a tar.gz archive under /restore (or --output).
COPY /app/snapshot_export.sh /bin/snapshot-export
# Operator retention preview helper: runs restic forget --dry-run using
# RESTIC_FORGET_ARGS and host/tag scope by default.
COPY /app/forget_preview.sh /bin/forget-preview
# Operator FUSE-mount helper: wraps `restic mount` with safe target
# validation (refuses /data / BACKUP_ROOT_DIR / system dirs unless --force)
# and an EXIT trap that unmounts cleanly on Ctrl+C, SIGTERM or crash.
# Defaults --target to /fusemount (container-internal) so the FUSE mount
# never collides with /bin/restore output or a host bind-mount on /restore.
COPY /app/mount_snapshot.sh /bin/mount-snapshot
# Operator manual-unlock helper. Pairs with the safer RESTIC_AUTO_UNLOCK=OFF
# default: workers never auto-clear locks on failure, so on shared
# repositories a legitimate concurrent lock is preserved. Run /bin/unlock
# yourself once you have confirmed the lock is stale; emits the same
# log / JSON / metrics / mail / webhook / hook surface as the other wrappers.
COPY /app/unlock.sh /bin/unlock
# Operator pre-flight inventory: reports readability, type, file count and
# (optional) size for BACKUP_ROOT_DIR plus every --files-from /
# --exclude-file reference inside RESTIC_JOB_ARGS. Read-only; estimates
# only — exclude rules are NOT subtracted from the size figure.
COPY /app/sources_report.sh /bin/sources-report
# Operator-driven bootstrap helper: explicit `restic init` wrapper with a
# type-to-confirm prompt and a --dry-run mode that prints the planned
# command without mutating anything. Complements
# RESTIC_CHECK_REPOSITORY_STATUS=OFF (auto-init probe disabled) — same
# audit surface (log, JSON, metrics, mail, webhook, hooks) as the other
# wrappers.
COPY /app/init_repo.sh /bin/init-repo
# Operator notification test helper: sends clearly-labelled mail and/or
# webhook payloads through the same notify_mail / notify_webhook helpers
# used by real jobs so operators can validate msmtp, auth headers and
# timeout handling without waiting for a real worker failure.
COPY /app/notify_test.sh /bin/notify-test
# Operator-friendly restore wrapper: flag-driven for scripts/CI, interactive
# when invoked from `docker exec -ti`. Not cron-driven by design (restores are
# always operator-initiated); shares mail/webhook/metrics plumbing with the
# other workers.
COPY /app/restore.sh /bin/restore
# Restore-rehearsal / disaster-recovery test: restores a snapshot (or
# sub-path) into an auto-mktemp tempdir, verifies file count + optional
# SHA-256 canary checksums, cleans up, and emits the same audit surface
# (log / last-restore-test.json / restic_restore_test.prom / mail / webhook /
# pre-/post-restore-test hooks). Complements `restic check` (repo health)
# by proving the bytes can actually come back.
COPY /app/restore_test.sh /bin/restore-test
# Lock-aware cron wrapper used by /entry.sh to log "skipped: previous run
# still active" instead of leaving cron with an opaque flock exit code.
COPY /app/locked_run.sh /bin/locked_run
# Sourced by /entry.sh and the workers; kept readable but not executable.
COPY /app/lib.sh /bin/lib.sh
# Baked at build: ./build.sh passes --build-arg (no repo .release file).
ARG RESTIC_BACKUP_HELPER_RELEASE=unknown
LABEL org.opencontainers.image.title="restic-backup-helper" \
	org.opencontainers.image.version="${RESTIC_BACKUP_HELPER_RELEASE}"
ENV RESTIC_BACKUP_HELPER_RELEASE=${RESTIC_BACKUP_HELPER_RELEASE}
RUN chmod 755 /entry.sh /bin/backup /bin/check /bin/replicate /bin/rotate_log /bin/prune /bin/forget /bin/doctor /bin/cron-list /bin/snapshot-export /bin/forget-preview /bin/mount-snapshot /bin/unlock /bin/sources-report /bin/init-repo /bin/notify-test /bin/restore /bin/restore-test /bin/locked_run \
	&& ln -s replicate /bin/bisync

# set sendmail-path
RUN rm -rf /usr/sbin/sendmail && ln -s /usr/bin/msmtp /usr/sbin/sendmail

WORKDIR "/"

ENTRYPOINT ["/entry.sh"]
CMD ["tail","-fn0","/var/log/cron.log"]
