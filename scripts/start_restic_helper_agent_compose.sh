#!/bin/sh

# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# =========================================================

docker-compose -p "restic_backup_helper" -f ./docker-compose.yml up -d --remove-orphans
