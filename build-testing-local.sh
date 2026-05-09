#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Name: restic-backup-helper — local/private registry testing image
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
#
# Same idea as marc0janssen/nzbgetvpn build-testing-local.sh: push to your own
# registry without bumping VERSION or editing README.md.
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
	cat <<'EOF'
Usage: build-testing-local.sh [--repo <host:port/name>] [--platform <platforms>]
       build-testing-local.sh --help

Local/private-registry variant of build-testing.sh.

Builds ./Dockerfile with the same layout as production testing images. Does not
increment VERSION and does not modify README.md. The image gets release metadata
via Docker build-arg RESTIC_BACKUP_HELPER_RELEASE (see Dockerfile).

Optional env file:
  build-testing-local.env (copy from build-testing-local.env.example)

Defaults (override with LOCAL_REPO / LOCAL_PLATFORM or CLI):
  repo:     192.168.1.1:5000/restic-backup-helper
  platform: linux/amd64

Precedence (hoog → laag): CLI --repo / --platform → niet-lege export in je shell
→ build-testing-local.env → defaults in dit script / scripts/build-common.sh.

Environment:
  VERSION_RESTIC   Same as build-testing.sh (default 0.18.1); keep in sync with Dockerfile FROM.

Docker tag pushed (only):
  <LOCAL_REPO>:testing

Examples:
  ./build-testing-local.sh
  ./build-testing-local.sh --repo 192.168.1.10:5000/restic-backup-helper --platform linux/arm64
EOF
}

trim_value() {
	printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

case "${1:-}" in
-h | --help)
	show_help
	exit 0
	;;
esac

# Shell-export overrides (alleen niet-leeg) — moeten build-testing-local.env kunnen overschrijven.
# Een lege export LOCAL_REPO="" mag het bestand NIET verwerpen (oude bug: restore overschreef met leeg).
_o_LOCAL_REPO=""
_o_LOCAL_PLATFORM=""
_o_VERSION_RESTIC=""
[[ -n "${LOCAL_REPO:-}" ]] && _o_LOCAL_REPO="${LOCAL_REPO}"
[[ -n "${LOCAL_PLATFORM:-}" ]] && _o_LOCAL_PLATFORM="${LOCAL_PLATFORM}"
[[ -n "${VERSION_RESTIC:-}" ]] && _o_VERSION_RESTIC="${VERSION_RESTIC}"

# shellcheck source=scripts/build-common.sh
source "${SCRIPT_DIR}/scripts/build-common.sh"

# --- build-testing-local.env (optioneel, naast dit script in repo root) ---
_env_file="${SCRIPT_DIR}/build-testing-local.env"
if [[ -f "${_env_file}" ]]; then
	echo "[build] Env-bestand laden: ${_env_file}"
	# shellcheck disable=SC1090
	source "${_env_file}"
	# Windows/CRLF: carriage returns na waarde verwijderen
	LOCAL_REPO="${LOCAL_REPO//$'\r'/}"
	LOCAL_PLATFORM="${LOCAL_PLATFORM//$'\r'/}"
	VERSION_RESTIC="${VERSION_RESTIC//$'\r'/}"
else
	echo "[build] Geen env-bestand (optioneel): ${_env_file} — defaults voor LOCAL_REPO / LOCAL_PLATFORM"
fi

# Export-voorkeur terugzetten (alleen als niet-leeg vastgelegd vóór dit script)
[[ -n "${_o_LOCAL_REPO}" ]] && LOCAL_REPO="${_o_LOCAL_REPO}"
[[ -n "${_o_LOCAL_PLATFORM}" ]] && LOCAL_PLATFORM="${_o_LOCAL_PLATFORM}"
[[ -n "${_o_VERSION_RESTIC}" ]] && VERSION_RESTIC="${_o_VERSION_RESTIC}"

# build-common.sh zet hier geen VERSION_RESTIC-default meer vóór env; vul aan als alles nog leeg is.
VERSION_RESTIC="${VERSION_RESTIC:-0.18.1}"

LOCAL_REPO_ARG="${LOCAL_REPO:-192.168.1.1:5000/restic-backup-helper}"
PLATFORM_ARG="${LOCAL_PLATFORM:-linux/amd64}"

while [[ "$#" -gt 0 ]]; do
	arg="$(trim_value "$1")"
	case "$1" in
	--repo)
		if [[ "$#" -lt 2 ]]; then
			echo "--repo requires a value" >&2
			exit 1
		fi
		LOCAL_REPO_ARG="$(trim_value "$2")"
		shift 2
		;;
	--repo=*)
		LOCAL_REPO_ARG="$(trim_value "${arg#--repo=}")"
		shift
		;;
	--platform)
		if [[ "$#" -lt 2 ]]; then
			echo "--platform requires a value" >&2
			exit 1
		fi
		PLATFORM_ARG="$(trim_value "$2")"
		shift 2
		;;
	--platform=*)
		PLATFORM_ARG="$(trim_value "${arg#--platform=}")"
		shift
		;;
	-*)
		show_help >&2
		exit 1
		;;
	*)
		echo "Unexpected argument: $1" >&2
		show_help >&2
		exit 1
		;;
	esac
done

if [[ -z "${LOCAL_REPO_ARG}" ]]; then
	echo "--repo / LOCAL_REPO must not be empty" >&2
	exit 1
fi
if [[ -z "${PLATFORM_ARG}" ]]; then
	echo "--platform / LOCAL_PLATFORM must not be empty" >&2
	exit 1
fi

echo "[build] Build gebruikt registry/tag-basis: ${LOCAL_REPO_ARG}"
echo "[build] Build gebruikt --platform: ${PLATFORM_ARG}"
echo "[build] Build gebruikt VERSION_RESTIC: ${VERSION_RESTIC}"

require_commands
cd_repo_root

if [[ ! -f "${VERSION_FILE}" ]]; then
	echo "Missing ${VERSION_FILE}" >&2
	exit 1
fi

image_version="$(read_image_version)"
if ! is_semver "${image_version}"; then
	echo "VERSION must contain a semver like 1.0.0; got ${image_version}" >&2
	exit 1
fi

RELEASE="${image_version}-${VERSION_RESTIC}-dev"

docker buildx build --no-cache --platform "${PLATFORM_ARG}" --push \
	--build-arg "RESTIC_BACKUP_HELPER_RELEASE=${RELEASE}" \
	-t "${LOCAL_REPO_ARG}:testing" \
	-t "${LOCAL_REPO_ARG}:${RELEASE}" \
	-f ./Dockerfile .

echo ""
echo "Pushed ${LOCAL_REPO_ARG}:testing  (RESTIC_BACKUP_HELPER_RELEASE=${RELEASE})"
