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
  --verbose, -v       Stream restic's output to stdout while the restore
                      is running. Passes --verbose=2 to restic so per-file
                      lines (`restored /path/...`) appear, and wraps restic
                      in `script(1)` so the native in-place progress bar
                      (`[time] X%, MiB/s, ETA …`) renders too. The combined
                      output is tee'd to restore-last.log; the file then
                      contains ANSI escape codes and \r overwrites from
                      the progress bar — view with `cat` on a terminal or
                      strip with `col -bp`.
  --force             Allow restoring into a non-empty target.
  --yes, -y           Run fully non-interactive: skip the snapshot picker,
                      the target prompt, the dry-run prompt AND the final
                      "Proceed? [y/N/q]" confirmation. Falls back on the
                      same defaults the cron/CI path uses (latest snapshot,
                      /restore target, no dry-run) so an operator inside
                      `docker exec -ti …` can launch a one-shot restore
                      without dropping the TTY via `< /dev/null`.
  --list              List matching snapshots (most recent 20) and exit.
  --all               When combined with --list, show all matching snapshots.
  --help              Show this help and exit.

Interactive mode:
  Triggered by stdin/stdout being a TTY (`docker exec -ti ...`) AND --yes
  not being passed. Flags can suppress prompts individually:
    --id          skips the snapshot picker
    --target      skips the target prompt
    --dry-run     skips the dry-run prompt
  ...or all at once:
    --yes / -y    runs the whole command non-interactively (same code path
                  as cron/CI), filling in any missing answer with the
                  default (latest snapshot / /restore / no dry-run).
  Other flags (--verbose, --force, --verify, --tag, --host, --since,
  --include, --exclude, --owner) leave the interactive flow intact.

  Without a TTY (cron, CI, `docker exec` without -t) no prompts are ever
  shown and the wrapper falls back to "latest" when --id is not provided.

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
VERBOSE="OFF"
# --yes / -y bypasses *only* the final "Proceed?" safety prompt. The earlier
# pre-prompts (snapshot picker, target, dry-run) are already suppressed by
# --id, --target and --dry-run respectively, so --yes is what lets an
# operator in an interactive container shell launch a fully-specified restore
# in one shot without falling back to `< /dev/null` tricks.
ASSUME_YES="OFF"

# Per-prompt explicit-flag markers. Interactive mode skips a prompt only when
# the *answer* was already supplied via a flag. We cannot infer this from the
# variable alone because TARGET defaults to /restore (not empty) and DRY_RUN
# is toggled ON by the prompt itself. Modifiers like --verbose, --force,
# --verify, --include, --exclude, --owner, --tag, --host and --since are pure
# behaviour/filter overrides and do not affect interactivity at all.
TARGET_EXPLICIT="OFF"
DRY_RUN_EXPLICIT="OFF"

# Allow operators to abort the interactive flow at any prompt by typing `q`
# or `quit`. Writes a cancelled-style last-restore.json (exit 130, same as
# answering "n" to the final Proceed? prompt) so external monitoring can
# distinguish "operator changed their mind" from "restore actually failed".
# Safe to call before `start` has been set: falls back to the current epoch
# for both timestamps so the JSON document is always well-formed.
cancel_interactive_restore() {
	local now
	now="$(date +%s)"
	log "🛑 Restore cancelled by operator."
	write_last_run_json "restore" 130 "${start:-${now}}" "${now}" \
		"repository" "${MASKED_REPO:-}" \
		"snapshot" "${SNAP_ID:-}" \
		"target" "${TARGET:-}" \
		"cancelled" "true"
	exit 130
}

