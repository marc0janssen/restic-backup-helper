#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Sources Report (operator-driven pre-flight inventory)
# Description: Read-only inventory of the paths a backup will actually
#              read: BACKUP_ROOT_DIR (passed positionally to
#              `restic backup`) plus every --files-from / --exclude-file
#              reference discovered inside RESTIC_JOB_ARGS. Reports path
#              readability, type, file count and approximate size; also
#              checks the contents of every --files-from for missing
#              entries and counts pattern lines in --exclude-file files.
#
#              The size figure is the UNFILTERED size of each source
#              (`du -sk`). Exclude rules are NOT subtracted from the
#              total — restic itself decides what is actually skipped at
#              backup time. The exclude-file inventory is reported
#              separately so operators can reason about expected
#              exclusions without this helper having to re-implement
#              restic's matcher.
#
#              Run BEFORE configuring a new backup, after editing
#              RESTIC_JOB_ARGS, or as a CI smoke step that catches
#              missing mounts, unreadable secrets and silently empty
#              --files-from files long before the next BACKUP_CRON tick.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/sources-report-last.log"
LAST_ERROR_LOGFILE="/var/log/sources-report-error-last.log"
LAST_MAIL_LOGFILE="/var/log/sources-report-mail-last.log"

# shellcheck source=app/lib.sh
. /bin/lib.sh

RELEASE="${RESTIC_BACKUP_HELPER_RELEASE:-unknown}"

usage() {
	cat <<'EOF'
Usage: /bin/sources-report [OPTIONS]

Pre-flight inventory of the paths your backup will read. Estimates source
sizes and verifies path readability for BACKUP_ROOT_DIR plus every
--files-from / --exclude-file reference found in RESTIC_JOB_ARGS.

The size figure is the UNFILTERED size of each source (`du -sk`); exclude
rules are NOT applied. The report lists exclude-file paths and pattern
counts separately so you can reason about expected exclusions.

Options:
  --source PATH        Add an ad-hoc path to inspect. Repeatable. By default
                       the report covers BACKUP_ROOT_DIR plus every
                       --files-from referenced in RESTIC_JOB_ARGS.
  --files-from FILE    Add a --files-from file to inspect. Repeatable. By
                       default the report scans RESTIC_JOB_ARGS for them.
  --no-size            Skip size estimation; only check readability, type
                       and the line counts of --files-from / --exclude-file.
                       Recommended on slow/remote sources (NFS, SFTP, cloud
                       mounts) where `du -sk` is expensive.
  --depth N            Cap directory traversal depth at N levels when
                       counting files (default: unlimited). No effect with
                       --no-size. Useful on very large trees.
  --help               Show this help.

Audit trail:
  * /var/log/sources-report-last.log
  * /var/log/last-sources-report.json
  * /hooks/pre-sources-report.sh
  * /hooks/post-sources-report.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing as
    backup/check/prune/forget/forget-preview/replicate/restore/unlock.

Exit codes:
  0  Report produced (even when individual sources are unreadable;
     errors_count in the JSON / log carries that signal).
  2  Configuration error: no sources to inspect (BACKUP_ROOT_DIR empty,
     no --source given, no --files-from in RESTIC_JOB_ARGS or --files-from),
     or invalid --depth.
EOF
}

NO_SIZE="OFF"
DEPTH_LIMIT=""
EXTRA_SOURCES=()
EXTRA_FILES_FROM=()

while [ "$#" -gt 0 ]; do
	case "$1" in
	--source)
		[ -n "${2:-}" ] || {
			echo "❌ --source needs a path argument." >&2
			exit 2
		}
		EXTRA_SOURCES+=("$2")
		shift 2
		;;
	--source=*)
		EXTRA_SOURCES+=("${1#*=}")
		shift
		;;
	--files-from)
		[ -n "${2:-}" ] || {
			echo "❌ --files-from needs a path argument." >&2
			exit 2
		}
		EXTRA_FILES_FROM+=("$2")
		shift 2
		;;
	--files-from=*)
		EXTRA_FILES_FROM+=("${1#*=}")
		shift
		;;
	--no-size)
		NO_SIZE="ON"
		shift
		;;
	--depth)
		[ -n "${2:-}" ] || {
			echo "❌ --depth needs a positive integer." >&2
			exit 2
		}
		DEPTH_LIMIT="$2"
		shift 2
		;;
	--depth=*)
		DEPTH_LIMIT="${1#*=}"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/sources-report --help for usage." >&2
		exit 2
		;;
	esac
