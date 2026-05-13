#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Restore Rehearsal Worker
# Description: Disaster-recovery rehearsal: pick a snapshot, restore it (or a
#              chosen sub-path) into an isolated temp directory, prove the
#              restored bytes are actually there (file count, optional
#              checksum canary), clean up, and emit the same audit surface
#              every other helper does.
#
#              The goal is to answer the question that `restic check` can NOT
#              answer: *restic check says "repo is healthy"; restore-test
#              says "I can really get my data back"*.
#
#              By design /bin/restore-test is read-mostly: it never mutates
#              the repository and it picks an auto-generated tempdir under
#              /tmp/restore-test.XXXXXX so it cannot accidentally overwrite
#              BACKUP_ROOT_DIR or operator data. With --keep operators can
#              inspect the restored tree manually; without --keep the helper
#              removes the tempdir after verification.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/restore-test-last.log"
LAST_ERROR_LOGFILE="/var/log/restore-test-error-last.log"
LAST_MAIL_LOGFILE="/var/log/restore-test-mail-last.log"

# shellcheck source=lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO=$(mask_repository "${RESTIC_REPOSITORY}")
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

build_restic_cacert_args

usage() {
	cat <<'EOF'
Usage: /bin/restore-test [OPTIONS]

Restore-rehearsal helper: restores a snapshot (or a sub-path) into an isolated
temp directory, asserts the restored bytes are actually there and optionally
matches one or more canary file checksums, then removes the tempdir again.
Writes /var/log/last-restore-test.json and restic_restore_test.prom on the
same audit surface as /bin/backup and /bin/restore.

Snapshot selection (defaults to the latest snapshot for this host + tag):
  --id HEX           Snapshot ID to restore (default: latest).
  --tag TAG          Filter snapshots by tag (default: $RESTIC_TAG).
  --host HOST        Filter snapshots by host (default: container $HOSTNAME).

Scope:
  --path PATH        Restore only this sub-path of the snapshot (repeatable).
                     Equivalent to restic's --include; restricts the restore
                     to a known small canary tree so the rehearsal stays
                     fast on huge repos. Defaults to the full snapshot.

Target and cleanup:
  --target PATH      Restore destination (default: auto-mktemp under
                     /tmp/restore-test.XXXXXX). Explicit targets must point
                     at an empty directory (or pass --force).
  --keep             Do not remove the restored tree after verification
                     (default: clean up). Useful for manual inspection;
                     pair with --target to control where the bytes land.
  --force            Allow restoring into a non-empty explicit --target.

Verification:
  --canary PATH=SHA256   Assert that the restored copy of PATH matches the
                         given SHA-256 hex digest (lowercase). Repeatable.
                         PATH is the absolute path *as stored in the
                         snapshot*; the helper computes the on-disk path
                         as <target>/<PATH>.
  --canary-file FILE     Read canaries from FILE: one per line in the
                         standard `sha256sum` format ("<sha256>  <path>",
                         two spaces). Comments (#) and blank lines are
                         ignored. Useful when you have many canaries or
                         when PATH contains '=' / whitespace.
  --min-files N      Fail unless at least N files were restored (default 1).
                     Set to 0 to disable.
  --verify           Pass restic's --verify so per-file hashes are checked
                     against the snapshot manifest during the restore.
                     Slower; catches silent corruption at the cost of CPU.

Behaviour:
  --dry-run          Run restic restore --dry-run only; skip checksum/file
                     count verification and tempdir creation.
  --yes, -y          Non-interactive (currently the only mode; reserved for
                     future "confirm large restore" prompts so the flag is
                     already accepted).
  --help, -h         Show this help and exit.

Environment-variable equivalents:
  RESTORE_TEST_PATH        Equivalent to --path (whitespace-separated list).
  RESTORE_TEST_TARGET      Equivalent to --target (rare; usually the auto
                           tempdir is the safer choice).
  RESTORE_TEST_CANARY      Equivalent to --canary; whitespace-separated
                           "PATH=SHA256" entries (use --canary-file when
                           paths contain '=' or whitespace).
  RESTORE_TEST_CANARY_FILE Equivalent to --canary-file.
  RESTORE_TEST_KEEP        Equivalent to --keep when set to ON.
  RESTORE_TEST_MIN_FILES   Equivalent to --min-files (default: 1).
  RESTORE_TEST_VERIFY      Equivalent to --verify when set to ON.

Exit codes:
  0   Restore + verification succeeded.
  1   Restore failed, file-count floor not met, or a canary mismatched.
  2   Bad CLI / configuration error.
  3   restic restore exited 0 but matched zero files for --path.

Notifications and audit trail (mirrors /bin/restore):
  * /var/log/restore-test-last.log           - full restic stdout/stderr
  * /var/log/last-restore-test.json          - structured per-run summary
  * /var/log/restic_restore_test.prom        - Prometheus textfile (when
                                               METRICS_DIR is set)
  * /hooks/pre-restore-test.sh               - runs before the rehearsal
  * /hooks/post-restore-test.sh "$rc"        - runs after the rehearsal
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR   - same wiring as other workers
EOF
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

SNAP_ID=""
TAG_FILTER="${RESTIC_TAG:-}"
HOST_FILTER="${HOSTNAME:-}"
INCLUDE_PATHS=()
TARGET=""
TARGET_EXPLICIT="OFF"
KEEP="${RESTORE_TEST_KEEP:-OFF}"
FORCE="OFF"
DRY_RUN="OFF"
DO_VERIFY="${RESTORE_TEST_VERIFY:-OFF}"
MIN_FILES="${RESTORE_TEST_MIN_FILES:-1}"
CANARY_SPECS=()
CANARY_FILE="${RESTORE_TEST_CANARY_FILE:-}"

# Seed CLI-equivalent defaults from environment so RESTORE_TEST_* can be set
# in Compose / Kubernetes manifests without wrapping the helper. Splits on
# whitespace because paths used in canary rehearsals rarely contain spaces;
# operators with weird paths should use --canary-file instead.
if [ -n "${RESTORE_TEST_PATH:-}" ]; then
	# shellcheck disable=SC2206
	INCLUDE_PATHS=(${RESTORE_TEST_PATH})
fi
if [ -n "${RESTORE_TEST_TARGET:-}" ]; then
	TARGET="${RESTORE_TEST_TARGET}"
	TARGET_EXPLICIT="ON"
fi
if [ -n "${RESTORE_TEST_CANARY:-}" ]; then
	# shellcheck disable=SC2206
	CANARY_SPECS=(${RESTORE_TEST_CANARY})
fi

while [ $# -gt 0 ]; do
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
	--path)
		[ -n "${2:-}" ] || {
			echo "❌ --path needs a non-empty argument." >&2
			exit 2
		}
		INCLUDE_PATHS+=("$2")
		shift 2
		;;
	--target)
		[ -n "${2:-}" ] || {
			echo "❌ --target needs a non-empty argument." >&2
			exit 2
		}
		TARGET="$2"
		TARGET_EXPLICIT="ON"
		shift 2
		;;
	--keep)
		KEEP="ON"
		shift
		;;
	--force)
		FORCE="ON"
		shift
		;;
	--canary)
		[ -n "${2:-}" ] || {
			echo "❌ --canary needs a non-empty PATH=SHA256 argument." >&2
			exit 2
		}
		CANARY_SPECS+=("$2")
		shift 2
		;;
	--canary-file)
		[ -n "${2:-}" ] || {
			echo "❌ --canary-file needs a non-empty FILE argument." >&2
			exit 2
		}
		CANARY_FILE="$2"
		shift 2
		;;
	--min-files)
		[ -n "${2:-}" ] || {
			echo "❌ --min-files needs an integer argument." >&2
			exit 2
		}
		MIN_FILES="$2"
		shift 2
		;;
	--verify)
		DO_VERIFY="ON"
		shift
		;;
	--dry-run)
		DRY_RUN="ON"
		shift
		;;
	--yes | -y)
		# Reserved for future interactive guard; accepted now so cron
		# scripts pinning --yes stay forward-compatible.
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/restore-test --help for usage." >&2
		exit 2
		;;
	esac
