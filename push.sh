#!/bin/sh

# Name: restic-backup-helper
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-12-20 21:06:14
# update: 2021-12-20 21:06:22

docker push marc0janssen/restic-backup-helper:latest
docker pushrm marc0janssen/restic-backup-helper:latest
