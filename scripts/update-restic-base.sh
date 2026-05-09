#!/bin/sh
set -eu

log_usage() {
	echo "Usage: $0 <Dockerfile> <restic-tag>" >&2
	echo "  Example: $0 ./Dockerfile 0.18.2" >&2
}

if [ "$#" -ne 2 ]; then
	log_usage
	exit 1
fi

dockerfile="$1"
tag="$2"

if [ ! -f "${dockerfile}" ]; then
	echo "Not a file: ${dockerfile}" >&2
	exit 1
fi

sed -i.bak "s#^FROM restic/restic:.*#FROM restic/restic:${tag}#" "${dockerfile}"
rm -f "${dockerfile}.bak"
