#!/bin/bash
# =========================================================
# Name: restic-backup-helper
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# Mount Snapshot Script
# Description: Operator-friendly wrapper around `restic mount` that mounts the
#              repository read-only under /fusemount by default, scoped to this
#              container's host/tag, with safe target validation and a trap
#              that unmounts cleanly on signals or crashes.
# =========================================================

set -Eeuo pipefail

LAST_LOGFILE="/var/log/mount-snapshot-last.log"
LAST_ERROR_LOGFILE="/var/log/mount-snapshot-error-last.log"
LAST_MAIL_LOGFILE="/var/log/mount-snapshot-mail-last.log"

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
Usage: /bin/mount-snapshot [OPTIONS]

Mount the Restic repository read-only under a target directory using
`restic mount` (FUSE). Defaults are designed for the common case
"give me last night's snapshot tree, scoped to this host".

Restic exposes every matching snapshot under <target>/snapshots/<id>/...,
plus a stable <target>/snapshots/latest symlink to the most recent
snapshot for the current host/tag filters. The mount is read-only at the
FUSE layer; the repository contents cannot be modified through it.

Options:
  --target PATH     Mountpoint (default: /fusemount). Created if missing;
                    must be writable and either empty or used with --force.
                    /fusemount is intentionally container-internal so it
                    never collides with /bin/restore output or with a
                    host bind-mount on /restore.
  --tag TAG         Filter snapshots by tag (default: $RESTIC_TAG).
  --host HOST       Filter snapshots by host (default: container $HOSTNAME).
  --path PATH       Only expose snapshots that include this path (repeatable).
  --repo-wide       Do not add --host / --tag. Expose every snapshot in the
                    repository (useful for cross-host inspection).
  --allow-other     Pass restic's --allow-other so other UIDs (e.g. a host
                    bind-mount consumer) can read the FUSE tree. Requires
                    `user_allow_other` in /etc/fuse.conf inside the container.
  --force           Allow mounting on a non-empty target or on a refused
                    path (e.g. BACKUP_ROOT_DIR, /data, /host).
  --help, -h        Show this help.

Runtime requirements:
  * FUSE inside the container: `--cap-add SYS_ADMIN --device /dev/fuse`.
  * The mount blocks until you press Ctrl+C (or the container receives
    SIGTERM); the EXIT trap then unmounts cleanly before this helper exits.

Audit trail:
  * /var/log/mount-snapshot-last.log
  * /var/log/last-mount-snapshot.json
  * /hooks/pre-mount-snapshot.sh
  * /hooks/post-mount-snapshot.sh "$rc"
  * MAILX_RCPT / WEBHOOK_URL / METRICS_DIR use the same helper plumbing as
    backup/check/prune/replicate/restore.
EOF
}

TARGET="/fusemount"
TAG_FILTER="${RESTIC_TAG:-}"
HOST_FILTER="${HOSTNAME:-}"
PATH_FILTERS=()
REPO_WIDE="OFF"
ALLOW_OTHER="OFF"
FORCE="OFF"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--target)
		TARGET="${2:-}"
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
		PATH_FILTERS+=("${2:-}")
		shift 2
		;;
	--repo-wide)
		REPO_WIDE="ON"
		shift
		;;
	--allow-other)
		ALLOW_OTHER="ON"
		shift
		;;
	--force)
		FORCE="ON"
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "❌ Unknown argument: $1" >&2
		echo "Run /bin/mount-snapshot --help for usage." >&2
		exit 2
		;;
	esac
done

MOUNTED="OFF"

# shellcheck disable=SC2317,SC2329 # Invoked indirectly via traps below.
unmount_target() {
	if [ "${MOUNTED}" != "ON" ]; then
		return 0
	fi
	if [ -z "${TARGET:-}" ]; then
		return 0
	fi
	# `restic mount` typically unmounts itself on SIGINT/SIGTERM, but if it
	# crashes the FUSE mount can be left behind. Try fusermount first and
	# fall back to umount; ignore failures so we never override the real
	# exit code coming from restic itself.
	fusermount -u "${TARGET}" >/dev/null 2>&1 ||
		umount "${TARGET}" >/dev/null 2>&1 ||
		true
	MOUNTED="OFF"
}