done

# Normalise: --min-files must be a non-negative integer.
if ! [[ "${MIN_FILES}" =~ ^[0-9]+$ ]]; then
	echo "❌ --min-files must be a non-negative integer, got: ${MIN_FILES}" >&2
	exit 2
fi

# Default snapshot selector. restic accepts the literal "latest" token
# together with --tag / --host filters so we do not need to resolve it
# ourselves.
[ -n "${SNAP_ID}" ] || SNAP_ID="latest"

# ---------------------------------------------------------------------------
# Pre-flight: target directory
# ---------------------------------------------------------------------------

rm -f "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
restoreTestRC=0
TARGET_CLEANED="OFF"
TARGET_AUTOTMP="OFF"
FILES_RESTORED_COUNT=0
BYTES_RESTORED_COUNT=0
CANARY_TOTAL=0
CANARY_PASSED=0
CANARY_FAILED=0
CANARY_RESULTS_JSON="[]"

if [ "${TARGET_EXPLICIT}" = "OFF" ]; then
	# Auto tempdir under /tmp keeps the rehearsal completely isolated from
	# operator data even if RESTIC_REPOSITORY happens to be local. The path
	# is unique per run and removed on success unless --keep is set.
	if ! TARGET="$(mktemp -d /tmp/restore-test.XXXXXX 2>/dev/null)"; then
		echo "❌ Could not create temporary restore target under /tmp." >&2
		exit 1
	fi
	TARGET_AUTOTMP="ON"
