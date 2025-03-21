#!/bin/bash

# Definieer logbestanden
LAST_LOGFILE="/var/log/backup-last.log"
LAST_ERROR_LOGFILE="/var/log/backup-error-last.log"
LAST_MAIL_LOGFILE="/var/log/mail-last.log"
LAST_MICROSOFT_TEAMS_LOGFILE="/var/log/microsoft-teams-last.log"

# Functie om error log te kopiëren
copyErrorLog() {
  cp "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
}

# Functie om naar het laatste logbestand te schrijven
logLast() {
  echo "$1" >> "${LAST_LOGFILE}"
}

# Controleer of pre-backup script bestaat en voer uit
if [ -f "/hooks/pre-backup.sh" ]; then
  echo "Starting pre-backup script ..."
  /hooks/pre-backup.sh
else
  echo "Pre-backup script not found ..."
fi

# Starttijd noteren
start=$(date +%s)

# Logbestanden wissen
rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

# Start van backup noteren
echo "Starting Backup at $(date +"%Y-%m-%d %H:%M:%S")"
echo "Starting Backup at $(date)" >> "${LAST_LOGFILE}"

# Omgevingsvariabelen loggen
logLast "BACKUP_CRON: ${BACKUP_CRON}"
logLast "BACKUP_ROOT_DIR: ${BACKUP_ROOT_DIR}"
logLast "RESTIC_TAG: ${RESTIC_TAG}"
logLast "RESTIC_FORGET_ARGS: ${RESTIC_FORGET_ARGS}"
logLast "RESTIC_JOB_ARGS: ${RESTIC_JOB_ARGS}"
logLast "RESTIC_REPOSITORY: ${RESTIC_REPOSITORY}"
logLast "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}"

# Backup uitvoeren
restic backup "${BACKUP_ROOT_DIR}" "${RESTIC_JOB_ARGS}" --tag="${RESTIC_TAG}" >> "${LAST_LOGFILE}" 2>&1
backupRC=$?

# Einde van backup noteren
logLast "Finished backup at $(date)"

# Foutafhandeling
if [ $backupRC -eq 0 ]; then
  echo "Backup Successful"
else
  echo "Backup Failed with Status ${backupRC}"
  restic unlock
  copyErrorLog
fi

# Forget snapshots uitvoeren als RESTIC_FORGET_ARGS is ingesteld
if [ $backupRC -eq 0 ] && [ -n "${RESTIC_FORGET_ARGS}" ]; then
  echo "Forget about old snapshots based on RESTIC_FORGET_ARGS = ${RESTIC_FORGET_ARGS}"
  restic forget "${RESTIC_FORGET_ARGS}" >> "${LAST_LOGFILE}" 2>&1
  rc=$?
  logLast "Finished forget at $(date)"
  
  # Foutafhandeling voor forget
  if [ $rc -eq 0 ]; then
    echo "Forget Successful"
  else
    echo "Forget Failed with Status ${rc}"
    restic unlock
    copyErrorLog
  fi
fi

# Eindtijd noteren
end=$(date +%s)
echo "Finished backup at $(date +"%Y-%m-%d %H:%M:%S") after $((end-start)) seconds"

# Mail notificatie verzenden
if [ -n "${MAILX_RCPT}" ] && (
  [ "${MAILX_ON_ERROR}" == "ON" ] && [ $backupRC -ne 0 ] ||
  [ "${MAILX_ON_ERROR}" != "ON" ]
); then
  if sh -c "mail -v -s 'Result of the last ${HOSTNAME} backup run on ${RESTIC_REPOSITORY}' ${MAILX_RCPT} < ${LAST_LOGFILE} > ${LAST_MAIL_LOGFILE} 2>&1"; then
    echo "Mail notification successfully sent."
  else
    echo "Sending mail notification FAILED. Check ${LAST_MAIL_LOGFILE} for further information."
  fi
fi

# Controleer of post-backup script bestaat en voer uit
if [ -f "/hooks/post-backup.sh" ]; then
  echo "Starting post-backup script ..."
  /hooks/post-backup.sh $backupRC
else
  echo "Post-backup script not found ..."
fi