done

if [ -n "${DEPTH_LIMIT}" ] && ! [[ "${DEPTH_LIMIT}" =~ ^[1-9][0-9]*$ ]]; then
	echo "❌ --depth must be a positive integer; got '${DEPTH_LIMIT}'." >&2
	exit 2
fi

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
sourcesReportRC=0

if [ -n "${RESTIC_REPOSITORY:-}" ]; then
	MASKED_REPO="$(mask_repository "${RESTIC_REPOSITORY}")"
else
	MASKED_REPO="${RESTIC_REPOSITORY:-}"
fi

if [ "${NO_SIZE}" = "ON" ]; then
	MODE_BANNER="size-skipped (--no-size; only readability + line counts)"
else
	MODE_BANNER="full sizing (du -sk + find -type f)"
fi

log "📋 Starting sources report at $(date +"%Y-%m-%d %a %H:%M:%S")"
log "Release:            ${RELEASE}"
log "Repository:         ${MASKED_REPO}"
log "BACKUP_ROOT_DIR:    ${BACKUP_ROOT_DIR:-(empty)}"
log "RESTIC_JOB_ARGS:    ${RESTIC_JOB_ARGS:-(empty)}"
log "Mode:               ${MODE_BANNER}"
log "Depth limit:        ${DEPTH_LIMIT:-unlimited}"

run_hook "pre-sources-report" || true

# Compose the effective source / files-from / exclude-file lists. Sources
# are deduplicated to avoid double-counting when an operator passes
# --source BACKUP_ROOT_DIR explicitly. Files-from references discovered in
# RESTIC_JOB_ARGS keep their definition order so the report reads top-to-
# bottom in the same order restic itself sees them.
SOURCES=()
if [ -n "${BACKUP_ROOT_DIR:-}" ]; then
	SOURCES+=("${BACKUP_ROOT_DIR}")
fi
for s in "${EXTRA_SOURCES[@]:-}"; do
	[ -z "${s}" ] && continue
	already=0
	for existing in "${SOURCES[@]}"; do
		[ "${existing}" = "${s}" ] && already=1 && break
	done
	[ "${already}" -eq 0 ] && SOURCES+=("${s}")
done

FILES_FROM=()
while IFS= read -r p; do
	[ -n "${p}" ] && FILES_FROM+=("${p}")
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--files-from")
while IFS= read -r p; do
	[ -n "${p}" ] && FILES_FROM+=("${p}")
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--files-from-verbatim")
while IFS= read -r p; do
	[ -n "${p}" ] && FILES_FROM+=("${p}")
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--files-from-raw")
for f in "${EXTRA_FILES_FROM[@]:-}"; do
	[ -n "${f}" ] && FILES_FROM+=("${f}")
done

EXCLUDE_FILES=()
while IFS= read -r p; do
	[ -n "${p}" ] && EXCLUDE_FILES+=("${p}")
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--exclude-file")
while IFS= read -r p; do
	[ -n "${p}" ] && EXCLUDE_FILES+=("${p}")
done < <(collect_arg_paths "${RESTIC_JOB_ARGS:-}" "--iexclude-file")

if [ "${#SOURCES[@]}" -eq 0 ] && [ "${#FILES_FROM[@]}" -eq 0 ]; then
	errorlog "❌ No sources to inspect. Set BACKUP_ROOT_DIR, populate RESTIC_JOB_ARGS with --files-from, or pass --source / --files-from on the CLI."
	sourcesReportRC=2
else
	log ""
	log "📂 Scope:"
	log "  - ${#SOURCES[@]} source path(s)"
	log "  - ${#FILES_FROM[@]} --files-from file(s)"
	log "  - ${#EXCLUDE_FILES[@]} --exclude-file(s)"
fi

