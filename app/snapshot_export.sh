#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Snapshot Export Script
# Description: Restore a snapshot into a temporary workdir and package it as
#              a tar.gz archive for offline transfer / support handoff.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/snapshot-export-last.log"
LAST_ERROR_LOGFILE="/var/log/snapshot-export-error-last.log"
LAST_MAIL_LOGFILE="/var/log/snapshot-export-mail-last.log"

# shellcheck source=app/lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO="$(mask_repository "${RESTIC_REPOSITORY}")"
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

build_restic_cacert_args

usage() {
	cat <<'EOF'
Usage: /bin/snapshot-export [OPTIONS]

Restore a Restic snapshot into a temporary directory and package the result as
a .tar.gz archive. This is intended for offline transfer, support handoff, or
"send me just this subtree from last night's backup" workflows.

Snapshot selection:
  --id HEX|latest      Snapshot ID to export (default: latest).
  --tag TAG            Filter snapshots by tag (default: $RESTIC_TAG).
  --host HOST          Filter snapshots by host (default: container $HOSTNAME).

Scope:
  --include PATH       Only export this path from the snapshot (repeatable).
  --exclude PATH       Exclude this path from the export (repeatable).

Output:
  --output FILE        Archive path (default:
                       /restore/snapshot-export-<snapshot>-<timestamp>.tar.gz).
  --work-dir DIR       Use this working directory instead of mktemp under TMPDIR.
                       It must be empty unless --force is passed.
  --keep-workdir       Do not remove the restored temporary tree after packaging.
  --force              Allow overwriting an existing archive and reusing a
                       non-empty --work-dir.

Behaviour:
  --dry-run            Run restic restore --dry-run only; do not create archive.
  --verify             Pass restic restore --verify before packaging.
  --verbose, -v        Stream restic restore output to stdout while exporting.
  --help               Show this help.

Audit trail:
  * /var/log/snapshot-export-last.log
  * /var/log/last-snapshot-export.json
  * /hooks/pre-snapshot-export.sh
  * /hooks/post-snapshot-export.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing as
    backup/check/prune/replicate/restore.
EOF
}

write_snapshot_export_json() {
	local target="/var/log/last-snapshot-export.json"
	local tmp="${target}.tmp"
	render_last_run_json "snapshot-export" "$@" >"${tmp}" && mv -f "${tmp}" "${target}"
}

SNAP_ID="latest"
TAG_FILTER="${RESTIC_TAG:-}"
HOST_FILTER="${HOSTNAME:-}"
INCLUDE_PATHS=()
EXCLUDE_PATHS=()
OUTPUT=""
WORK_DIR=""
KEEP_WORKDIR="OFF"
FORCE="OFF"
DRY_RUN="OFF"
DO_VERIFY="OFF"
VERBOSE="OFF"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--id)
		SNAP_ID="${2:-}"
		shift 2
		;;
	--tag)
		TAG_FILTER="${2:-}"
		shift 2
		;;
	--host)
		HOST_FILTER="${2:-}"
		shift 2
		;;
	--include)
		INCLUDE_PATHS+=("${2:-}")
		shift 2
		;;
	--exclude)
		EXCLUDE_PATHS+=("${2:-}")
		shift 2
		;;
	--output)
		OUTPUT="${2:-}"
		shift 2
		;;
	--work-dir)
		WORK_DIR="${2:-}"
		shift 2
		;;
	--keep-workdir)
		KEEP_WORKDIR="ON"
		shift
		;;
	--force)
		FORCE="ON"
		shift
		;;
	--dry-run)
		DRY_RUN="ON"
		shift
		;;
	--verify)
		DO_VERIFY="ON"
		shift
		;;
	--verbose | -v)
		VERBOSE="ON"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/snapshot-export --help for usage." >&2
		exit 2
		;;
	esac
done

if [ -z "${SNAP_ID}" ]; then
	echo "❌ --id must not be empty. Use --id latest or a snapshot ID." >&2
	exit 2
fi

timestamp="$(date +"%Y%m%d-%H%M%S")"
archive_label="$(printf '%s' "${SNAP_ID}" | sed -E 's/[^A-Za-z0-9_.-]+/-/g')"
if [ -z "${OUTPUT}" ]; then
	OUTPUT="/restore/snapshot-export-${archive_label}-${timestamp}.tar.gz"
