#!/bin/bash

# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# =========================================================

VERSION_RESTIC="0.18.1"
VERSION_FILE=".version"
RELEASE_FILE=".release"

# Read version number from file
VERSION=$(cat ${VERSION_FILE})

# Split version in major, minor, patch and rest
IFS='.' read -r MAJOR MINOR BUILD <<< "${VERSION}"

# Rise buildnumber
BUILD=$((BUILD + 1))

# New version nummer
NEW_VERSION="${MAJOR}.${MINOR}.${BUILD}"

# New release nummer
NEW_RELEASE="${MAJOR}.${MINOR}.${BUILD}-${VERSION_RESTIC}-dev"

# Write new versionnumber to file
echo "$NEW_VERSION" > $VERSION_FILE

# Write new releasenumber to file
echo "$NEW_RELEASE" > $RELEASE_FILE

# Change new releasenumber in files
# Only change the lines with "-dev"
sed -i.bak "s/restic-backup-helper:[0-9.]*-[0-9.]*-dev/restic-backup-helper:${NEW_RELEASE}/" ./README.md
# Set restic version in Dockerfile
sed -i.bak "s#restic/restic:.*#restic/restic:${VERSION_RESTIC}#" ./Dockerfile

rm -f ./README.md.bak ./Dockerfile.bak

docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${NEW_RELEASE} -t marc0janssen/restic-backup-helper:develop -f ./Dockerfile .
# docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${NEW_RELEASE} -f ./Dockerfile .
docker pushrm marc0janssen/restic-backup-helper:develop

echo ""
echo "Docker image ${NEW_RELEASE} built"
