#!/bin/bash

# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# date: 2021-11-28 14:24:26
# update: 2025-03-23 11:30:32

RELEASE_FILE=".release"

# Read release number from file
RELEASE=$(cat ${RELEASE_FILE})

# Split release in major, minor, patch and rest
IFS='.-' read -r MAJOR MINOR BUILD REST <<< "${RELEASE}"

# Rise buildnumber
BUILD=$((BUILD + 1))

# New release nummer
NEW_RELEASE="${MAJOR}.${MINOR}.${BUILD}-${REST}"

# Write new releasenumber to file
echo "$NEW_RELEASE" > $RELEASE_FILE

# Set development state
echo "dev" > .state

# Change new releasenumber in files
# Only change the lines with "-dev"
sed -i '' "s/restic-backup-helper:[0-9.]*-[0-9.]*-dev/restic-backup-helper:${NEW_RELEASE}-dev/" ./README.md

docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:develop -f ./Dockerfile .
docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${NEW_RELEASE}-dev -f ./Dockerfile .
docker pushrm marc0janssen/restic-backup-helper:develop

echo "Docker image ${NEW_RELEASE}-dev built"