# Format an integer byte count as a short human-readable string. Matches
# the output convention `du -h` uses but stays in pure awk so it works on
# both BusyBox and GNU coreutils.
human_bytes() {
	local b="${1:-0}"
	[[ "${b}" =~ ^[0-9]+$ ]] || b=0
	awk -v b="${b}" 'BEGIN {
		split("B KiB MiB GiB TiB PiB", u)
		i = 1
		while (b >= 1024 && i < 6) { b = b / 1024; i++ }
		if (i == 1) printf "%d %s", b, u[i]
		else printf "%.2f %s", b, u[i]
	}'
}

# Best-effort path type label. Distinguishes the four cases the operator
# usually cares about for backup planning: a regular file (single-file
# source via --files-from line), a directory tree, a symlink (worth
# noticing because restic follows it for the root path), or missing.
path_type() {
	local p="$1"
	if [ ! -e "${p}" ]; then
		printf 'missing'
	elif [ -L "${p}" ]; then
		printf 'symlink'
	elif [ -d "${p}" ]; then
		printf 'directory'
	elif [ -f "${p}" ]; then
		printf 'file'
	else
		printf 'other'
	fi
}

# Best-effort byte count for a path. Always uses `du -sk` (POSIX,
# available on both BusyBox and GNU) and multiplies the kilobytes by
# 1024. Empty / unreadable / non-existent paths return 0. The function
# is intentionally lenient under set -e so a single bad source does not
# abort the entire report.
estimate_bytes() {
	local p="$1"
	local kb
	if [ ! -e "${p}" ]; then
		printf '0'
		return
	fi
	kb="$(du -sk "${p}" 2>/dev/null | awk '{print $1; exit}')" || kb=0
	[[ "${kb}" =~ ^[0-9]+$ ]] || kb=0
	printf '%d' "$((kb * 1024))"
}

# Best-effort file count for a path. Uses `find -type f` so symlinks
# pointing at directories are NOT followed (matches what restic actually
# stores). When --depth N was passed, the find search is capped, which
# can dramatically reduce the time on huge trees at the cost of an
# under-count for very deep hierarchies (the JSON `files` field reflects
# the cap, not the true number).
count_files() {
	local p="$1"
	local depth_args=()
	if [ -n "${DEPTH_LIMIT}" ]; then
		depth_args=(-maxdepth "${DEPTH_LIMIT}")
	fi
	if [ ! -e "${p}" ] || [ ! -r "${p}" ]; then
		printf '0'
		return
	fi
	if [ -f "${p}" ]; then
		printf '1'
		return
	fi
	find "${p}" "${depth_args[@]}" -type f 2>/dev/null | wc -l | tr -d ' \n'
}

# Aggregate counters; promoted to Prometheus gauges via the standard
# write_metrics_for_job extras path.
TOTAL_FILES=0
TOTAL_BYTES=0
ERRORS_COUNT=0

# JSON-encode a value as a quoted string. Handles the three characters
# JSON parsers refuse silently (backslash, double-quote, control chars).
json_string() {
	local s="${1:-}"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	# Replace literal newlines / tabs with their JSON escapes.
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	printf '"%s"' "${s}"
}

# Build the per-source JSON inventory in a single shell variable so the
# final write_last_run_json call can embed it. write_last_run_json itself
# only knows about flat key/value extras; the nested-array detail is
# emitted by appending a custom suffix below.
SOURCES_JSON='[]'
FILES_FROM_JSON='[]'
EXCLUDE_FILES_JSON='[]'

