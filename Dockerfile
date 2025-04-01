FROM restic/restic:0.18.0

RUN apk update && apk upgrade && apk add --update --no-cache mailx fuse curl libcap sudo bash rclone tzdata msmtp

RUN mkdir -p /mnt/restic /var/spool/cron/crontabs /var/log

ENV RESTIC_REPOSITORY="/mnt/restic"
ENV RESTIC_PASSWORD=""
ENV RESTIC_PASSWORD_FILE=""
ENV RESTIC_TAG="automated"
ENV RESTIC_CACHE_DIR="/.cache/restic"
ENV RESTIC_FORGET_ARGS=""
ENV RESTIC_JOB_ARGS=""
ENV RESTIC_CHECK_ARGS=""
ENV NFS_TARGET=""
ENV BACKUP_CRON="0 */6 * * *"
ENV BACKUP_ROOT_DIR=""
ENV CHECK_CRON=""
ENV RCLONE_CONFIG="/config/rclone.conf"
ENV SYNC_JOB_FILE="/config/sync_jobs.txt"
ENV SYNC_JOB_ARGS=""
ENV SYNC_CRON=""
ENV ROTATE_LOG_CRON="0 */6 * * *"
ENV CRON_LOG_MAX_SIZE="1048576"
ENV MAX_CRON_LOG_ARCHIVES="5"
ENV MAILX_RCPT=""
ENV MAILX_ON_ERROR="OFF"
ENV OS_AUTH_URL=""
ENV OS_PROJECT_ID=""
ENV OS_PROJECT_NAME=""
ENV OS_USER_DOMAIN_NAME="Default"
ENV OS_PROJECT_DOMAIN_ID="default"
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
COPY ./.release /.release

RUN chmod 755 /entry.sh /bin/backup /bin/check /bin/bisync /bin/rotate_log

# set sendmail-path
RUN rm -rf /usr/sbin/sendmail && ln -s /usr/bin/msmtp /usr/sbin/sendmail

WORKDIR "/"

ENTRYPOINT ["/entry.sh"]
CMD ["tail","-fn0","/var/log/cron.log"]
