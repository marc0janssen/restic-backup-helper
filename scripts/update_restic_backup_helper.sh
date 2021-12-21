#!/bin/sh

# Name: Restic Backup Helper
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-12-20 17:40:37
# update: 2021-12-20 17:40:41

sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --run-once --cleanup restic-backup-helper