if [ "${sourcesReportRC}" -eq 0 ]; then
	# ----- Sources table -----
	if [ "${#SOURCES[@]}" -gt 0 ]; then
		SOURCES_JSON=''
		log ""
		log "Source inventory:"
		log "  PATH                                              READABLE  TYPE       FILES        SIZE"
		log "  ------------------------------------------------  --------  ---------  ----------  ---------------"
		first=1
		for src in "${SOURCES[@]}"; do
			t="$(path_type "${src}")"
			if [ "${t}" = "missing" ]; then
				readable="false"
				ERRORS_COUNT=$((ERRORS_COUNT + 1))
				bytes=0
				files=0
			elif [ -r "${src}" ]; then
				readable="true"
				if [ "${NO_SIZE}" = "ON" ]; then
					bytes=-1
					files=-1
				else
					log "🔎 Sizing ${src} ..."
					bytes="$(estimate_bytes "${src}")"
					files="$(count_files "${src}")"
				fi
			else
				readable="false"
				ERRORS_COUNT=$((ERRORS_COUNT + 1))
				bytes=0
				files=0
			fi
			if [ "${bytes}" = "-1" ]; then
				size_h="skipped"
			else
				size_h="$(human_bytes "${bytes}")"
				TOTAL_BYTES=$((TOTAL_BYTES + bytes))
			fi
			if [ "${files}" = "-1" ]; then
				files_h="skipped"
			else
				files_h="${files}"
				TOTAL_FILES=$((TOTAL_FILES + files))
			fi
			row="$(printf '  %-48.48s  %-8s  %-9s  %10s  %15s' \
				"${src}" "${readable}" "${t}" "${files_h}" "${size_h}")"
			log "${row}"
			[ "${first}" -eq 0 ] && SOURCES_JSON+=','
			first=0
			SOURCES_JSON+="$(printf '{"path":%s,"readable":%s,"type":%s,"files":%s,"bytes":%s}' \
				"$(json_string "${src}")" \
				"${readable}" \
				"$(json_string "${t}")" \
				"${files}" \
				"${bytes}")"
		done
		SOURCES_JSON="[${SOURCES_JSON}]"
	fi

	# ----- --files-from inventory -----
	if [ "${#FILES_FROM[@]}" -gt 0 ]; then
		log ""
		log "--files-from inventory:"
		log "  PATH                                              READABLE  LINES   MISSING_ENTRIES"
		log "  ------------------------------------------------  --------  ------  ----------------"
		FILES_FROM_JSON=''
		first=1
		for ff in "${FILES_FROM[@]}"; do
			# Collect missing entries so we can both COUNT them for the
			# JSON / errors aggregate and SHOW the first few inline under
			# each row — a teller alone is not actionable, a sample of
			# offending paths is. Cap the inline list at five so a stale
			# 10k-line --files-from doesn't drown the report.
			missing=0
			missing_samples=()
			missing_sample_cap=5
			if [ -r "${ff}" ]; then
				readable="true"
				lines="$(grep -cEv '^\s*(#|$)' "${ff}" 2>/dev/null || true)"
				[[ "${lines}" =~ ^[0-9]+$ ]] || lines=0
				while IFS= read -r entry; do
					[ -z "${entry}" ] && continue
					case "${entry}" in
					\#*) continue ;;
					esac
					if [ ! -e "${entry}" ]; then
						missing=$((missing + 1))
						if [ "${#missing_samples[@]}" -lt "${missing_sample_cap}" ]; then
							missing_samples+=("${entry}")
						fi
					fi
				done <"${ff}"
				if [ "${missing}" -gt 0 ]; then
					ERRORS_COUNT=$((ERRORS_COUNT + missing))
				fi
			else
				readable="false"
				lines=0
				ERRORS_COUNT=$((ERRORS_COUNT + 1))
			fi
			row="$(printf '  %-48.48s  %-8s  %6s  %16s' \
				"${ff}" "${readable}" "${lines}" "${missing}")"
			log "${row}"
			if [ "${missing}" -gt 0 ]; then
				if [ "${missing}" -le "${missing_sample_cap}" ]; then
					log "    Missing --files-from entries (${missing}):"
				else
					log "    Missing --files-from entries (first ${missing_sample_cap} of ${missing}):"
				fi
				for entry in "${missing_samples[@]}"; do
					log "      - ${entry}"
				done
				if [ "${missing}" -gt "${missing_sample_cap}" ]; then
					log "    ... and $((missing - missing_sample_cap)) more."
				fi
			fi
			[ "${first}" -eq 0 ] && FILES_FROM_JSON+=','
			first=0
			FILES_FROM_JSON+="$(printf '{"path":%s,"readable":%s,"lines":%s,"missing_entries":%s}' \
				"$(json_string "${ff}")" \
				"${readable}" \
				"${lines}" \
				"${missing}")"
		done
		FILES_FROM_JSON="[${FILES_FROM_JSON}]"
	fi

	# ----- --exclude-file inventory -----
	if [ "${#EXCLUDE_FILES[@]}" -gt 0 ]; then
		log ""
		log "--exclude-file inventory:"
		log "  PATH                                              READABLE  PATTERNS"
		log "  ------------------------------------------------  --------  --------"
		EXCLUDE_FILES_JSON=''
		first=1
		for ef in "${EXCLUDE_FILES[@]}"; do
			if [ -r "${ef}" ]; then
				readable="true"
				patterns="$(grep -cEv '^\s*(#|$)' "${ef}" 2>/dev/null || true)"
				[[ "${patterns}" =~ ^[0-9]+$ ]] || patterns=0
			else
				readable="false"
				patterns=0
				ERRORS_COUNT=$((ERRORS_COUNT + 1))
			fi
			row="$(printf '  %-48.48s  %-8s  %8s' "${ef}" "${readable}" "${patterns}")"
			log "${row}"
			[ "${first}" -eq 0 ] && EXCLUDE_FILES_JSON+=','
			first=0
			EXCLUDE_FILES_JSON+="$(printf '{"path":%s,"readable":%s,"patterns":%s}' \
				"$(json_string "${ef}")" \
				"${readable}" \
				"${patterns}")"
		done
		EXCLUDE_FILES_JSON="[${EXCLUDE_FILES_JSON}]"
	fi

	log ""
	log "Totals: ${#SOURCES[@]} source(s), ${#FILES_FROM[@]} files-from, ${#EXCLUDE_FILES[@]} exclude-file(s), ${TOTAL_FILES} files, $(human_bytes "${TOTAL_BYTES}") (${TOTAL_BYTES} bytes), ${ERRORS_COUNT} error(s)."
