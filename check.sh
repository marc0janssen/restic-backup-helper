#!/bin/sh

lastcheckLogfile="/home/restic/log/check-last.log"
lastMailLogfile="/home/restic/log/mail-last.log"

copyErrorLog() {
  cp ${lastLogfile} /home/restic/log/check-error-last.log
}

logLast() {
  echo "$1" >> ${lastLogfile}
}

start=`date +%s`
rm -f ${lastcheckLogfile} ${lastMailLogfile}

echo "Starting Check at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Check at $(date)" >> ${lastLogfile}
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

sudo -E -u restic /home/restic/bin/restic check ${RESTIC_CHECK_ARGS} >> ${lastcheckLogfile} 2>&1
checkRC=$?
logLast "Finished check at $(date)"
if [[ $checkRC == 0 ]]; then
    echo "Check Successful"
else
    echo "Check Failed with Status ${backupRC}"
    sudo -E -u restic /home/restic/bin/restic unlock
    copyErrorLog
fi

end=`date +%s`
echo "Finished check at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

if [ -n "${TEAMS_WEBHOOK_URL}" ]; then
    teamsTitle="Restic Last Check Log"
    teamsMessage=$( cat ${lastcheckLogfile} | sed 's/"/\"/g' | sed "s/'/\'/g" | sed ':a;N;$!ba;s/\n/\n\n/g' )
    teamsReqBody="{\"title\": \"${teamsTitle}\", \"text\": \"${teamsMessage}\" }"
    sh -c "curl -H 'Content-Type: application/json' -d '${teamsReqBody}' '${TEAMS_WEBHOOK_URL}' > ${lastMicrosoftTeamsLogfile} 2>&1"
    if [ $? == 0 ]; then
        echo "Microsoft Teams notification successfully sent."
    else
        echo "Sending Microsoft Teams notification FAILED. Check ${lastMicrosoftTeamsLogfile} for further information."
    fi
fi

if ([ -n "${MAILX_ARGS}" ] && [ "${MAILX_ON_ERROR}" == "ON" ] && [[ $checkRC != 0 ]]) || ([ -n "${MAILX_ARGS}" ] && [ "${MAILX_ON_ERROR}" != "ON" ]); then
    sh -c "mailx -v -S sendwait ${MAILX_ARGS} < ${lastcheckLogfile} > ${lastMailLogfile} 2>&1"
    if [ $? == 0 ]; then
        echo "Mail notification successfully sent."
    else
        echo "Sending mail notification FAILED. Check ${lastMailLogfile} for further information."
    fi
fi

