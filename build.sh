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

# Set production state
echo "prd" > .state

# Change new releasenumber in files
# Only change the lines with "release:"
sed -i '' "s/release:.*/release: ${NEW_RELEASE}/" ./README.md
# Only change the lines without "-dev"
sed -i '' '/restic-backup-helper:[0-9.]*-[0-9.]*$/s/restic-backup-helper:[0-9.]*-[0-9.]*/restic-backup-helper:'"${NEW_RELEASE}"'/' ./README.md

docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:latest -f ./Dockerfile .
docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${NEW_RELEASE} -f ./Dockerfile .

# Update documentation of Docker
docker pushrm marc0janssen/restic-backup-helper:latest

echo "Docker image ${NEW_RELEASE} built"