# shellcheck disable=SC2317,SC2329 # Invoked indirectly via the EXIT trap.
cleanup() {
	local rc=$?
	unmount_target
	return "${rc}"
}
trap cleanup EXIT

rm -f "${LAST_LOGFILE}" "${LAST_MAIL_LOGFILE}"

start="$(date +%s)"
mountSnapshotRC=0

log "🔌 Starting snapshot mount at $(date +"%Y-%m-%d %a %H:%M:%S")"
logLast "RELEASE: ${RELEASE}"
logLast "RESTIC_REPOSITORY: ${MASKED_REPO}"
logLast "TARGET: ${TARGET}"
logLast "TAG_FILTER: ${TAG_FILTER:-}"
logLast "HOST_FILTER: ${HOST_FILTER:-}"
logLast "PATH_FILTERS: ${PATH_FILTERS[*]:-}"
logLast "REPO_WIDE: ${REPO_WIDE}"
logLast "ALLOW_OTHER: ${ALLOW_OTHER}"
logLast "FORCE: ${FORCE}"
logLast "RESTIC_CACERT: ${RESTIC_CACERT:-}"

run_hook "pre-mount-snapshot" || true

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
	errorlog "❌ RESTIC_REPOSITORY is empty."
	mountSnapshotRC=2
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ] && [ -z "${RESTIC_PASSWORD:-}" ]; then
	errorlog "❌ Set RESTIC_PASSWORD_FILE or RESTIC_PASSWORD."
	mountSnapshotRC=2
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ -z "${TARGET}" ]; then
	errorlog "❌ --target must not be empty."
	mountSnapshotRC=2
fi

# Refuse system / source directories unless --force is given. The FUSE mount
# hides the real contents while active, so mounting on /data would make the
# backup source disappear from inside the container for the duration of the
# mount; refusing this loudly is friendlier than letting an operator wonder
# why the next scheduled backup suddenly archives 0 bytes.
if [ "${mountSnapshotRC}" -eq 0 ] && [ "${FORCE}" != "ON" ]; then
	case "${TARGET}" in
	"/" | "/bin" | "/sbin" | "/usr" | "/etc" | "/lib" | "/lib64" | \
		"/var" | "/var/log" | "/var/run" | "/var/spool" | "/var/spool/cron" | \
		"/run" | "/proc" | "/sys" | "/dev" | "/tmp" | \
		"/data" | "/host" | "/config" | "/hooks" | "/mnt" | "/mnt/restic")
		errorlog "❌ Refusing to mount on system/source directory '${TARGET}'. Pick a different --target (e.g. /fusemount) or pass --force."
		mountSnapshotRC=2
		;;
	esac
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ "${FORCE}" != "ON" ] &&
	[ -n "${BACKUP_ROOT_DIR:-}" ] && [ "${TARGET}" = "${BACKUP_ROOT_DIR}" ]; then
	errorlog "❌ Refusing to mount on BACKUP_ROOT_DIR ('${BACKUP_ROOT_DIR}'). Pick a different --target or pass --force."
	mountSnapshotRC=2
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ ! -d "${TARGET}" ]; then
	if ! mkdir -p "${TARGET}" 2>/dev/null; then
		errorlog "❌ Mount target '${TARGET}' does not exist and could not be created."
		mountSnapshotRC=1
	fi
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ ! -w "${TARGET}" ]; then
	errorlog "❌ Mount target '${TARGET}' is not writable. Re-mount without :ro or pick a different --target."
	mountSnapshotRC=1
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ "${FORCE}" != "ON" ]; then
	entries="$(find "${TARGET}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
	if [ -n "${entries}" ]; then
		errorlog "❌ Mount target '${TARGET}' is not empty. FUSE would hide its contents while mounted. Empty it, pick a different --target, or pass --force."
		mountSnapshotRC=1
	fi