fi

if [ ! -d "${TARGET}" ]; then
	if ! mkdir -p "${TARGET}" 2>/dev/null; then
		echo "❌ Restore target '${TARGET}' does not exist and could not be created." >&2
		exit 1
	fi
fi
if [ ! -w "${TARGET}" ]; then
	echo "❌ Restore target '${TARGET}' is not writable. Pick a different --target." >&2
	exit 1
fi

# Safety: refuse to use BACKUP_ROOT_DIR or the conventional source paths.
if [ -n "${BACKUP_ROOT_DIR:-}" ] && [ "${TARGET}" = "${BACKUP_ROOT_DIR}" ]; then
	echo "❌ Refusing to restore-test into BACKUP_ROOT_DIR (${BACKUP_ROOT_DIR}). Pick a different --target." >&2
	exit 2
fi
if [ "${TARGET}" = "/data" ] || [ "${TARGET}" = "/" ]; then
	echo "❌ Refusing to restore-test into '${TARGET}'. Pick a tempdir or a dedicated rehearsal path." >&2
	exit 2
fi

# For explicit targets, refuse non-empty unless --force.
if [ "${TARGET_EXPLICIT}" = "ON" ] && [ "${FORCE}" != "ON" ] && [ "${DRY_RUN}" != "ON" ]; then
	if find "${TARGET}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
		echo "❌ Explicit --target '${TARGET}' is not empty. Pass --force to allow, --dry-run to preview, or pick a different path." >&2
		exit 2
	fi
fi

# ---------------------------------------------------------------------------
# Pre-flight: build canary list (CLI specs + optional canary file)
# ---------------------------------------------------------------------------

# Each entry in CANARIES is "SHA256<TAB>PATH" so checksum lookup is a simple
# split-on-tab. We accept "PATH=SHA256" on the CLI/env (only the *last* '='
# is treated as a separator so paths with embedded '=' still parse) and the
# canonical `sha256sum -c` format ("<sha256>  <path>", two spaces) in the
# optional canary file. Comments and blank lines in the file are skipped.
CANARIES=()

for spec in "${CANARY_SPECS[@]:-}"; do
	[ -n "${spec}" ] || continue
	canary_sha="${spec##*=}"
	canary_path="${spec%=*}"
	if [ "${canary_path}" = "${spec}" ] || [ -z "${canary_path}" ] || [ -z "${canary_sha}" ]; then
		echo "❌ --canary spec is not in PATH=SHA256 form: ${spec}" >&2
		exit 2
	fi
	if [[ ! "${canary_sha}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
		echo "❌ --canary SHA256 for '${canary_path}' is not 64 hex characters." >&2
		exit 2
	fi
	# Normalise hex to lowercase for stable comparison + JSON output.
	canary_sha="${canary_sha,,}"
	CANARIES+=("${canary_sha}	${canary_path}")
done

if [ -n "${CANARY_FILE}" ]; then
	if [ ! -r "${CANARY_FILE}" ]; then
		echo "❌ --canary-file '${CANARY_FILE}' is not readable." >&2
		exit 2
	fi
	while IFS= read -r line || [ -n "${line}" ]; do
		# Trim leading whitespace, skip comments / empty lines.
		line="${line#"${line%%[![:space:]]*}"}"
		case "${line}" in
		"" | \#*) continue ;;
		esac
		canary_sha="$(printf '%s' "${line}" | awk '{print $1}')"
		canary_path="$(printf '%s' "${line}" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print}')"
		if [ -z "${canary_sha}" ] || [ -z "${canary_path}" ]; then
			echo "❌ Malformed canary line in '${CANARY_FILE}': ${line}" >&2
			exit 2
		fi
		if [[ ! "${canary_sha}" =~ ^[A-Fa-f0-9]{64}$ ]]; then
			echo "❌ Canary SHA256 for '${canary_path}' in '${CANARY_FILE}' is not 64 hex characters." >&2
			exit 2
		fi
		canary_sha="${canary_sha,,}"
		CANARIES+=("${canary_sha}	${canary_path}")
	done <"${CANARY_FILE}"
fi
CANARY_TOTAL="${#CANARIES[@]}"

# ---------------------------------------------------------------------------
# Cleanup trap (auto-tempdir removal only)
# ---------------------------------------------------------------------------

# We only sweep tempdirs we created ourselves. Operator-supplied --target
# paths are left alone so a rehearsal that surfaces a problem can be
# investigated. KEEP=ON also suppresses cleanup unconditionally.
cleanup_restore_target() {
	if [ "${KEEP}" = "ON" ]; then
		TARGET_CLEANED="kept"
		return 0
	fi
	if [ "${TARGET_AUTOTMP}" != "ON" ]; then
		TARGET_CLEANED="kept"
		return 0
	fi
	if [ ! -d "${TARGET}" ]; then
		TARGET_CLEANED="absent"
		return 0
	fi
	# Belt-and-braces: only remove paths under /tmp/restore-test.* so even
	# a broken caller cannot trick us into rm -rf on something important.
	case "${TARGET}" in
	/tmp/restore-test.??????*)
		if rm -rf "${TARGET}" 2>>"${LAST_LOGFILE}"; then
			TARGET_CLEANED="cleaned"
		else
			TARGET_CLEANED="cleanup-failed"
			errorlog "⚠️ Failed to remove auto tempdir ${TARGET} (continuing)."
		fi
		;;
	*)
		TARGET_CLEANED="kept"
		;;
	esac
}

