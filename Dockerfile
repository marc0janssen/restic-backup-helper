FROM alpine:latest as rclone

# Get rclone executable
ADD https://downloads.rclone.org/rclone-current-linux-amd64.zip /
RUN unzip rclone-current-linux-amd64.zip && mv rclone-*-linux-amd64/rclone /bin/rclone && chmod +x /bin/rclone

FROM restic/restic:0.12.1

RUN apk update && apk upgrade && apk add --update --no-cache heirloom-mailx fuse curl libcap sudo

COPY --from=rclone /bin/rclone /bin/rclone

# Creating user for running restic non-root
RUN adduser -G users -S -s /sbin/nologin restic && \
    adduser restic wheel && \
    echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel

# Setup crontabs, cronlogging and expose log dirextory
RUN \
    mkdir -p /mnt/restic /var/spool/cron/crontabs /home/restic/log; \
    touch /home/restic/log/cron.log; \
    ln -s /home/restic/log /

# Extended attribute to the restic binary
RUN mkdir ~restic/bin; \
    cp /usr/bin/restic ~restic/bin/; \
    chown root:wheel ~restic/bin/restic; \
    chmod 750 ~restic/bin/restic; \
    setcap cap_dac_read_search=+ep ~restic/bin/restic; \
    apk del libcap; \
    rm -f /var/cache/apk/*

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
ENV MAILX_ARGS=""
ENV MAILX_ON_ERROR=""
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

# openshift fix
RUN mkdir -p /.cache/restic && \
    chgrp -R 0 /.cache && \
    chmod -R g=u /.cache && \
    chgrp -R 0 /mnt && \
    chmod -R g=u /mnt && \
    chgrp -R 0 /var/spool/cron/crontabs/root && \
    chmod -R g=u /var/spool/cron/crontabs/root && \
    chgrp -R 0 /home/restic/log/cron.log && \
    chmod -R g=u /home/restic/log/cron.log

# /data is the dir where you have to put the data to be backed up
VOLUME /data
VOLUME /log

COPY backup.sh /bin/backup
COPY entry.sh /entry.sh
COPY check.sh /bin/check

RUN chmod 755 /bin/backup /entry.sh /bin/check

WORKDIR "/"

ENTRYPOINT ["/entry.sh"]
CMD ["tail","-fn0","/home/restic/log/cron.log"]
