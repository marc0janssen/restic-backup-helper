FROM restic/restic:0.17.3

RUN apk update && apk upgrade && apk add --update --no-cache mailx fuse curl libcap sudo bash rclone tzdata msmtp

RUN mkdir -p /mnt/restic /var/spool/cron/crontabs /var/log

ENV RESTIC_REPOSITORY=/mnt/restic
ENV RESTIC_PASSWORD=""
ENV RESTIC_PASSWORD_FILE=""
ENV RESTIC_TAG=""
ENV NFS_TARGET=""
ENV BACKUP_CRON="0 */6 * * *"
ENV BACKUP_ROOT_DIR="/data"
ENV CHECK_CRON="37 0 1 * *"
ENV RESTIC_FORGET_ARGS=""
ENV RESTIC_JOB_ARGS=""
ENV RESTIC_CHECK_ARGS=""
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
ENV RESTIC_CACHE_DIR="/.cache/restic"
ENV TZ Europe/Amsterdam

# /data is the dir where you have to put the data to be backed up
VOLUME /data

# Copy the worker files
COPY backup.sh /bin/backup
COPY entry.sh /entry.sh
COPY check.sh /bin/check

RUN chmod 755 /bin/backup /entry.sh /bin/check

# set sendmail-path
RUN rm -rf /usr/sbin/sendmail && ln -s /usr/bin/msmtp /usr/sbin/sendmail
RUN touch /var/log/cron.log

WORKDIR "/"

ENTRYPOINT ["/entry.sh"]
CMD ["tail","-fn0","/var/log/cron.log"]
