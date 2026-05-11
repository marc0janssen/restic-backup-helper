#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Restic Restore Worker
# Description: Operator-friendly wrapper around `restic restore`. Supports
#              both non-interactive flag-driven invocations (cron-jobs,
#              scripts, CI) and an interactive TTY mode that lists matching
#              snapshots and prompts for target/dry-run. Follows the same
#              patterns as /bin/backup, /bin/check, /bin/prune and /bin/bisync
#              (hooks, RESTIC_CACERT wiring, last-restore.json, mail/webhook,
#              Prometheus textfile metrics).
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/restore-last.log"
LAST_ERROR_LOGFILE="/var/log/restore-error-last.log"
LAST_MAIL_LOGFILE="/var/log/restore-mail-last.log"

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
Usage: /bin/restore [OPTIONS]

Restore a snapshot from the Restic repository into a target directory.
Defaults are designed for the common case "give me last night's data back".

Snapshot selection (defaults to the latest snapshot for this host + tag):
  --id HEX            Restore the snapshot with this short or long ID.
  --tag TAG           Filter snapshots by tag (default: $RESTIC_TAG).
  --host HOST         Filter snapshots by host (default: container $HOSTNAME).
  --since DATE        Pick the oldest snapshot newer than DATE (YYYY-MM-DD or
                      ISO 8601, e.g. 2026-05-01 or 2026-05-01T18:00:00).

Target and scope:
  --target PATH       Restore destination (default: /restore). Must be
                      writable and either empty or used with --force.
  --include PATH      Only restore this path (repeatable). Paths are within
                      the snapshot tree, e.g. /data/documenten.
  --exclude PATH      Skip this path (repeatable).
  --owner UID:GID     chown -R the target after a successful restore.

Behaviour:
  --dry-run           Show what would be restored without writing anything
                      (passes restic's own --dry-run).
  --verify            Pass restic's --verify so hashes are verified during
                      restore. Slower but catches silent corruption.
  --force             Allow restoring into a non-empty target.
  --list              List matching snapshots (most recent 20) and exit.
  --all               When combined with --list, show all matching snapshots.
  --help              Show this help and exit.

Interactive mode:
  Invoked without any of the flags above on a TTY (`docker exec -ti ...`),
  /bin/restore lists the most recent 10 matching snapshots, asks which one
  to restore, asks for the target, offers a dry-run preview and finally a
  confirmation before mutating the target.

Notifications and audit trail (mirrors /bin/backup):
  * /var/log/restore-last.log         — full restic stdout/stderr
  * /var/log/last-restore.json        — structured per-run summary
  * /hooks/pre-restore.sh             — runs before restore (informational)
  * /hooks/post-restore.sh "$rc"      — runs after restore with exit code
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR — same wiring as the other workers
EOF
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------

SNAP_ID=""
TARGET="/restore"
TAG_FILTER="${RESTIC_TAG:-}"
HOST_FILTER="${HOSTNAME:-}"
SINCE_FILTER=""
INCLUDE_PATHS=()
EXCLUDE_PATHS=()
CHOWN_SPEC=""
DRY_RUN="OFF"
DO_VERIFY="OFF"
FORCE="OFF"
LIST_ONLY="OFF"
LIST_ALL="OFF"
HAD_FLAGS="OFF"

while [ $# -gt 0 ]; do
	case "$1" in
	--id)
		SNAP_ID="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--target)
		TARGET="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--tag)
		TAG_FILTER="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--host)
		HOST_FILTER="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--since)
		SINCE_FILTER="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--include)
		INCLUDE_PATHS+=("${2:-}")
		shift 2
		HAD_FLAGS="ON"
		;;
	--exclude)
		EXCLUDE_PATHS+=("${2:-}")
		shift 2
		HAD_FLAGS="ON"
		;;
	--owner)
		CHOWN_SPEC="${2:-}"
		shift 2
		HAD_FLAGS="ON"
		;;
	--dry-run)
		DRY_RUN="ON"
		shift
		HAD_FLAGS="ON"
		;;
	--verify)
		DO_VERIFY="ON"
		shift
		HAD_FLAGS="ON"
		;;
	--force)
		FORCE="ON"
		shift
		HAD_FLAGS="ON"
		;;
	--list)
		LIST_ONLY="ON"
		shift
		HAD_FLAGS="ON"
		;;
	--all)
		LIST_ALL="ON"
		shift
		HAD_FLAGS="ON"
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/restore --help for usage." >&2
		exit 2
		;;
	esac
