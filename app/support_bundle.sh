#!/usr/bin/env bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Support bundle helper
# Description: Create a redacted diagnostics tarball for support/triage.
# =========================================================

set -Eeuo pipefail

# shellcheck source=app/lib.sh
. /bin/lib.sh

OUTPUT_PATH=""
INCLUDE_FULL_LOGS="OFF"

usage() {
	cat <<'EOF'
Usage: /bin/support-bundle [--output PATH] [--include-full-logs]

Create a redacted diagnostics tarball with local state only:
doctor/status/config-check JSON, cron-list output, recent last-*.json files,
tool versions and redacted log tails. By default the archive is written under
/var/log/support-bundle-<timestamp>.tar.gz.

Options:
  --output PATH          Write to PATH. If PATH is a directory, a timestamped
                         support-bundle-*.tar.gz file is created inside it.
  --include-full-logs    Include full *.log files instead of redacted tails.
                         Use only when you are comfortable sharing hook output
                         and filenames that may appear in logs.
  --help, -h             Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--output)
		OUTPUT_PATH="${2:-}"
		if [ -z "${OUTPUT_PATH}" ]; then
			echo "ERROR: --output requires a path." >&2
			exit 2
		fi
		shift 2
		;;
	--include-full-logs)
		INCLUDE_FULL_LOGS="ON"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "ERROR: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

timestamp="$(date '+%Y%m%d-%H%M%S')"
bundle_name="support-bundle-${timestamp}.tar.gz"
if [ -z "${OUTPUT_PATH}" ]; then
	output="/var/log/${bundle_name}"
elif [ -d "${OUTPUT_PATH}" ]; then
	output="${OUTPUT_PATH%/}/${bundle_name}"
else
	output="${OUTPUT_PATH}"
fi

workdir="$(mktemp -d /tmp/restic-support-bundle.XXXXXX)"
cleanup() {
	rm -rf "${workdir}"
}
trap cleanup EXIT INT TERM

redact_stream() {
	sed -E \
		-e 's|(https?://)([^/@[:space:]]+@)?([^/?#[:space:]]+)[^[:space:]]*|\1\3/...|g' \
		-e 's#([A-Za-z0-9_.-]+:)[^[:space:]@;]+@#\1***@#g' \
		-e 's#(password|passwd|secret|token|authorization|client_secret)([[:space:]_:-]*).*#\1\2***#Ig'
}

run_capture() {
	local name="$1"
	shift
	local rc_file="${workdir}/${name}.exit"
	if "$@" >"${workdir}/${name}.out" 2>"${workdir}/${name}.err"; then
		printf '0\n' >"${rc_file}"
	else
		printf '%s\n' "$?" >"${rc_file}"
	fi
	redact_stream <"${workdir}/${name}.out" >"${workdir}/${name}.txt"
	if [ -s "${workdir}/${name}.err" ]; then
		{
			printf '\n--- stderr ---\n'
			redact_stream <"${workdir}/${name}.err"
		} >>"${workdir}/${name}.txt"
	fi
	rm -f "${workdir:?}/${name}.out" "${workdir:?}/${name}.err"
}

{
	printf 'Restic Backup Helper support bundle\n'
	printf 'Generated: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
	printf 'Hostname: %s\n' "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
	printf 'Release: %s\n' "${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"
	printf 'Output: %s\n' "${output}"
	printf 'Full logs: %s\n' "${INCLUDE_FULL_LOGS}"
} >"${workdir}/manifest.txt"

run_capture "status-json" /bin/status --json
run_capture "doctor-json" /bin/doctor --json
run_capture "config-check-json" /entry.sh config-check --json
run_capture "cron-list" /bin/cron-list

{
	restic version 2>&1 || true
	rclone version 2>&1 || true
	bash --version 2>&1 | head -n 1 || true
	uname -a 2>&1 || true
} | redact_stream >"${workdir}/versions.txt"

mkdir -p "${workdir}/last-json" "${workdir}/logs"
if compgen -G "/var/log/last-*.json" >/dev/null; then
	for file in /var/log/last-*.json; do
		[ -f "${file}" ] || continue
		# shellcheck disable=SC2094 # source is /var/log; destination is the private mktemp workdir.
		redact_stream <"${file}" >"${workdir}/last-json/$(basename "${file}")"
	done
fi

if [ "${INCLUDE_FULL_LOGS}" = "ON" ]; then
	for file in /var/log/*.log; do
		[ -f "${file}" ] || continue
		# shellcheck disable=SC2094 # source is /var/log; destination is the private mktemp workdir.
		redact_stream <"${file}" >"${workdir}/logs/$(basename "${file}")"
	done
else
	for file in /var/log/cron.log /var/log/*-last.log /var/log/*-error-last.log; do
		[ -f "${file}" ] || continue
		tail -n 200 "${file}" 2>/dev/null | redact_stream >"${workdir}/logs/$(basename "${file}").tail"
	done
fi

mkdir -p "$(dirname "${output}")"
tar -C "${workdir}" -czf "${output}" .
chmod 755 "${output}" 2>/dev/null || true

printf 'Support bundle written: %s\n' "${output}"
