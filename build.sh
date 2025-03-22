#!/bin/sh

# Name: docker-nzbgetvpn
# Coder: Marco Janssen (twitter @marc0janssen)
# date: 2021-11-28 14:24:26
# update: 2021-11-28 14:24:32

VERSION="1.5.6-0.17.3"

docker image rm marc0janssen/restic-backup-helper:latest
docker image rm marc0janssen/restic-backup-helper:${VERSION}

docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:latest -f ./Dockerfile .
docker buildx build --no-cache --platform linux/amd64,linux/arm64 --push -t marc0janssen/restic-backup-helper:${VERSION} -f ./Dockerfile .

docker pushrm marc0janssen/restic-backup-helper:latest