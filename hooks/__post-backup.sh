#!/bin/sh

echo "Start cleaning up ownership."
chown -R 1032:100 ${RESTIC_REPOSITORY}/*
chmod -R 777 ${RESTIC_REPOSITORY}/*
echo "End cleaning up ownership."
