#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Init Repo (operator-driven bootstrap)
# Description: Explicit, audited `restic init` wrapper. Pairs with the
#              entrypoint auto-init probe (RESTIC_CHECK_REPOSITORY_STATUS):
#              when operators disable that probe (so a transient TLS / DNS
#              hiccup can never accidentally call init on a healthy remote)
#              they still need a one-shot bootstrap path. /bin/init-repo
#              fills that gap with a confirmation prompt and a dry-run mode
#              that explains exactly what would happen.
#
#              The helper is read-only when invoked with --dry-run: it
#              runs `restic cat config` to detect an existing repository,
#              then prints the masked repo URL, the resolved init flags
#              and the verdict ("would create" / "would refuse, already
#              exists" / "probe failed") WITHOUT calling `restic init`.
#
#              Without --dry-run the helper requires either an interactive
#              TTY plus a typed-word confirmation ("init") or an explicit
#              --yes / -y flag, so a stray container restart cannot
#              re-initialise a repository.
#
#              Emits the standard worker surface (masked log, last-*.json,
#              restic_init_repo.prom, mail/webhook, pre-/post-init-repo
#              hooks).
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/init-repo-last.log"
LAST_ERROR_LOGFILE="/var/log/init-repo-error-last.log"
LAST_MAIL_LOGFILE="/var/log/init-repo-mail-last.log"

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
Usage: /bin/init-repo [OPTIONS] [-- restic-init-flags...]

Explicit, audited `restic init` wrapper for operators who keep the
entrypoint auto-init probe disabled (RESTIC_CHECK_REPOSITORY_STATUS=OFF)
but still want a guided bootstrap command for a fresh repository.

Without --dry-run a type-to-confirm prompt is shown (or an explicit
--yes flag must be passed) so an unattended container restart can
never re-initialise a repository.

Options:
  --dry-run        Probe with `restic cat config` to detect an existing
                   repository, print the exact `restic init` command
                   that WOULD run (with masked repo URL and resolved
                   flags), then exit WITHOUT calling restic init. Same
                   audit trail (log, JSON, metrics, webhook, hooks) as
                   a real run so monitoring stays consistent.
  --yes, -y        Skip the type-to-confirm prompt. Required for
                   non-interactive use (CI, scripted bootstraps): when
                   stdin is not a TTY and --yes is not set the helper
                   aborts with exit 2 to prevent surprise init runs.
  --help, -h       Show this help.

Extra restic-init flags are read from $RESTIC_INIT_ARGS (whitespace-
split, analogous to RESTIC_JOB_ARGS / RESTIC_FORGET_ARGS) and from any
positional arguments after `--`. Useful examples:
  --repository-version=2
  --copy-chunker-params=/run/secrets/other_repo  (matches a sibling repo)

Audit trail:
  * /var/log/init-repo-last.log
  * /var/log/last-init-repo.json
  * /hooks/pre-init-repo.sh
  * /hooks/post-init-repo.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing
    as backup/check/prune/forget/forget-preview/replicate/restore/
    unlock/sources-report.

Exit codes:
  0  Init succeeded, dry-run completed, or operator cancelled at the
     prompt.
  1  `restic init` returned non-zero (real failure).
  2  Configuration error: missing RESTIC_REPOSITORY / RESTIC_PASSWORD,
     no TTY without --yes, wrong password reported by the pre-probe.
  3  Repository already exists; no init attempted. Idempotent: rerun
     with --dry-run if you want a no-op probe instead.

Examples:
  /bin/init-repo --dry-run                     # probe + print plan, no mutation
  /bin/init-repo                               # interactive: prompts for 'init'
  /bin/init-repo --yes                         # non-interactive (CI)
  /bin/init-repo -- --repository-version=2     # pass-through to restic init
EOF
}

DRY_RUN="OFF"
ASSUME_YES="OFF"
PASSTHROUGH_ARGS=()

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN="ON"
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
	--)
		shift
		PASSTHROUGH_ARGS+=("$@")
		break
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/init-repo --help for usage." >&2
		exit 2
		;;
	esac
done

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
initRC=0
REPO_EXISTED="unknown"
CONFIRMED="OFF"