done

# ---------------------------------------------------------------------------
# Snapshot discovery (restic snapshots --json filtered by tag + host)
# ---------------------------------------------------------------------------

# Print a tab-separated table of matching snapshots:
#   index<TAB>id<TAB>time<TAB>tags<TAB>paths
# Index is 1-based; rows are ordered oldest-first by `restic snapshots`.
# `restic snapshots --latest 1 --json` would only give us the very last one,
# so we list all and post-filter to avoid an extra round-trip.
list_snapshots_table() {
	local args=(snapshots --json)
	if [ -n "${TAG_FILTER}" ]; then
		args+=(--tag "${TAG_FILTER}")
	fi
	if [ -n "${HOST_FILTER}" ]; then
		args+=(--host "${HOST_FILTER}")
	fi
	# Awk-based JSON walker; dependency-free (no jq in the image). The format
	# is the standard restic snapshots --json array. We accept "id" as either
	# the short or long form (restic always emits both in newer versions; the
	# short form sits in "short_id"). Each record is rendered on one line.
	#
	# Edge: restic 0.18 always closes each record on its own line; older
	# versions may pack them. The script is robust to both because awk
	# tracks brace depth.
	if ! restic "${RESTIC_CACERT_ARGS[@]}" "${args[@]}" 2>/dev/null | awk '
		BEGIN { depth = 0; cur = ""; }
		{
			for (i = 1; i <= length($0); i++) {
				c = substr($0, i, 1)
				if (c == "{") { depth++; if (depth == 1) cur = "" }
				if (depth >= 1) cur = cur c
				if (c == "}") {
					depth--
					if (depth == 0) {
						print cur
						cur = ""
					}
				}
			}
		}
	' | nl -ba -w1 -s$'\t' >/tmp/restore-snapshots.$$.tsv; then
		rm -f "/tmp/restore-snapshots.$$.tsv"
		return 1
	fi

	# Parse per-record JSON into fields. Each line: <idx><TAB><json_record>.
	# We pull `short_id`, `time`, `tags`, `paths` from the record. When a
	# field is missing we leave it empty.
	awk -F'\t' -v since="${SINCE_FILTER}" '
		function jget(blob, key,   m, s) {
			# Match "key":"value" or "key":number; returns the string between
			# the first balanced quote pair following the key. Sufficient for
			# the simple fields we need.
			s = "\"" key "\""
			n = index(blob, s)
			if (n == 0) return ""
			# Skip the key + the colon + the opening quote.
			rest = substr(blob, n + length(s))
			sub(/^[[:space:]]*:[[:space:]]*"/, "", rest)
			if (rest == "") return ""
			m = index(rest, "\"")
			if (m == 0) return ""
			return substr(rest, 1, m - 1)
		}
		function jget_array(blob, key,    n, s, rest, m) {
			# Returns the contents of a string array as a comma-separated
			# list. Used for "tags" and "paths".
			s = "\"" key "\""
			n = index(blob, s)
			if (n == 0) return ""
			rest = substr(blob, n + length(s))
			sub(/^[[:space:]]*:[[:space:]]*\[/, "", rest)
			m = index(rest, "]")
			if (m == 0) return ""
			content = substr(rest, 1, m - 1)
			gsub(/"[[:space:]]*,[[:space:]]*"/, "|", content)
			gsub(/(^"|"$)/, "", content)
			gsub(/\|/, ",", content)
			return content
		}
		{
			idx = $1
			rec = $2
			short_id = jget(rec, "short_id")
			if (short_id == "") short_id = substr(jget(rec, "id"), 1, 8)
			time = jget(rec, "time")
			hostname = jget(rec, "hostname")
			tags = jget_array(rec, "tags")
			paths = jget_array(rec, "paths")
			# Trim "time" to seconds (drop fractional/timezone for display).
			short_time = substr(time, 1, 19)
			# Filter by --since if provided. ISO 8601 strings compare
			# lexicographically when both are YYYY-MM-DDTHH:MM:SS-formatted.
			if (since != "" && short_time < since) next
			printf "%s\t%s\t%s\t%s\t%s\t%s\n", idx, short_id, short_time, hostname, tags, paths
		}
	' "/tmp/restore-snapshots.$$.tsv"

	rm -f "/tmp/restore-snapshots.$$.tsv"
}

# Render a human-friendly table from list_snapshots_table for stdout.
print_snapshot_table() {
	local limit="${1:-20}"
	local count=0
	printf '  #   SNAPSHOT  TIME                 HOST          TAGS           PATHS\n'
	printf '  --- --------  -------------------  ------------  -------------  ----------------------------------\n'
	while IFS=$'\t' read -r idx sid stime host tags paths; do
		printf '  %-3s %-8s  %-19s  %-12s  %-13s  %s\n' "${idx}" "${sid}" "${stime}" "${host}" "${tags}" "${paths}"
		count=$((count + 1))
		if [ "${LIST_ALL}" != "ON" ] && [ "${count}" -ge "${limit}" ]; then
			break
		fi
	done
	if [ "${count}" -eq 0 ]; then
		echo "  (no snapshots matched: tag='${TAG_FILTER:-*}' host='${HOST_FILTER:-*}' since='${SINCE_FILTER:-*}')"
	fi
}

# ---------------------------------------------------------------------------
# --list short-circuit (informational, no mail/webhook)
# ---------------------------------------------------------------------------

if [ "${LIST_ONLY}" = "ON" ]; then
	echo "📋 Matching snapshots in ${MASKED_REPO}:"
	list_snapshots_table | print_snapshot_table 1000
	exit 0
fi

# ---------------------------------------------------------------------------
# Resolve which snapshot to restore
# ---------------------------------------------------------------------------

# When --id was passed we use it directly. Otherwise we pick from the table:
#   * interactive mode: prompt for index or `latest`
#   * non-interactive: pick the most recent matching snapshot ("latest")
TABLE=""
if [ -z "${SNAP_ID}" ] || { [ "${HAD_FLAGS}" = "OFF" ] && [ -t 0 ] && [ -t 1 ]; }; then
	TABLE="$(list_snapshots_table)"
fi

SNAPSHOT_COUNT=0
if [ -n "${TABLE}" ]; then
	SNAPSHOT_COUNT="$(printf '%s\n' "${TABLE}" | grep -c .)"
fi

INTERACTIVE="OFF"
if [ "${HAD_FLAGS}" = "OFF" ] && [ -t 0 ] && [ -t 1 ]; then
	INTERACTIVE="ON"
fi

if [ "${INTERACTIVE}" = "ON" ]; then
	echo "📋 Matching snapshots in ${MASKED_REPO} (tag='${TAG_FILTER:-*}' host='${HOST_FILTER:-*}'):"
	printf '%s\n' "${TABLE}" | print_snapshot_table 10
	if [ "${SNAPSHOT_COUNT}" -eq 0 ]; then
		echo "❌ Nothing to restore. Run /bin/restore --list to widen the filter, or pass --tag/--host." >&2
		exit 1
	fi
	echo ""
	read -r -p "Snapshot to restore [index 1-${SNAPSHOT_COUNT} or short-id, default=latest]: " choice
	choice="${choice:-latest}"

	if [[ "${choice}" =~ ^[0-9]+$ ]]; then
		SNAP_ID="$(printf '%s\n' "${TABLE}" | awk -F'\t' -v idx="${choice}" '$1 == idx { print $2; exit }')"
		if [ -z "${SNAP_ID}" ]; then
			echo "❌ No snapshot at index ${choice}." >&2
			exit 2
		fi
	elif [[ "${choice}" == "latest" ]]; then
		SNAP_ID="latest"
	else
		SNAP_ID="${choice}"
	fi

	read -r -p "Restore target [${TARGET}]: " new_target
	if [ -n "${new_target}" ]; then
		TARGET="${new_target}"
	fi

	read -r -p "Dry-run first? [Y/n]: " dr
	dr="${dr:-Y}"
	if [[ "${dr^^}" == "Y" || "${dr^^}" == "YES" ]]; then
		DRY_RUN="ON"
	fi
elif [ -z "${SNAP_ID}" ]; then
	# Non-interactive default: latest. restic accepts the literal "latest"
	# token together with --tag / --host filters so we do not need to resolve
	# it ourselves; pass it through verbatim.
	SNAP_ID="latest"
fi

# ---------------------------------------------------------------------------
# Pre-flight safety checks (target writable / non-empty / not source path)
# ---------------------------------------------------------------------------

if [ -z "${TARGET}" ]; then
	echo "❌ --target must not be empty." >&2
	exit 2
fi
if [ ! -d "${TARGET}" ]; then
	if ! mkdir -p "${TARGET}" 2>/dev/null; then
		echo "❌ Restore target '${TARGET}' does not exist and could not be created." >&2
		exit 1
	fi
fi
if [ ! -w "${TARGET}" ]; then
	echo "❌ Restore target '${TARGET}' is not writable. Re-mount without :ro or pick a different --target." >&2
	exit 1
fi

# Refuse to restore on top of the backup source path unless --force is given.
# Defaults to /data, the conventional source mount; honoured both for the env
# variable form and the bare path.
if [ -n "${BACKUP_ROOT_DIR:-}" ] && [ "${TARGET}" = "${BACKUP_ROOT_DIR}" ] && [ "${FORCE}" != "ON" ]; then
	echo "❌ Refusing to restore into BACKUP_ROOT_DIR (${BACKUP_ROOT_DIR}). Pick a different --target (e.g. /restore) or pass --force if this really is what you want." >&2
	exit 1
fi
if [ "${TARGET}" = "/data" ] && [ "${FORCE}" != "ON" ]; then
	echo "❌ Refusing to restore directly into /data (the conventional backup source). Pick a different --target (e.g. /restore) or pass --force." >&2
	exit 1
fi

# Refuse to restore into a non-empty target unless --force / --dry-run is set.
# Counting visible entries via find for portability (busybox-friendly).
if [ "${FORCE}" != "ON" ] && [ "${DRY_RUN}" != "ON" ]; then
	entries="$(find "${TARGET}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
	if [ -n "${entries}" ]; then
		echo "❌ Restore target '${TARGET}' is not empty. Pass --force to allow overwriting, --dry-run to preview, or pick a different --target." >&2
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Build the restic restore invocation
# ---------------------------------------------------------------------------

restore_cmd=(restore "${SNAP_ID}" --target "${TARGET}")
if [ -n "${TAG_FILTER}" ]; then
	restore_cmd+=(--tag "${TAG_FILTER}")
fi
if [ -n "${HOST_FILTER}" ]; then
	restore_cmd+=(--host "${HOST_FILTER}")
fi
for inc in "${INCLUDE_PATHS[@]:-}"; do
	[ -n "${inc}" ] && restore_cmd+=(--include "${inc}")
done
for exc in "${EXCLUDE_PATHS[@]:-}"; do
	[ -n "${exc}" ] && restore_cmd+=(--exclude "${exc}")
done
if [ "${DO_VERIFY}" = "ON" ]; then
	restore_cmd+=(--verify)
fi
if [ "${DRY_RUN}" = "ON" ]; then
	restore_cmd+=(--dry-run)
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

run_hook "pre-restore" || true

start=$(date +%s)
log "♻️ Starting Restore at $(date +"%Y-%m-%d %a %H:%M:%S")"

logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"
logLast "SNAPSHOT: ${SNAP_ID}"
logLast "TARGET: ${TARGET}"
logLast "TAG_FILTER: ${TAG_FILTER:-}"
logLast "HOST_FILTER: ${HOST_FILTER:-}"
logLast "INCLUDE_PATHS: ${INCLUDE_PATHS[*]:-}"
logLast "EXCLUDE_PATHS: ${EXCLUDE_PATHS[*]:-}"
logLast "DRY_RUN: ${DRY_RUN}"
logLast "VERIFY: ${DO_VERIFY}"
logLast "FORCE: ${FORCE}"
logLast "CHOWN_SPEC: ${CHOWN_SPEC:-}"

if [ "${INTERACTIVE}" = "ON" ]; then
	echo ""
	echo "About to run: restic ${restore_cmd[*]}"
	if [ "${DRY_RUN}" = "ON" ]; then
		echo "(dry-run; no files will be written)"
	fi
	read -r -p "Proceed? [y/N]: " confirm
	if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
		log "🛑 Restore cancelled by operator."
		end=$(date +%s)
		write_last_run_json "restore" 130 "${start}" "${end}" \
			"repository" "${MASKED_REPO}" \
			"snapshot" "${SNAP_ID}" \
			"target" "${TARGET}" \
			"cancelled" "true"
		exit 130
	fi
fi

# if/else captures restic's exit code without aborting under `set -e`.
if restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
	restoreRC=0
else
	restoreRC=$?
fi
logLast "Finished restore at $(date +"%Y-%m-%d %a %H:%M:%S")"

if [ "${restoreRC}" -eq 0 ]; then
	log "✅ Restore Successful"
	# Apply optional ownership change on the target. Skipped for dry-run.
	if [ -n "${CHOWN_SPEC}" ] && [ "${DRY_RUN}" != "ON" ]; then
		log "👤 Applying ownership ${CHOWN_SPEC} on ${TARGET}..."
		if chown -R "${CHOWN_SPEC}" "${TARGET}" >>"${LAST_LOGFILE}" 2>&1; then
			log "✅ chown ${CHOWN_SPEC} ${TARGET} completed"
		else
			rc=$?
			errorlog "⚠️ chown -R ${CHOWN_SPEC} ${TARGET} failed (exit ${rc}); restore itself was successful."
		fi
	fi
else
	log "❌ Restore Failed with Status ${restoreRC}"
	copyErrorLog
fi

end=$(date +%s)
duration=$((end - start))
minutes=$((duration / 60))
seconds=$((duration % 60))
log "🏁 Finished restore at $(date +"%Y-%m-%d %a %H:%M:%S") after ${minutes}m ${seconds}s"

parse_restic_restore_stats "${LAST_LOGFILE}"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"snapshot" "${SNAP_ID}"
	"target" "${TARGET}"
	"dry_run" "${DRY_RUN}"
)
if [ -n "${TAG_FILTER}" ]; then
	last_run_extras+=("tag_filter" "${TAG_FILTER}")
fi
if [ -n "${HOST_FILTER}" ]; then
	last_run_extras+=("host_filter" "${HOST_FILTER}")
fi
if [ -n "${RESTORE_STATS_FILES_RESTORED}" ]; then
	last_run_extras+=(
		"files_restored" "${RESTORE_STATS_FILES_RESTORED}"
		"bytes_restored" "${RESTORE_STATS_BYTES_RESTORED}"
		"elapsed_human" "${RESTORE_STATS_ELAPSED_HUMAN}"
	)
fi

write_last_run_json "restore" "${restoreRC}" "${start}" "${end}" "${last_run_extras[@]}"
notify_webhook "restore" "${restoreRC}" "${start}" "${end}" "${last_run_extras[@]}" || true
write_metrics_for_job "restore" "${restoreRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

# Mail subject details: "<files> files (<bytes>) to <target>" when restic
# produced its summary line; otherwise just the target path.
mail_details="${TARGET}"
if [ -n "${RESTORE_STATS_FILES_RESTORED}" ]; then
	mail_details="${RESTORE_STATS_FILES_RESTORED} files (${RESTORE_STATS_BYTES_RESTORED}) → ${TARGET}"
fi
if [ "${DRY_RUN}" = "ON" ]; then
	mail_details="DRY-RUN · ${mail_details}"
fi
notify_mail "$(format_subject "Restore" "${restoreRC}" "${duration}" "${mail_details}")" "${restoreRC}" || true

run_hook "post-restore" "${restoreRC}" || true

exit "${restoreRC}"