fi

if [ "${sourcesReportRC}" -eq 0 ]; then
	if [ "${ERRORS_COUNT}" -gt 0 ]; then
		log "⚠️ Sources report completed with ${ERRORS_COUNT} unreadable / missing entr$([ "${ERRORS_COUNT}" -eq 1 ] && echo "y" || echo "ies"). Inspect ${LAST_LOGFILE}."
	else
		log "✅ Sources report completed cleanly (${#SOURCES[@]} source(s), ${TOTAL_FILES} files, $(human_bytes "${TOTAL_BYTES}"))."
	fi
else
	log "❌ Sources report failed with Status ${sourcesReportRC}"
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished sources report at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

last_run_extras=(
	"backup_root_dir" "${BACKUP_ROOT_DIR:-}"
	"sources_count" "${#SOURCES[@]}"
	"files_from_count" "${#FILES_FROM[@]}"
	"exclude_files_count" "${#EXCLUDE_FILES[@]}"
	"total_files" "${TOTAL_FILES}"
	"total_bytes" "${TOTAL_BYTES}"
	"errors_count" "${ERRORS_COUNT}"
	"no_size" "${NO_SIZE}"
	"depth_limit" "${DEPTH_LIMIT:-unlimited}"
)

write_last_run_json "sources-report" "${sourcesReportRC}" "${start}" "${end}" "${last_run_extras[@]}"

# write_last_run_json emits flat key/value extras only. The per-source
# arrays are surfaced by appending them to the JSON file just before the
# closing brace — this is a self-contained post-processing step so the
# common helper does not need to grow nested-array support for one caller.
# The temp file dance keeps the on-disk file atomic from a reader's POV.
JSON_FILE="/var/log/last-sources-report.json"
if [ -s "${JSON_FILE}" ]; then
	tmp="${JSON_FILE}.detail.tmp"
	sed -e 's/}\s*$//' "${JSON_FILE}" >"${tmp}"
	printf ',"sources":%s,"files_from":%s,"exclude_files":%s}\n' \
		"${SOURCES_JSON}" "${FILES_FROM_JSON}" "${EXCLUDE_FILES_JSON}" \
		>>"${tmp}"
	mv "${tmp}" "${JSON_FILE}"
fi

notify_webhook "sources-report" "${sourcesReportRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

write_metrics_for_job "sources_report" "${sourcesReportRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Sources report" "${sourcesReportRC}" "${duration}" "${BACKUP_ROOT_DIR:-${RESTIC_JOB_ARGS:-no sources}}")" "${sourcesReportRC}" || true

run_hook "post-sources-report" "${sourcesReportRC}" || true

exit "${sourcesReportRC}"