# Compose the effective init flag list once. RESTIC_INIT_ARGS is the
# stable env-driven knob (mirrors RESTIC_FORGET_ARGS / RESTIC_PRUNE_ARGS
# in shape); CLI passthrough after `--` lets operators add one-off
# tweaks without editing their env file.
INIT_FLAGS=()
if [ -n "${RESTIC_INIT_ARGS:-}" ]; then
	read -r -a RESTIC_INIT_ARGS_TOKENS <<<"${RESTIC_INIT_ARGS}"
	INIT_FLAGS+=("${RESTIC_INIT_ARGS_TOKENS[@]}")
fi
if [ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]; then
	INIT_FLAGS+=("${PASSTHROUGH_ARGS[@]}")
fi

if [ "${DRY_RUN}" = "ON" ]; then
	log "🧪 Starting init-repo DRY-RUN at $(date +"%Y-%m-%d %a %H:%M:%S")"
else
	log "🆕 Starting init-repo at $(date +"%Y-%m-%d %a %H:%M:%S")"
fi
log "Release:            ${RELEASE}"
log "Repository:         ${MASKED_REPO}"
log "RESTIC_CACERT:      ${RESTIC_CACERT:-(empty)}"
log "RESTIC_INIT_ARGS:   ${RESTIC_INIT_ARGS:-(empty)}"
if [ "${#PASSTHROUGH_ARGS[@]}" -gt 0 ]; then
	log "CLI passthrough:    ${PASSTHROUGH_ARGS[*]}"
fi
log "Dry-run:            ${DRY_RUN}"
log "Assume-yes:         ${ASSUME_YES}"

run_hook "pre-init-repo" || true

# --------------- 1. Required-env validation ---------------

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	errorlog "❌ RESTIC_REPOSITORY is empty."
	initRC=2
fi

if [ "${initRC}" -eq 0 ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
	errorlog "❌ Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD (the encryption password will be permanently bound to the new repository — losing it makes all future backups unrecoverable)."
	initRC=2
fi

# --------------- 2. Pre-flight probe (same contract as entry.sh) ---------------
#
# `restic cat config` exits 10 when the repository does not exist (a
# stable contract since restic 0.13). 0 means a repository is already in
# place; anything else points at a transient or auth problem and we
# refuse to run init blindly — that is exactly the safety story behind
# RESTIC_CHECK_REPOSITORY_STATUS=OFF in the first place.

probe_repo() {
	local rc
	if restic "${RESTIC_CACERT_ARGS[@]}" cat config >/dev/null 2>>"${LAST_LOGFILE}"; then
		rc=0
	else
		rc=$?
	fi
	printf '%d' "${rc}"
}

PROBE_RC="-1"
if [ "${initRC}" -eq 0 ]; then
	log "🔎 Probing repository with 'restic cat config' ..."
	PROBE_RC="$(probe_repo)"
	case "${PROBE_RC}" in
	0)
		REPO_EXISTED="true"
		log "ℹ️  Repository already exists at '${MASKED_REPO}'."
		;;
	10)
		REPO_EXISTED="false"
		log "🆕 Repository does not exist yet (probe exit 10) — ready for init."
		;;
	12)
		errorlog "❌ Wrong password reported by the pre-probe (exit 12). Refusing to run init: a wrong-password failure on an EXISTING repo is not something init can fix, and on a fresh prefix the same password must succeed."
		initRC=2
		;;
	*)
		errorlog "❌ Repository probe failed with exit ${PROBE_RC}; refusing to run init to avoid masking a transient failure (auth, network, DNS, TLS). Resolve the probe error first, then retry."
		initRC=2
		;;
	esac
fi

# --------------- 3. Already-exists short-circuit ---------------

if [ "${initRC}" -eq 0 ] && [ "${REPO_EXISTED}" = "true" ]; then
	if [ "${DRY_RUN}" = "ON" ]; then
		log "🧪 Dry-run verdict: would REFUSE — repository already exists; restic init would fail with 'config file already exists'."
	else
		log "⏭  Refusing to init an existing repository (exit 3). This is idempotent: rerun with --dry-run for a no-op probe."
		initRC=3
	fi
fi

# --------------- 4. Plan rendering (used by both dry-run and live) ---------------

render_plan() {
	{
		printf 'Planned command: restic'
		for word in "${RESTIC_CACERT_ARGS[@]}" init "${INIT_FLAGS[@]}"; do
			printf ' %q' "${word}"
		done
		printf '\n'
		printf '(Repository URL is read from $RESTIC_REPOSITORY = %s; not on the command line.)\n' "${MASKED_REPO}"
	}
}