while [ $# -gt 0 ]; do
	case "$1" in
	--id)
		SNAP_ID="${2:-}"
		shift 2
		;;
	--target)
		TARGET="${2:-}"
		TARGET_EXPLICIT="ON"
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
	--since)
		SINCE_FILTER="${2:-}"
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
	--owner)
		CHOWN_SPEC="${2:-}"
		shift 2
		;;
	--dry-run)
		DRY_RUN="ON"
		DRY_RUN_EXPLICIT="ON"
		shift
		;;
	--verify)
		DO_VERIFY="ON"
		shift
		;;
	--force)
		FORCE="ON"
		shift
		;;
	--list)
		LIST_ONLY="ON"
		shift
		;;
	--all)
		LIST_ALL="ON"
		shift
		;;
	--verbose | -v)
		VERBOSE="ON"
		shift
		;;
	--yes | -y)
		ASSUME_YES="ON"
		shift
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
#   index<TAB>short_id<TAB>time<TAB>host<TAB>tags<TAB>paths
# Index is 1-based and rows are emitted **newest-first** so callers can take
# the first N rows to display "the N most recent". `restic snapshots --json`
# itself orders oldest-first, so the END block below reverses + renumbers.
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
		function jget(blob, key,    m, s, n, rest) {
			# Match "key":"value" or "key":number; returns the string between
			# the first balanced quote pair following the key. Sufficient for
			# the simple fields we need.
			# All non-param locals (m, s, n, rest) MUST stay in this param
			# list; otherwise n collides with the body block`s array counter
			# and overwrites out[] entries between records.
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
		function jget_array(blob, key,    n, s, rest, m, content) {
			# Returns the contents of a string array as a comma-separated
			# list. Used for "tags" and "paths". All scratch variables MUST
			# remain locals (param list) so they cannot clobber the body
			# block`s `n` counter.
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
			n++
			out[n] = short_id "\t" short_time "\t" hostname "\t" tags "\t" paths
		}
		END {
			# Reverse so the newest snapshot from `restic snapshots --json`
			# (which emits oldest-first) becomes row 1, and renumber the
			# leading column to a 1-based newest-first ordinal so the
			# interactive prompt`s "index 1-N" maps to what is actually
			# displayed.
			for (i = n; i >= 1; i--) {
				printf "%d\t%s\n", (n - i + 1), out[i]
			}
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

# Interactive is a TTY decision *unless* --yes was passed. --yes is an
# explicit operator opt-out: "use whatever I supplied via flags/env, fall
# back on the same defaults the cron/CI path uses, ask nothing." That means
# from inside the container shell (`docker exec -ti …`) the operator can
# still get a fully prompt-less run without the `< /dev/null` TTY-dropping
# trick. Per-prompt flags (--id, --target, --dry-run) still only suppress
# their own prompt when --yes is *not* set.
INTERACTIVE="OFF"
if [ -t 0 ] && [ -t 1 ] && [ "${ASSUME_YES}" = "OFF" ]; then
	INTERACTIVE="ON"
fi

# Build the snapshot table only when we actually need it: either the operator
# is going to pick from it (interactive + no --id) or we cannot resolve a
# default ("latest") in the non-interactive path (handled below by passing
# the literal "latest" token to restic).
TABLE=""
if [ "${INTERACTIVE}" = "ON" ] && [ -z "${SNAP_ID}" ]; then
	TABLE="$(list_snapshots_table)"
fi

SNAPSHOT_COUNT=0
if [ -n "${TABLE}" ]; then
	SNAPSHOT_COUNT="$(printf '%s\n' "${TABLE}" | grep -c .)"
fi

if [ "${INTERACTIVE}" = "ON" ]; then
	# Clear stale log content before the first user-facing prompt so a
	# cancel via `q`/`quit` does not append to a previous run's log file.
	rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

	if [ -z "${SNAP_ID}" ]; then
		echo "📋 Matching snapshots in ${MASKED_REPO} (tag='${TAG_FILTER:-*}' host='${HOST_FILTER:-*}', newest first):"
		printf '%s\n' "${TABLE}" | print_snapshot_table 10
		if [ "${SNAPSHOT_COUNT}" -eq 0 ]; then
			echo "❌ Nothing to restore. Run /bin/restore --list to widen the filter, or pass --tag/--host." >&2
			exit 1
		fi
		# Range shown in the prompt = number of rows actually displayed (max 10).
		# Older snapshots remain reachable via their short-id (see `--list`).
		shown_in_interactive=10
		if [ "${SNAPSHOT_COUNT}" -lt "${shown_in_interactive}" ]; then
			shown_in_interactive="${SNAPSHOT_COUNT}"
		fi
		if [ "${SNAPSHOT_COUNT}" -gt "${shown_in_interactive}" ]; then
			echo "(showing ${shown_in_interactive} most recent of ${SNAPSHOT_COUNT}; run /bin/restore --list for all, or use a short-id below)"
		fi
		echo ""
		read -r -p "Snapshot to restore [index 1-${shown_in_interactive} or short-id, default=latest, q=quit]: " choice
		case "${choice,,}" in
		q | quit) cancel_interactive_restore ;;
		esac
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
	else
		echo "📌 Snapshot pre-selected via --id: ${SNAP_ID}"
	fi

	if [ "${TARGET_EXPLICIT}" = "OFF" ]; then
		read -r -p "Restore target [${TARGET}, q=quit]: " new_target
		case "${new_target,,}" in
		q | quit) cancel_interactive_restore ;;
		esac
		if [ -n "${new_target}" ]; then
			TARGET="${new_target}"
		fi
	fi

	if [ "${DRY_RUN_EXPLICIT}" = "OFF" ]; then
		read -r -p "Dry-run first? [Y/n/q]: " dr
		case "${dr,,}" in
		q | quit) cancel_interactive_restore ;;
		esac
		dr="${dr:-Y}"
		if [[ "${dr^^}" == "Y" || "${dr^^}" == "YES" ]]; then
			DRY_RUN="ON"
		fi
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
# Verbose mode: ask restic itself to emit per-file output so there is
# actually something to stream. --verbose=2 is the level that prints
# `restored /path/to/file`, `skipped /path/to/file` and `unchanged …`
# lines (restic PR #4839, present since 0.17+). --verbose=1 by itself
# barely produces extra output for `restore`, which is why --verbose used
# to look like a no-op during a long restore.
#
# The native in-place progress bar (`[3:42] 5.2%, 12 MiB/s, 1234/24000
# files`) requires restic to detect a real TTY on stdout. Our tee-to-log
# pipe makes that detection fail; if you want the percentage bar back,
# add util-linux to the image and wrap restic in `script` so the child
# sees a PTY. The per-file stream below is the dependency-free fallback.
if [ "${VERBOSE}" = "ON" ]; then
	restore_cmd+=(--verbose=2)
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

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
logLast "VERBOSE: ${VERBOSE}"
logLast "FORCE: ${FORCE}"
logLast "ASSUME_YES: ${ASSUME_YES}"
logLast "CHOWN_SPEC: ${CHOWN_SPEC:-}"

