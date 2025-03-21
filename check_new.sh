#!/bin/bash

# Definieer logbestanden
LAST_CHECK_LOGFILE="/var/log/check-last.log"
LAST_ERROR_CHECK_LOGFILE="/var/log/check-error-last.log"
LAST_MAIL_LOGFILE="/var/log/mail-last.log"

# Functie om error log te kopiëren
copyErrorLog() {
  cp "${LAST_CHECK_LOGFILE}" "${LAST_ERROR_CHECK_LOGFILE}"
}

# Functie om naar het laatste logbestand te schrijven
logLast() {
  echo "$1" >> "${LAST_CHECK_LOGFILE}"
}

# Controleer of pre-check script bestaat en voer uit
if [ -f "/hooks/pre-check.sh" ]; then
  echo "Starting pre-check script 🚀..."
  /hooks/pre-check.sh
else
  echo "Pre-check script not found 😐..."
fi

# Starttijd noteren
start=$(date +%s)

# Logbestanden wissen
rm -f "${LAST_CHECK_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Start van check noteren
echo "Starting Check at $(date +"%Y-%m-%d %H:%M:%S") 🕒"
echo "Starting Check at $(date)" >> "${LAST_CHECK_LOGFILE}"

# Omgevingsvariabelen loggen
logLast "CHECK_CRON: ${CHECK_CRON}"
logLast "RESTIC_CHECK_ARGS: ${RESTIC_CHECK_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

# Check uitvoeren
restic check "${RESTIC_CHECK_ARGS}" >> "${LAST_CHECK_LOGFILE}" 2>&1
checkRC=$?

# Einde van check noteren
logLast "Finished check at $(date)"

# Foutafhandeling
if [ $checkRC -eq 0 ]; then
  echo "Check Successful 🎉✅"
else
  echo "Check Failed with Status ${checkRC} 😔"
  restic unlock
  copyErrorLog
fi

# Eindtijd noteren
end=$(date +%s)
echo "Finished check at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds ⏱️"

# Mail notificatie verzenden
if [ -n "${MAILX_RCPT}" ] && (
  [ "${MAILX_ON_ERROR}" == "ON" ] && [ $checkRC -ne 0 ] ||
  [ "${MAILX_ON_ERROR}" != "ON" ]
); then
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} check run on ${RESTIC_REPOSITORY}' ${MAILX_RCPT} < ${LAST_CHECK_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
    echo "Mail notification successfully sent 📨✅"
  else
    echo "Sending mail notification FAILED 🚫😐. Check ${LAST_MAIL_LOGFILE} for further information."
  fi
fi

# Controleer of post-check script bestaat en voer uit
if [ -f "/hooks/post-check.sh" ]; then
  echo "Starting post-check script 🚀..."
  /hooks/post-check.sh $checkRC
else
  echo "Post-check script not found 😐..."
fi
