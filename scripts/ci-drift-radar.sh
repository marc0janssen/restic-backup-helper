#!/bin/sh
set -eu

log_info() {
	echo "[info] [drift-radar] $*"
}

log_crit() {
	echo "[crit] [drift-radar] $*" >&2
}

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "${repo_root}"

require_file() {
	path="$1"
	if [ ! -f "${path}" ]; then
		log_crit "Missing required file: ${path}"
		exit 1
	fi
}

require_file "Dockerfile"
require_file "scripts/update-restic-base.sh"

current_restic="$(sed -n 's/^FROM restic\/restic://p' Dockerfile | head -n1)"
if [ -z "${current_restic}" ]; then
	log_crit "Unable to read FROM restic/restic tag from Dockerfile"
	exit 1
fi

log_info "Resolving latest Restic release tag from GitHub"
latest_restic="$(
	python3 -c '
import json
import urllib.request
url = "https://api.github.com/repos/restic/restic/releases/latest"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "restic-backup-helper-ci"})
with urllib.request.urlopen(req, timeout=60) as r:
    tag = json.load(r)["tag_name"]
print(tag[1:] if tag.startswith("v") else tag)
'
)"

drift_count=0
summary_file="$(mktemp)"
trap 'rm -f "${summary_file}"' EXIT INT TERM

status_line() {
	label="$1"
	current="$2"
	latest="$3"
	if [ "${current}" = "${latest}" ]; then
		printf -- '- ✅ %s: `%s` (up to date)\n' "${label}" "${current}"
	else
		drift_count=$((drift_count + 1))
		printf -- '- ⚠️ %s: current `%s`, latest `%s`\n' "${label}" "${current}" "${latest}"
	fi
}

{
	echo "## Dependency drift radar (restic/restic base image)"
	echo
	echo "- Generated: \`$(date -u '+%Y-%m-%d %H:%M:%S UTC')\`"
	echo "- Repository: \`marc0janssen/restic-backup-helper\`"
	echo
	echo "### Base image"
	status_line "Dockerfile FROM restic/restic" "${current_restic}" "${latest_restic}"
	echo
	if [ "${drift_count}" -eq 0 ]; then
		echo "✅ No dependency drift detected."
	else
		echo "⚠️ Drift detected: Dockerfile pins an older Restic release than GitHub latest."
		echo
		echo "Suggested next actions:"
		echo "- Review breaking changes in upstream Restic release notes."
		echo "- Run \`./scripts/update-restic-base.sh ./Dockerfile ${latest_restic}\` and align \`VERSION_RESTIC\` in build env files."
	fi
} >"${summary_file}"

cat "${summary_file}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	cat "${summary_file}" >>"${GITHUB_STEP_SUMMARY}"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		if [ "${drift_count}" -eq 0 ]; then
			echo "drift_detected=no"
		else
			echo "drift_detected=yes"
		fi
		echo "drift_count=${drift_count}"
		echo "current_restic_tag=${current_restic}"
		echo "latest_restic_tag=${latest_restic}"
		echo "summary_body<<EOF"
		cat "${summary_file}"
		echo "EOF"
	} >>"${GITHUB_OUTPUT}"
fi

log_info "Drift radar completed (drift_count=${drift_count})"