# ---------------------------------------------------------------------------
# Run restic restore
# ---------------------------------------------------------------------------

run_hook "pre-restore-test" || true

log "🩺 Starting Restore-test at $(date +"%Y-%m-%d %a %H:%M:%S")"
logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "SNAPSHOT: ${SNAP_ID}"
logLast "TAG_FILTER: ${TAG_FILTER:-}"
logLast "HOST_FILTER: ${HOST_FILTER:-}"
logLast "INCLUDE_PATHS: ${INCLUDE_PATHS[*]:-}"
logLast "TARGET: ${TARGET}"
logLast "TARGET_AUTOTMP: ${TARGET_AUTOTMP}"
logLast "KEEP: ${KEEP}"
logLast "DRY_RUN: ${DRY_RUN}"
logLast "VERIFY: ${DO_VERIFY}"
logLast "MIN_FILES: ${MIN_FILES}"
logLast "CANARY_TOTAL: ${CANARY_TOTAL}"

restore_cmd=(restore "${SNAP_ID}" --target "${TARGET}")
[ -n "${TAG_FILTER}" ] && restore_cmd+=(--tag "${TAG_FILTER}")
[ -n "${HOST_FILTER}" ] && restore_cmd+=(--host "${HOST_FILTER}")
for inc in "${INCLUDE_PATHS[@]:-}"; do
	[ -n "${inc}" ] && restore_cmd+=(--include "${inc}")
done
[ "${DO_VERIFY}" = "ON" ] && restore_cmd+=(--verify)
[ "${DRY_RUN}" = "ON" ] && restore_cmd+=(--dry-run)

echo ""
echo "About to run: restic ${restore_cmd[*]}"
if [ "${DRY_RUN}" = "ON" ]; then
	echo "(dry-run; no files will be written, no checksum verification)"
fi

# if/else preserves the restic exit code under set -e.
if restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	restoreTestRC=0
else
	restoreTestRC=$?
fi
logLast "Finished restic restore at $(date +"%Y-%m-%d %a %H:%M:%S")"

# Parse the restic summary line ("Summary: Restored N files/dirs (S) in T")
# the same way /bin/restore does so JSON / metrics / mail subject all carry
# a consistent files_restored / bytes_restored pair.
parse_restic_restore_stats "${LAST_LOGFILE}"

# Pre-flight zero-match guard: --path matched nothing in the snapshot.
include_zero_match="OFF"
if [ "${restoreTestRC}" -eq 0 ] && [ "${#INCLUDE_PATHS[@]}" -gt 0 ] && [ "${RESTORE_STATS_FILES_RESTORED:-}" = "0" ]; then
	include_zero_match="ON"
	restoreTestRC=3
	errorlog "❌ --path matched 0 files in the snapshot. Check the snapshot-absolute path (e.g. /data/foo vs /home/foo)."
	copyErrorLog