fi

if [ "${mountSnapshotRC}" -eq 0 ] && [ "${REPO_WIDE}" != "ON" ]; then
	if [ -z "${HOST_FILTER}" ]; then
		errorlog "❌ Host filter is empty. Pass --host HOST or use --repo-wide for an explicit repository-wide mount."
		mountSnapshotRC=2
	fi
	if [ -z "${TAG_FILTER}" ]; then
		errorlog "❌ Tag filter is empty. Set RESTIC_TAG, pass --tag TAG, or use --repo-wide for an explicit repository-wide mount."
		mountSnapshotRC=2
	fi
fi

# FUSE plumbing pre-flight. `restic mount` returns an opaque
# `fusermount: exit status 1 / mount failed: Permission denied` for
# several distinct misconfigurations. Detect them explicitly up front
# so the operator sees the actual fix, not the post-mortem.
if [ "${mountSnapshotRC}" -eq 0 ]; then
	if [ ! -e /dev/fuse ]; then
		errorlog "❌ /dev/fuse is missing inside the container. Start the container with '--device /dev/fuse' (docker run) or 'devices: [/dev/fuse:/dev/fuse]' (compose)."
		mountSnapshotRC=2
	elif [ ! -c /dev/fuse ]; then
		errorlog "❌ /dev/fuse exists but is not a character device. Re-check how it is exposed into the container."
		mountSnapshotRC=2
	elif [ ! -r /dev/fuse ] || [ ! -w /dev/fuse ]; then
		errorlog "❌ /dev/fuse exists but is not read/write accessible. Re-check that the device was passed through with default 0666 c permissions."
		mountSnapshotRC=2
	fi
fi

if [ "${mountSnapshotRC}" -eq 0 ]; then
	if ! command -v fusermount >/dev/null 2>&1; then
		errorlog "❌ /usr/bin/fusermount is missing from PATH; the helper image normally ships it via the 'fuse' apk package. Rebuild the image or install fuse manually."
		mountSnapshotRC=2
	elif [ -x /usr/bin/fusermount ] && [ ! -u /usr/bin/fusermount ]; then
		# Rare: an admin actually stripped the setuid bit from the on-disk
		# inode. The much more common case (no-new-privileges) is caught
		# below via /proc/self/status because that flag does NOT change
		# the on-disk bit; it only tells the kernel to ignore it at exec.
		errorlog "⚠️ /usr/bin/fusermount lost its setuid bit on disk. Rebuild the image or restore 'chmod 4755 /usr/bin/fusermount' before retrying."
	fi
fi

# Effective capabilities + no-new-privileges. A world-readable
# /dev/fuse (typically `crw-rw-rw-`) is NOT sufficient: the actual
# `mount()` syscall needs CAP_SYS_ADMIN, and even when that capability
# is present, 'no-new-privileges:true' tells the kernel to ignore
# fusermount's setuid bit at exec time so FUSE still fails with
# Permission denied. Both flags are readable from /proc/self/status
# without any extra tooling; check them up front.
if [ "${mountSnapshotRC}" -eq 0 ] && [ -r /proc/self/status ]; then
	cap_eff_hex="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
	if [ -n "${cap_eff_hex}" ]; then
		# CAP_SYS_ADMIN is bit 21 (mask 0x200000). Bash interprets
		# `16#<hex>` as a base-16 literal; `(( ... ))` returns a
		# non-zero exit code when the expression evaluates to 0, but
		# the `if` swallows that so set -e stays harmless.
		cap_eff_dec="$((16#${cap_eff_hex}))"
		if ! ((cap_eff_dec & 0x200000)); then
			errorlog "❌ CAP_SYS_ADMIN is not in this container's effective capability set (CapEff=0x${cap_eff_hex}). FUSE needs it. Add '--cap-add SYS_ADMIN' (docker run), 'cap_add: [SYS_ADMIN]' (compose), or 'securityContext.capabilities.add: [SYS_ADMIN]' (Kubernetes)."
			mountSnapshotRC=2
		fi
	fi

	no_new_privs="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || true)"
	if [ "${no_new_privs}" = "1" ]; then
		errorlog "❌ This container is running with no-new-privileges (NoNewPrivs=1 in /proc/self/status). The kernel will ignore the setuid bit on /usr/bin/fusermount, so FUSE fails with Permission denied even when CAP_SYS_ADMIN and /dev/fuse are in place. Drop 'security_opt: [no-new-privileges:true]' for this container, or run /bin/mount-snapshot from a separate short-lived container without it."
		mountSnapshotRC=2
	fi
