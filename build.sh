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
NEW_RELEASE="${MAJOR}.${MINOR}.${BUILD}-${VERSION_RESTIC}"

# Write new versionnumber to file
echo "$NEW_VERSION" > $VERSION_FILE

# Write new releasenumber to file
echo "$NEW_RELEASE" > $RELEASE_FILE

# Change new releasenumber in files
# Only change the lines with "release:"
sed -i '' "s/release:.*/release: ${NEW_RELEASE}/" ./README.md
# Only change the lines without "-dev"
sed -i '' '/restic-backup-helper:[0-9.]*-[0-9.]*$/s/restic-backup-helper:[0-9.]*-[0-9.]*/restic-backup-helper:'"${NEW_RELEASE}"'/' ./README.md
# Set restic version in Dockerfile
sed -i '' "s/restic\/restic:.*/restic\/restic:${VERSION_RESTIC}/" ./Dockerfile

docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:latest -f ./Dockerfile .
docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${NEW_RELEASE} -f ./Dockerfile .

# Update documentation of Docker
docker pushrm marc0janssen/restic-backup-helper:latest

echo ""
echo "Docker image ${NEW_RELEASE} built"