# Preview the exact restic invocation regardless of interactive mode so an
# operator running with --yes (no Proceed prompt) still sees the command
# being executed. In a TTY this also serves as the leader for the prompt.
echo ""
echo "About to run: restic ${restore_cmd[*]}"
if [ "${DRY_RUN}" = "ON" ]; then
	echo "(dry-run; no files will be written)"
fi

if [ "${INTERACTIVE}" = "ON" ]; then
	read -r -p "Proceed? [y/N/q]: " confirm
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
elif [ "${ASSUME_YES}" = "ON" ]; then
	# Audit-friendly: explicit one-liner so the cron / non-TTY log clearly
	# records that the Proceed prompt was bypassed by --yes rather than
	# never reached because there was no TTY.
	echo "(--yes: skipping Proceed? confirmation)"
fi

# if/else captures restic's exit code without aborting under `set -e`.
# Verbose mode: wrap restic in `script(1)` (util-linux) so restic sees a
# real PTY on stdout and renders its native in-place progress bar
# (`[time] X% files, MiB/s, ETA …`) instead of suppressing it because of
# the tee pipe. Combined output is still tee'd into restore-last.log so
# the run remains auditable. `set -o pipefail` is already active, so the
# pipeline's exit code reflects restic's (not tee's) when restic fails;
# `script -e` ensures script itself exits with the child's status. The
# log file will contain ANSI escape sequences and \r overwrites from the
# progress bar — pipe through `col -bp` (also from util-linux) or `cat`
# on a terminal to read it back as plain text. `parse_restic_restore_stats`
# in lib.sh normalises \r → \n before grepping so the Summary line is
# still extractable.
#
# `printf '%q '` shell-safe-quotes every restic argument, so paths with
# spaces or special characters survive the script -c invocation.
if [ "${VERBOSE}" = "ON" ]; then
	restic_cmd_str="$(printf '%q ' restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}")"
	# script(1) parses `-c CMD` with $SHELL; on the Restic Alpine base
	# SHELL is /bin/ash, which does not understand bash's %q output
	# (e.g. $'\t' for non-printable chars). Force bash explicitly so the
	# round-trip stays safe regardless of the container's default shell.
	if SHELL=/bin/bash script -q -e -f -c "${restic_cmd_str}" /dev/null 2>&1 | tee -a "${LAST_LOGFILE}"; then
		restoreRC=0
	else
		restoreRC=$?
	fi
else
	if restic "${RESTIC_CACERT_ARGS[@]}" "${restore_cmd[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		restoreRC=0
	else
		restoreRC=$?
	fi
fi
logLast "Finished restore at $(date +"%Y-%m-%d %a %H:%M:%S")"

parse_restic_restore_stats "${LAST_LOGFILE}"
include_zero_match="OFF"
if [ "${restoreRC}" -eq 0 ] && [ "${#INCLUDE_PATHS[@]}" -gt 0 ] && [ "${RESTORE_STATS_FILES_RESTORED:-}" = "0" ]; then
	include_zero_match="ON"
	restoreRC=3
	errorlog "❌ Restore include matched 0 files/dirs. Check the path as stored in the snapshot (for example /host/... vs /home/...)."
	copyErrorLog
fi

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
if [ "${include_zero_match}" = "ON" ]; then
	last_run_extras+=("include_zero_match" "true")
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
if [ "${include_zero_match}" = "ON" ]; then
	mail_details="include matched 0 · ${mail_details}"
fi
if [ "${DRY_RUN}" = "ON" ]; then
	mail_details="DRY-RUN · ${mail_details}"
fi
notify_mail "$(format_subject "Restore" "${restoreRC}" "${duration}" "${mail_details}")" "${restoreRC}" || true

run_hook "post-restore" "${restoreRC}" || true

exit "${restoreRC}"
