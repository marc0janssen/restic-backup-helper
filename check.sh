#!/bin/bash

lastcheckLogfile="/var/log/check-last.log"
lasterrorchecklogfile="/var/log/check-error-last.log"
lastMailLogfile="/var/log/mail-last.log"

copyErrorLog() {
  cp ${lastcheckLogfile} ${lasterrorchecklogfile}
}

logLast() {
  echo "$1" >> ${lastcheckLogfile}
}

if [ -f "/hooks/pre-check.sh" ]; then
    echo "Starting pre-check script ..."
    /hooks/pre-check.sh
else
    echo "Pre-check script not found ..."
fi

start=$(date +%s)
rm -f ${lastcheckLogfile} ${lastMailLogfile}

echo "Starting Check at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Check at $(date)" >> ${lastcheckLogfile}
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

#sudo -E -u restic /home/restic/bin/restic check ${RESTIC_CHECK_ARGS} >> ${lastcheckLogfile} 2>&1
restic check ${RESTIC_CHECK_ARGS} >> ${lastcheckLogfile} 2>&1
checkRC=$?
logLast "Finished check at $(date)"
if [[ $checkRC == 0 ]]; then
    echo "Check Successful"
else
    echo "Check Failed with Status ${checkRC}"
#    sudo -E -u restic /home/restic/bin/restic unlock
    restic unlock
    copyErrorLog
fi

end=$(date +%s)
echo "Finished check at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

if [ -n "${MAILX_RCPT}" ] && (
    [ "${MAILX_ON_ERROR}" == "ON" ] && [ $backupRC -ne 0 ] ||
    [ "${MAILX_ON_ERROR}" != "ON" ]
); then
    if sh -c "mail -v -s 'Result of the last ${HOSTNAME} check run on ${RESTIC_REPOSITORY}' ${MAILX_RCPT} < ${lastcheckLogfile} > ${lastMailLogfile} 2>&1"; then
        echo "Mail notification successfully sent."
    else
        echo "Sending mail notification FAILED. Check ${lastMailLogfile} for further information."
    fi
fi

if [ -f "/hooks/post-check.sh" ]; then
    echo "Starting post-check script ..."
    /hooks/post-check.sh $checkRC
else
    echo "Post-check script not found ..."
fi