fi

# AppArmor profile. Even with CAP_SYS_ADMIN, /dev/fuse, and the
# setuid fusermount in place, the docker-default AppArmor profile
# (Ubuntu/Debian hosts, the default Docker shipping AppArmor template)
# can still deny mount(2). When that happens FUSE bubbles up the same
# opaque "fusermount: mount failed: Permission denied" message we are
# trying to avoid. /proc/self/attr/current is readable from inside the
# container and exposes the active profile + mode without extra tooling.
if [ "${mountSnapshotRC}" -eq 0 ] && [ -r /proc/self/attr/current ]; then
	aa_label="$(tr -d '\0\n' </proc/self/attr/current 2>/dev/null || true)"
	case "${aa_label}" in
	"" | "unconfined")
		: # No AppArmor, or explicitly unconfined - nothing to flag.
		;;
	*"(complain)")
		log "ℹ️ AppArmor profile '${aa_label}' is loaded in complain mode; mounts are logged but not blocked."
		;;
	*"(enforce)"*)
		errorlog "❌ AppArmor profile '${aa_label}' is enforcing on this container; profiles like docker-default deny mount(2) regardless of CAP_SYS_ADMIN, so FUSE fails with 'Permission denied'. Add 'security_opt: [apparmor:unconfined]' (compose), '--security-opt apparmor=unconfined' (docker run), or 'container.apparmor.security.beta.kubernetes.io/<container>: unconfined' (Kubernetes ≤1.29) / 'securityContext.appArmorProfile.type: Unconfined' (k8s ≥1.30) for this container."
		mountSnapshotRC=2
		;;
	*)
		log "ℹ️ Unrecognised AppArmor label '${aa_label}'. If FUSE fails with 'Permission denied', the profile likely blocks mount(2); try '--security-opt apparmor=unconfined' for this container."
		;;
	esac
fi

if [ "${mountSnapshotRC}" -eq 0 ]; then
	mount_cmd=(mount)
	if [ "${REPO_WIDE}" = "ON" ]; then
		log "⚠️ Mounting repository-wide (--repo-wide); every snapshot will be visible."
	else
		mount_cmd+=(--host "${HOST_FILTER}" --tag "${TAG_FILTER}")
		log "🔎 Mounting host/tag-scoped tree (host='${HOST_FILTER}', tag='${TAG_FILTER}')."
	fi
	for p in "${PATH_FILTERS[@]:-}"; do
		[ -n "${p}" ] && mount_cmd+=(--path "${p}")
	done
	if [ "${ALLOW_OTHER}" = "ON" ]; then
		mount_cmd+=(--allow-other)
	fi
	mount_cmd+=("${TARGET}")

	{
		printf 'About to run: restic'
		for word in "${RESTIC_CACERT_ARGS[@]}" "${mount_cmd[@]}"; do
			printf ' %q' "${word}"
		done
		printf '\n'
	} >>"${LAST_LOGFILE}"

	log "📂 Mounting at '${TARGET}'. Browse <target>/snapshots/latest. Press Ctrl+C or send SIGTERM to unmount."
	MOUNTED="ON"
	# restic mount blocks until SIGINT/SIGTERM or fusermount -u from outside.
	# Tee so operators see live output and the same lines land in the log.
	if restic "${RESTIC_CACERT_ARGS[@]}" "${mount_cmd[@]}" 2>&1 | tee -a "${LAST_LOGFILE}"; then
		mountSnapshotRC=0
	else
		mountSnapshotRC=${PIPESTATUS[0]}
	fi
	# Restic itself unmounts on a clean exit; clear the flag so the EXIT
	# trap does not double-unmount. unmount_target is still called below as
	# a belt-and-braces in case restic crashed and left a stale FUSE mount.
	MOUNTED="ON"
	unmount_target