fi

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
	if [ "${KEEP_WORKDIR}" = "ON" ]; then
		return 0
	fi
	if [ "${WORK_DIR_CREATED_AUTO:-OFF}" = "ON" ] && [ -n "${AUTO_WORK_DIR:-}" ] && [ -d "${AUTO_WORK_DIR}" ]; then
		rm -rf "${AUTO_WORK_DIR}"
	elif [ -n "${RESTORE_DIR:-}" ] && [ -d "${RESTORE_DIR}" ]; then
		rm -rf "${RESTORE_DIR}"
	fi
}
trap cleanup EXIT

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
snapshotExportRC=0
archive_size_bytes=""
RESTORE_STATS_FILES_RESTORED=""
RESTORE_STATS_BYTES_RESTORED=""
RESTORE_STATS_ELAPSED_HUMAN=""

log "📦 Starting snapshot export at $(date +"%Y-%m-%d %a %H:%M:%S")"
logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "SNAPSHOT: ${SNAP_ID}"
logLast "TAG_FILTER: ${TAG_FILTER:-}"
logLast "HOST_FILTER: ${HOST_FILTER:-}"
logLast "INCLUDE_PATHS: ${INCLUDE_PATHS[*]:-}"
logLast "EXCLUDE_PATHS: ${EXCLUDE_PATHS[*]:-}"
logLast "OUTPUT: ${OUTPUT}"
logLast "WORK_DIR: ${WORK_DIR:-<auto>}"
logLast "DRY_RUN: ${DRY_RUN}"
logLast "VERIFY: ${DO_VERIFY}"
logLast "VERBOSE: ${VERBOSE}"

run_hook "pre-snapshot-export" || true

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	errorlog "❌ RESTIC_REPOSITORY is empty."
	snapshotExportRC=2
fi

if [ "${snapshotExportRC}" -eq 0 ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
	errorlog "❌ Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD."
	snapshotExportRC=2
fi

if [ "${snapshotExportRC}" -eq 0 ]; then
	if [ -n "${WORK_DIR}" ]; then
		AUTO_WORK_DIR="${WORK_DIR}"
		WORK_DIR_CREATED_AUTO="OFF"
		if [ ! -d "${AUTO_WORK_DIR}" ]; then
			if ! mkdir -p "${AUTO_WORK_DIR}" 2>/dev/null; then
				errorlog "❌ Work directory '${AUTO_WORK_DIR}' does not exist and could not be created."
				snapshotExportRC=1
			fi
		fi
		if [ "${snapshotExportRC}" -eq 0 ] && [ "${FORCE}" != "ON" ]; then
			entries="$(find "${AUTO_WORK_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
			if [ -n "${entries}" ]; then
				errorlog "❌ Work directory '${AUTO_WORK_DIR}' is not empty. Pass --force or choose a different --work-dir."
				snapshotExportRC=1
			fi
		fi
	else
		work_base="${TMPDIR:-/tmp}"
		if ! mkdir -p "${work_base}" 2>/dev/null; then
			errorlog "❌ Temporary base '${work_base}' does not exist and could not be created."
			snapshotExportRC=1
		else
			if AUTO_WORK_DIR="$(mktemp -d "${work_base%/}/snapshot-export.XXXXXX")"; then
				WORK_DIR_CREATED_AUTO="ON"
			else
				errorlog "❌ Could not create temporary work directory under '${work_base}'."
				snapshotExportRC=1
			fi
		fi
	fi
fi

if [ "${snapshotExportRC}" -eq 0 ] && [ "${DRY_RUN}" != "ON" ]; then
	output_dir="$(dirname "${OUTPUT}")"
	if [ ! -d "${output_dir}" ]; then
		if ! mkdir -p "${output_dir}" 2>/dev/null; then
			errorlog "❌ Output directory '${output_dir}' does not exist and could not be created."
			snapshotExportRC=1
		fi
	fi
	if [ "${snapshotExportRC}" -eq 0 ] && [ ! -w "${output_dir}" ]; then
		errorlog "❌ Output directory '${output_dir}' is not writable."
		snapshotExportRC=1
	fi
	if [ "${snapshotExportRC}" -eq 0 ] && [ -e "${OUTPUT}" ] && [ "${FORCE}" != "ON" ]; then
		errorlog "❌ Output archive '${OUTPUT}' already exists. Pass --force to overwrite."
		snapshotExportRC=1
	fi
fi

RESTORE_DIR=""
if [ -n "${AUTO_WORK_DIR:-}" ]; then
	RESTORE_DIR="${AUTO_WORK_DIR}/restore"
fi
if [ "${snapshotExportRC}" -eq 0 ]; then
	mkdir -p "${RESTORE_DIR}"

	restore_cmd=(restore "${SNAP_ID}" --target "${RESTORE_DIR}")
	if [ -n "${TAG_FILTER}" ]; then
		restore_cmd+=(--tag "${TAG_FILTER}")
	fi
	if [ -n "${HOST_FILTER}" ]; then
		restore_cmd+=(--host "${HOST_FILTER}")
	fi
	for include in "${INCLUDE_PATHS[@]}"; do
		restore_cmd+=(--include "${include}")
	done
	for exclude in "${EXCLUDE_PATHS[@]}"; do
		restore_cmd+=(--exclude "${exclude}")
	done
	if [ "${DRY_RUN}" = "ON" ]; then
		restore_cmd+=(--dry-run)
	fi
	if [ "${DO_VERIFY}" = "ON" ]; then
		restore_cmd+=(--verify)
	fi
	if [ "${VERBOSE}" = "ON" ]; then
		restore_cmd+=(--verbose=2)
	fi

	printf -v restore_preview '%q ' restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}"
	log "About to run: ${restore_preview}"

	if [ "${VERBOSE}" = "ON" ]; then
		if restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}" 2>&1 | tee -a "${LAST_LOGFILE}"; then
			snapshotExportRC=0
		else
			snapshotExportRC=$?
		fi
	else
		if restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
			snapshotExportRC=0
		else
			snapshotExportRC=$?
		fi
	fi