fi

# ---------------------------------------------------------------------------
# Verification (only when restore actually ran and produced files)
# ---------------------------------------------------------------------------

VERIFICATION_STATUS="skipped"
MIN_FILES_MET="true"

if [ "${restoreTestRC}" -eq 0 ] && [ "${DRY_RUN}" = "OFF" ]; then
	VERIFICATION_STATUS="passed"

	# Recount restored files on disk so we have a number even when restic's
	# Summary line was missing (older releases, --dry-run interactions).
	if [ -d "${TARGET}" ]; then
		FILES_RESTORED_COUNT="$(find "${TARGET}" -type f 2>/dev/null | wc -l | tr -d ' ')"
		# Portable byte summation. `wc -c file1 file2 ...` emits one line
		# per file (`<bytes> <path>`) plus a trailing `<bytes> total` line
		# *only when called with two or more files*. With a single file no
		# total line is printed, so we sum the per-file count of every
		# row that is NOT the wc summary line. The regex is anchored on
		# the *whole* line so paths that happen to end in "/total"
		# survive (they have a slash before the word and do not match).
		BYTES_RESTORED_COUNT="$(find "${TARGET}" -type f -exec wc -c {} + 2>/dev/null | awk '
			/^[[:space:]]*[0-9]+[[:space:]]+total$/ { next }
			{ sum += $1 }
			END { print sum + 0 }
		')"
		[ -n "${BYTES_RESTORED_COUNT}" ] || BYTES_RESTORED_COUNT=0
	fi

	# 1) File-count floor
	if [ "${MIN_FILES}" -gt 0 ] && [ "${FILES_RESTORED_COUNT}" -lt "${MIN_FILES}" ]; then
		MIN_FILES_MET="false"
		VERIFICATION_STATUS="failed"
		errorlog "❌ File-count floor not met: restored ${FILES_RESTORED_COUNT} files, required ${MIN_FILES}."
		restoreTestRC=1
	fi

	# 2) Canary checksums (one entry per CANARIES slot, "<sha>\t<path>")
	if [ "${CANARY_TOTAL}" -gt 0 ]; then
		log "🔐 Verifying ${CANARY_TOTAL} canary checksum(s) ..."
		CANARY_DETAIL_JSON=""
		for entry in "${CANARIES[@]}"; do
			expected_sha="${entry%%	*}"
			canary_path="${entry#*	}"
			# Snapshot-absolute path → on-disk path under TARGET.
			on_disk="${TARGET}${canary_path}"
			[ "${canary_path:0:1}" = "/" ] || on_disk="${TARGET}/${canary_path}"
			c_status="passed"
			actual_sha=""
			c_msg=""
			if [ ! -f "${on_disk}" ]; then
				c_status="missing"
				c_msg="file not present in restored tree"
				CANARY_FAILED=$((CANARY_FAILED + 1))
				errorlog "❌ Canary missing: ${canary_path} (expected sha256=${expected_sha})"
			else
				actual_sha="$(sha256sum "${on_disk}" 2>/dev/null | awk '{print $1}')"
				actual_sha="${actual_sha,,}"
				if [ -z "${actual_sha}" ]; then
					c_status="hash-failed"
					c_msg="sha256sum returned no output"
					CANARY_FAILED=$((CANARY_FAILED + 1))
					errorlog "❌ Canary hashing failed for ${canary_path}."
				elif [ "${actual_sha}" = "${expected_sha}" ]; then
					c_status="passed"
					CANARY_PASSED=$((CANARY_PASSED + 1))
					log "  ✅ ${canary_path}: sha256 ok"
				else
					c_status="mismatch"
					c_msg="expected ${expected_sha}, got ${actual_sha}"
					CANARY_FAILED=$((CANARY_FAILED + 1))
					errorlog "❌ Canary mismatch for ${canary_path}: expected ${expected_sha}, got ${actual_sha}"
				fi
			fi
			# Build a JSON object for this canary; assembled into the
			# nested canary_results[] array further down.
			esc_path="$(printf '%s' "${canary_path}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
			esc_msg="$(printf '%s' "${c_msg}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
			esc_actual="$(printf '%s' "${actual_sha}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
			CANARY_DETAIL_JSON+="${CANARY_DETAIL_JSON:+,}{\"path\":\"${esc_path}\",\"expected_sha256\":\"${expected_sha}\",\"actual_sha256\":\"${esc_actual}\",\"status\":\"${c_status}\",\"message\":\"${esc_msg}\"}"
		done
		CANARY_RESULTS_JSON="[${CANARY_DETAIL_JSON}]"
		if [ "${CANARY_FAILED}" -gt 0 ]; then
			VERIFICATION_STATUS="failed"
			restoreTestRC=1
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Summary lines + cleanup
# ---------------------------------------------------------------------------

