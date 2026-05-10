#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Lock-aware cron wrapper: acquire <lock-file> with flock -n before invoking
# <command...>. On lock contention (the previous run is still active), it
# logs a clear "skipped: previous run still active" line and exits 0 instead
# of leaving cron with an opaque non-zero flock exit code that disappears
# into /var/log/cron.log.
#
# Usage (in crontab lines composed by /entry.sh):
#   <cron> /bin/locked_run <job-name> <lock-file> <command> [arg ...] >> /var/log/cron.log 2>&1
#
# The wrapper opens the lockfile on FD 9 and uses `flock -n 9` so it works
# with both util-linux and busybox flock implementations (no -E required).
# After acquiring the lock, `exec "$@"` replaces the wrapper with the
# worker; FD 9 stays open in the new process so the kernel releases the
# lock automatically when the worker exits.
# =========================================================

set -Eeuo pipefail

if [ "$#" -lt 3 ]; then
	echo "Usage: $0 <job-name> <lock-file> <command> [arg ...]" >&2
	exit 2
fi

job="$1"
lock="$2"
shift 2

# Locate flock dynamically (Alpine ships util-linux flock at /usr/bin/flock,
# busybox provides /bin/flock). Fail loudly if it is missing instead of
# silently treating the absence as lock contention.
FLOCK_BIN="$(command -v flock 2>/dev/null || true)"
if [ -z "${FLOCK_BIN}" ] || [ ! -x "${FLOCK_BIN}" ]; then
	printf '[%s] ❌ %s aborted: flock binary not found in PATH (need util-linux or busybox flock)\n' \
		"$(date '+%Y-%m-%d %a %H:%M:%S')" "${job}" >&2
	exit 1
fi

# Ensure the lock directory exists; failure here is fatal (the cron line
# cannot meaningfully recover from a missing /var/run).
mkdir -p "$(dirname "${lock}")"

# Open the lockfile on FD 9 (creates if missing). Then try a non-blocking
# exclusive lock on that FD.
exec 9>"${lock}"
if ! "${FLOCK_BIN}" -n 9; then
	printf '[%s] ⏭ %s skipped: previous run still active (lock %s)\n' \
		"$(date '+%Y-%m-%d %a %H:%M:%S')" "${job}" "${lock}"
	exit 0
fi

# Hold the lock for the duration of the wrapped command; exec keeps FD 9
# open in the replacement process so the kernel releases the lock when
# that process exits (or is killed).
exec "$@"
