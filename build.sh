#!/bin/sh

# Name: restic-backup-helper
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-12-20 17:01:55
# update: 2021-12-20 17:02:00

docker image rm marc0janssen/restic-backup-helper:latest
docker build -t marc0janssen/restic-backup-helper:latest -f ./Dockerfile .
