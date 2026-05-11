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
#
# `apk upgrade` deliberately omitted: the Restic base image is rebuilt by
# upstream on a known cadence; running `apk upgrade` here makes the helper
# image non-reproducible across builds without adding meaningful security
# value beyond the base layer's existing patch level. CVE coverage is the
# Trivy/security-scan workflow's job and rebuilds against newer upstream tags.
RUN apk add --no-cache bash curl fuse libcap mailx msmtp sshpass sudo tzdata

# Optional pinning. Empty value (default) installs the latest stable rclone:
# version is resolved via downloads.rclone.org/version.txt, then the zip is
# downloaded from /v<version>/ and checksum-verified against the per-version
# SHA256SUMS. Pass --build-arg RCLONE_VERSION=1.74.1 to pin a specific version.
ARG RCLONE_VERSION=""
COPY /app/install_rclone.sh /install_rclone.sh
RUN RCLONE_VERSION="${RCLONE_VERSION}" bash /install_rclone.sh && rm -rf /install_rclone.sh

RUN mkdir -p /mnt/restic /var/spool/cron/crontabs /var/log

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
ENV PRUNE_CRON=""
ENV RCLONE_CONFIG="/config/rclone.conf"
ENV SYNC_JOB_FILE="/config/sync_jobs.txt"
ENV SYNC_JOB_ARGS=""
ENV SYNC_CRON=""
ENV SYNC_VERBOSE="ON"
ENV SYNC_BISYNC_CHECK_ACCESS="OFF"
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
COPY /app/bisync.sh /bin/bisync
COPY /app/rotate_log.sh /bin/rotate_log
COPY /app/prune.sh /bin/prune
# Operator-friendly restore wrapper: flag-driven for scripts/CI, interactive
# when invoked from `docker exec -ti`. Not cron-driven by design (restores are
# always operator-initiated); shares mail/webhook/metrics plumbing with the
# other workers.
COPY /app/restore.sh /bin/restore
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
RUN chmod 755 /entry.sh /bin/backup /bin/check /bin/bisync /bin/rotate_log /bin/prune /bin/restore /bin/locked_run

# set sendmail-path
RUN rm -rf /usr/sbin/sendmail && ln -s /usr/bin/msmtp /usr/sbin/sendmail

WORKDIR "/"

ENTRYPOINT ["/entry.sh"]
CMD ["tail","-fn0","/var/log/cron.log"]