fi

if [ "${mountSnapshotRC}" -eq 0 ]; then
	log "✅ Snapshot mount finished cleanly."
else
	log "❌ Snapshot mount exited with status ${mountSnapshotRC}."
	# Common operator wall: the container is missing the FUSE cap or
	# device. Spot-detect the symptom in the per-run log and add an
	# actionable hint so they do not have to grep the FAQ.
	if grep -qE 'fusermount: |mount helper error|Permission denied|fuse: device not found' "${LAST_LOGFILE}" 2>/dev/null; then
		log "💡 Hint: restic mount needs ALL of the following:"
		log "   1) '--cap-add SYS_ADMIN' (compose: 'cap_add: [SYS_ADMIN]')."
		log "   2) '--device /dev/fuse'  (compose: 'devices: [/dev/fuse:/dev/fuse]')."
		log "   3) NO 'security_opt: [no-new-privileges:true]' on this container — that flag strips the setuid bit on /usr/bin/fusermount at exec time, breaking FUSE."
		log "   4) AppArmor not enforcing 'docker-default' (Ubuntu/Debian hosts): add 'security_opt: [apparmor:unconfined]' (compose) / '--security-opt apparmor=unconfined' (docker run) / 'container.apparmor.security.beta.kubernetes.io/<container>: unconfined' annotation (k8s ≤1.29) / 'securityContext.appArmorProfile.type: Unconfined' (k8s ≥1.30)."
		log "   5) The 'fuse' apk package present in the image (provides /usr/bin/fusermount). Rebuild from the current Dockerfile or 'apk add --no-cache fuse' for a quick smoke-test."
	fi
	copyErrorLog "${LAST_LOGFILE}" "${LAST_ERROR_LOGFILE}"
fi

end="$(date +%s)"
duration=$((end - start))
log "🏁 Finished snapshot mount at $(date +"%Y-%m-%d %a %H:%M:%S") after $(human_duration "${duration}")"

last_run_extras=(
	"repository" "${MASKED_REPO}"
	"target" "${TARGET}"
	"repo_wide" "${REPO_WIDE}"
	"allow_other" "${ALLOW_OTHER}"
)
if [ "${REPO_WIDE}" != "ON" ]; then
	last_run_extras+=(
		"host_filter" "${HOST_FILTER}"
		"tag_filter" "${TAG_FILTER}"
	)
fi
if [ "${#PATH_FILTERS[@]}" -gt 0 ]; then
	last_run_extras+=("path_filters" "${PATH_FILTERS[*]}")
fi

write_last_run_json "mount-snapshot" "${mountSnapshotRC}" "${start}" "${end}" "${last_run_extras[@]}"
notify_webhook "mount-snapshot" "${mountSnapshotRC}" "${start}" "${end}" "${last_run_extras[@]}" || true
write_metrics_for_job "mount_snapshot" "${mountSnapshotRC}" "${start}" "${end}" || true
notify_mail "$(format_subject "Mount snapshot" "${mountSnapshotRC}" "${duration}" "${TARGET}")" "${mountSnapshotRC}" || true

run_hook "post-mount-snapshot" "${mountSnapshotRC}" || true

exit "${mountSnapshotRC}"