if [ "${initRC}" -eq 0 ] && [ "${REPO_EXISTED}" = "false" ]; then
	plan_output="$(render_plan)"
	# Echo the plan to BOTH stdout (operator) and the log (audit), via log().
	while IFS= read -r line; do
		log "${line}"
	done <<<"${plan_output}"
fi

# --------------- 5. Dry-run exit ---------------

if [ "${DRY_RUN}" = "ON" ] && [ "${initRC}" -eq 0 ] && [ "${REPO_EXISTED}" = "false" ]; then
	log "🧪 Dry-run verdict: would CREATE a new restic repository with the plan above."
fi

# --------------- 6. Confirmation prompt (skipped in dry-run / when repo exists / on --yes) ---------------

if [ "${DRY_RUN}" = "OFF" ] && [ "${initRC}" -eq 0 ] && [ "${REPO_EXISTED}" = "false" ]; then
	if [ "${ASSUME_YES}" = "ON" ]; then
		CONFIRMED="ON"
		log "✅ --yes given; skipping interactive prompt."
	elif [ -t 0 ]; then
		echo ""
		echo "⚠️  About to CREATE a new restic repository at:"
		echo "      ${MASKED_REPO}"
		echo "    The encryption password will be PERMANENTLY bound to the"
		echo "    new repository — losing it makes all future backups unrecoverable."
		echo ""
		printf "Type 'init' to confirm, anything else to cancel: "
		read -r answer
		if [ "${answer}" = "init" ]; then
			CONFIRMED="ON"
			log "✅ Confirmation received."
		else
			CONFIRMED="OFF"
			log "🛑 Operator cancelled (answer was not 'init'). No init attempted."
		fi
	else
		errorlog "❌ Refusing to run init non-interactively without --yes (stdin is not a TTY). Re-run with: /bin/init-repo --yes  (or pipe the bootstrap from an interactive shell)."
		initRC=2
	fi
fi

# --------------- 7. Live init ---------------

if [ "${DRY_RUN}" = "OFF" ] && [ "${initRC}" -eq 0 ] && [ "${REPO_EXISTED}" = "false" ] && [ "${CONFIRMED}" = "ON" ]; then
	log "🚀 Running restic init ..."
	{
		printf 'About to run: restic'
		for word in "${RESTIC_CACERT_ARGS[@]}" init "${INIT_FLAGS[@]}"; do
			printf ' %q' "${word}"
		done
		printf '\n'
	} >>"${LAST_LOGFILE}"

	if restic "${RESTIC_CACERT_ARGS[@]}" init "${INIT_FLAGS[@]}" >>"${LAST_LOGFILE}" 2>&1; then
		initRC=0
	else
		initRC=$?
	fi
	logLast "Finished restic init at $(date +"%Y-%m-%d %a %H:%M:%S")"
fi

# --------------- 8. Summary line ---------------

if [ "${initRC}" -eq 0 ]; then
	if [ "${DRY_RUN}" = "ON" ]; then
		log "✅ Init-repo dry-run completed (repo_existed=${REPO_EXISTED})."
	elif [ "${CONFIRMED}" = "OFF" ] && [ "${REPO_EXISTED}" = "false" ]; then
		log "🛑 Init-repo cancelled by operator at confirmation prompt (no mutation)."
	elif [ "${REPO_EXISTED}" = "true" ]; then
		log "✅ Init-repo completed (no-op; repository already existed)."
	else
		log "✅ Init-repo successful — new restic repository created."
	fi
elif [ "${initRC}" -eq 3 ]; then
	log "ℹ️  Init-repo skipped: repository already exists (exit 3)."
else
	log "❌ Init-repo failed with Status ${initRC}"
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))

log "🏁 Finished init-repo at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"dry_run" "${DRY_RUN}"
	"assume_yes" "${ASSUME_YES}"
	"confirmed" "${CONFIRMED}"
	"repo_existed" "${REPO_EXISTED}"
	"probe_exit_code" "${PROBE_RC}"
	"init_args" "${INIT_FLAGS[*]:-}"
)

write_last_run_json "init-repo" "${initRC}" "${start}" "${end}" "${last_run_extras[@]}"

notify_webhook "init-repo" "${initRC}" "${start}" "${end}" "${last_run_extras[@]}" || true

write_metrics_for_job "init_repo" "${initRC}" "${start}" "${end}" || true

notify_mail "$(format_subject "Init-repo" "${initRC}" "${duration}" "${MASKED_REPO}")" "${initRC}" || true

run_hook "post-init-repo" "${initRC}" || true

exit "${initRC}"