if [ "${restoreTestRC}" -eq 0 ]; then
	if [ "${DRY_RUN}" = "ON" ]; then
		log "✅ Restore-test dry-run completed (no verification performed)."
	else
		log "✅ Restore-test passed: ${FILES_RESTORED_COUNT} file(s), ${BYTES_RESTORED_COUNT} byte(s) restored; canaries ${CANARY_PASSED}/${CANARY_TOTAL} ok."
	fi
else
	log "❌ Restore-test failed with Status ${restoreTestRC} (files=${FILES_RESTORED_COUNT}, canary_failed=${CANARY_FAILED}/${CANARY_TOTAL})."
	copyErrorLog
fi

cleanup_restore_target

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished restore-test at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

# ---------------------------------------------------------------------------
# JSON summary + nested canary_results[] post-write
# ---------------------------------------------------------------------------

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"snapshot" "${SNAP_ID}"
	"target" "${TARGET}"
	"target_autotmp" "${TARGET_AUTOTMP}"
	"keep" "${KEEP}"
	"dry_run" "${DRY_RUN}"
	"verify" "${DO_VERIFY}"
	"min_files" "${MIN_FILES}"
	"min_files_met" "${MIN_FILES_MET}"
	"files_restored" "${FILES_RESTORED_COUNT}"
	"bytes_restored" "${BYTES_RESTORED_COUNT}"
	"verification" "${VERIFICATION_STATUS}"
	"canary_total" "${CANARY_TOTAL}"
	"canary_passed" "${CANARY_PASSED}"
	"canary_failed" "${CANARY_FAILED}"
	"cleanup_status" "${TARGET_CLEANED:-not-attempted}"
	"include_paths_count" "${#INCLUDE_PATHS[@]}"
)
if [ -n "${TAG_FILTER}" ]; then
	last_run_extras+=("tag_filter" "${TAG_FILTER}")
fi
if [ -n "${HOST_FILTER}" ]; then
	last_run_extras+=("host_filter" "${HOST_FILTER}")
fi
if [ -n "${RESTORE_STATS_FILES_RESTORED:-}" ]; then
	last_run_extras+=(
		"restic_files_restored" "${RESTORE_STATS_FILES_RESTORED}"
		"restic_bytes_restored" "${RESTORE_STATS_BYTES_RESTORED}"
		"restic_elapsed_human" "${RESTORE_STATS_ELAPSED_HUMAN}"
	)
fi
if [ "${include_zero_match}" = "ON" ]; then
	last_run_extras+=("include_zero_match" "true")
fi

write_last_run_json "restore-test" "${restoreTestRC}" "${start}" "${end}" "${last_run_extras[@]}"

# write_last_run_json emits flat key/value extras only. Append the nested
# canary_results[] array post-hoc so consumers do not have to re-derive it
# from the flat counts. Atomic temp-file dance matches sources_report.sh.
JSON_FILE="/var/log/last-restore-test.json"
if [ -s "${JSON_FILE}" ]; then
	tmp="${JSON_FILE}.detail.tmp"
	sed -e 's/}\s*$//' "${JSON_FILE}" >"${tmp}"
	printf ',"canary_results":%s}\n' "${CANARY_RESULTS_JSON}" >>"${tmp}"
	mv "${tmp}" "${JSON_FILE}"
fi

notify_webhook "restore-test" "${restoreTestRC}" "${start}" "${end}" "${last_run_extras[@]}" || true
write_metrics_for_job "restore_test" "${restoreTestRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

# Mail subject: prefer a one-liner that tells the operator at a glance
# whether the rehearsal proved restorability.
mail_details="${FILES_RESTORED_COUNT} files"
if [ "${CANARY_TOTAL}" -gt 0 ]; then
	mail_details="${mail_details} · canaries ${CANARY_PASSED}/${CANARY_TOTAL}"
fi
if [ "${DRY_RUN}" = "ON" ]; then
	mail_details="DRY-RUN · ${mail_details}"
fi
notify_mail "$(format_subject "Restore-test" "${restoreTestRC}" "${duration}" "${mail_details}")" "${restoreTestRC}" || true

run_hook "post-restore-test" "${restoreTestRC}" || true

exit "${restoreTestRC}"