fi

parse_restic_restore_stats "${LAST_LOGFILE}"

include_zero_match="false"
if [ "${snapshotExportRC}" -eq 0 ] && [ "${DRY_RUN}" != "ON" ] && [ "${#INCLUDE_PATHS[@]}" -gt 0 ] && [ "${RESTORE_STATS_FILES_RESTORED:-}" = "0" ]; then
	include_zero_match="true"
	snapshotExportRC=3
	errorlog "❌ Include filter matched 0 files/dirs. Check snapshot path prefixes (for example /host/... vs /home/...)."
fi

if [ "${snapshotExportRC}" -eq 0 ] && [ "${DRY_RUN}" != "ON" ]; then
	log "🗜️ Creating archive ${OUTPUT}..."
	rm -f "${OUTPUT}.tmp"
	if tar -C "${RESTORE_DIR}" -czf "${OUTPUT}.tmp" . >>"${LAST_LOGFILE}" 2>&1 && mv -f "${OUTPUT}.tmp" "${OUTPUT}"; then
		archive_size_bytes="$(wc -c <"${OUTPUT}" | tr -d '[:space:]')"
		log "✅ Snapshot archive created: ${OUTPUT} (${archive_size_bytes} bytes)"
	else
		snapshotExportRC=$?
		rm -f "${OUTPUT}.tmp"
		errorlog "❌ Snapshot archive creation failed with status ${snapshotExportRC}."
	fi
elif [ "${snapshotExportRC}" -eq 0 ]; then
	log "✅ Dry-run completed; no archive created."
fi

if [ "${snapshotExportRC}" -ne 0 ]; then
	copyErrorLog
fi

end="$(date +%s)"
duration=$((end - start))
log "🏁 Finished snapshot export at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}") (exit ${snapshotExportRC})"

json_args=(
	"snapshot" "${SNAP_ID}"
	"repository" "${MASKED_REPO}"
	"archive" "${OUTPUT}"
	"work_dir" "${AUTO_WORK_DIR:-}"
	"dry_run" "${DRY_RUN}"
	"include_zero_match" "${include_zero_match}"
)
if [ -n "${RESTORE_STATS_FILES_RESTORED:-}" ]; then
	json_args+=("files_restored" "${RESTORE_STATS_FILES_RESTORED}")
fi
if [ -n "${RESTORE_STATS_BYTES_RESTORED:-}" ]; then
	json_args+=("bytes_restored" "${RESTORE_STATS_BYTES_RESTORED}")
fi
if [ -n "${RESTORE_STATS_ELAPSED_HUMAN:-}" ]; then
	json_args+=("elapsed_human" "${RESTORE_STATS_ELAPSED_HUMAN}")
fi
if [ -n "${archive_size_bytes}" ]; then
	json_args+=("archive_size_bytes" "${archive_size_bytes}")
fi

write_snapshot_export_json "${snapshotExportRC}" "${start}" "${end}" "${json_args[@]}"
notify_webhook "snapshot-export" "${snapshotExportRC}" "${start}" "${end}" "${json_args[@]}" || true
write_metrics_for_job "snapshot_export" "${snapshotExportRC}" "${start}" "${end}" "${json_args[@]}" || true

subject_details="${SNAP_ID} -> ${OUTPUT}"
if [ -n "${archive_size_bytes}" ]; then
	subject_details+=" (${archive_size_bytes} bytes)"
fi
if [ "${include_zero_match}" = "true" ]; then
	subject_details="include matched 0 · ${subject_details}"
fi
notify_mail "$(format_subject "Snapshot export" "${snapshotExportRC}" "${duration}" "${subject_details}")" "${snapshotExportRC}" || true

run_hook "post-snapshot-export" "${snapshotExportRC}" || true

exit "${snapshotExportRC}"
