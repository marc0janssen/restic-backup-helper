#!/bin/bash

lastLogfile="/home/restic/log/backup-last.log"
lasterrorlogfile="/home/restic/log/backup-error-last.log"
lastMailLogfile="/home/restic/log/mail-last.log"
lastMicrosoftTeamsLogfile="/home/restic/log/microsoft-teams-last.log"

copyErrorLog() {
  cp ${lastLogfile} ${lasterrorlogfile}
}

logLast() {
  echo "$1" >> ${lastLogfile}
}

if [ -f "/hooks/pre-backup.sh" ]; then
    echo "Starting pre-backup script ..."
    /hooks/pre-backup.sh
else
    echo "Pre-backup script not found ..."
fi

start=$(date +%s)
rm -f ${lastLogfile} ${lastMailLogfile}
echo "Starting Backup at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Backup at $(date)" >> ${lastLogfile}
logLast "BACKUP_CRON: ${BACKUP_CRON}"
logLast "BACKUP_ROOT_DIR: ${BACKUP_ROOT_DIR}"
logLast "RESTIC_TAG: ${RESTIC_TAG}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

# Do not save full backup log to logfile but to backup-last.log
sudo -E -u restic /home/restic/bin/restic backup ${BACKUP_ROOT_DIR} ${RESTIC_JOB_ARGS} --tag=${RESTIC_TAG?"Missing environment variable RESTIC_TAG"} >> ${lastLogfile} 2>&1
backupRC=$?
logLast "Finished backup at $(date)"
if [[ $backupRC == 0 ]]; then
    echo "Backup Successful"
else
    echo "Backup Failed with Status ${backupRC}"
    sudo -E -u restic /home/restic/bin/restic unlock
    copyErrorLog
fi

if [[ $backupRC == 0 ]] && [ -n "${RESTIC_FORGET_ARGS}" ]; then
    echo "Forget about old snapshots based on RESTIC_FORGET_ARGS = ${RESTIC_FORGET_ARGS}"
    sudo -E -u restic /home/restic/bin/restic forget ${RESTIC_FORGET_ARGS} >> ${lastLogfile} 2>&1
    rc=$?
    logLast "Finished forget at $(date)"
    if [[ $rc == 0 ]]; then
        echo "Forget Successful"
    else
        echo "Forget Failed with Status ${rc}"
        sudo -E -u restic /home/restic/bin/restic unlock
        copyErrorLog
    fi
fi

end=$(date +%s)
echo "Finished Backup at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

if { [ -n "${MAILX_ARGS}" ] && [ "${MAILX_ON_ERROR}" == "ON" ] && [[ $backupRC != 0 ]]; } || { [ -n "${MAILX_ARGS}" ] && [ "${MAILX_ON_ERROR}" != "ON" ]; }; then
    if sh -c "mailx -v -S sendwait -s 'Result of the last ${HOSTNAME} backup run on ${RESTIC_REPOSITORY}' ${MAILX_ARGS} < ${lastLogfile} > ${lastMailLogfile} 2>&1"; then
        echo "Mail notification successfully sent."
    else
        echo "Sending mail notification FAILED. Check ${lastMailLogfile} for further information."
    fi
fi

if [ -f "/hooks/post-backup.sh" ]; then
    echo "Starting post-backup script ..."
    /hooks/post-backup.sh $backupRC
else
    echo "Post-backup script not found ..."
fi
