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
Usage: build-testing-local.sh [--repo <host:port/name>] [--platform <platforms>] [--base <restic-tag>]
       build-testing-local.sh --help

Local/private-registry variant of build-testing.sh.

--base accepts a concrete Restic version (e.g. 0.18.1, 0.18.2-rc.1),
'newest' (alias 'latest') or 'prerelease' (aliases 'rc' / 'beta'). Sentinels
are resolved before the tag is computed, so the published image tag never
contains the literal keyword. The tag is checked for existence on Docker Hub
before any files are mutated, and the Dockerfile FROM line is patched so the
pushed image always matches the version baked into the tag.

Builds ./Dockerfile with the same layout as production testing images. Does not
increment VERSION and does not modify README.md. The image gets release metadata
via Docker build-arg RESTIC_BACKUP_HELPER_RELEASE (see Dockerfile).

Optional env file:
  build-testing-local.env (copy from build-testing-local.env.example)

Defaults (override with LOCAL_REPO / LOCAL_PLATFORM or CLI):
  repo:     192.168.1.1:5000/restic-backup-helper
  platform: linux/amd64

Precedence (hoog → laag): CLI --repo / --platform / --base → niet-lege export
in je shell → build-testing-local.env → defaults in dit script / scripts/build-common.sh.

Environment:
  VERSION_RESTIC   Same as build-testing.sh (default 0.18.1). The build patches
                   Dockerfile FROM to match this value, so they never drift.
  SBOM             Set to ON to generate SPDX + CycloneDX SBOMs of the pushed
                   image via syft (requires syft on PATH). Default: off.
  SBOM_DIR         Output directory for SBOM artifacts. Default: ./sbom/local
                   so private-registry SBOMs do not overwrite the Docker Hub
                   testing/stable SBOMs (which default to ./sbom/).

Docker tags pushed:
  <LOCAL_REPO>:develop
  <LOCAL_REPO>:<release>            e.g. 2.9.0-0.18.1-dev

Examples:
  ./build-testing-local.sh
  ./build-testing-local.sh --repo 192.168.1.10:5000/restic-backup-helper --platform linux/arm64
  ./build-testing-local.sh --base 0.18.2
  ./build-testing-local.sh --base prerelease
EOF
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
	--base)
		if [[ "$#" -lt 2 ]]; then
			echo "--base requires a value" >&2
			exit 1
		fi
		VERSION_RESTIC="$(trim_value "$2")"
		shift 2
		;;
	--base=*)
		VERSION_RESTIC="$(trim_value "${arg#--base=}")"
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
if [[ -z "${VERSION_RESTIC}" ]]; then
	echo "--base / VERSION_RESTIC must not be empty" >&2
	exit 1
fi

require_commands
finalize_restic_base_tag

echo "[build] Build gebruikt registry/tag-basis: ${LOCAL_REPO_ARG}"
echo "[build] Build gebruikt --platform: ${PLATFORM_ARG}"
echo "[build] Build gebruikt VERSION_RESTIC: ${VERSION_RESTIC}"

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
# emit_sbom() (in scripts/build-common.sh) reads RESTIC_NEW_RELEASE for the
# SBOM filename; expose RELEASE under that name so the same helper works for
# build.sh, build-testing.sh and this private-registry variant.
RESTIC_NEW_RELEASE="${RELEASE}"
# Keep private-registry SBOMs out of the Docker Hub ./sbom/ pool by default
# so contributors who run both build flows on the same machine don't clobber
# each other's artifacts. Honours an explicit SBOM_DIR override.
export SBOM_DIR="${SBOM_DIR:-${REPO_ROOT}/sbom/local}"

# Keep Dockerfile FROM in sync with VERSION_RESTIC so the tag suffix
# (image_version-VERSION_RESTIC-dev) always matches what is actually pulled as
# the base. Without this, --base <new-tag> would silently keep building against
# the pre-existing Dockerfile FROM while still tagging the image as the new
# version. See finalize_restic_base_tag for the existence check that prevents
# patching the Dockerfile to a non-existent tag.
patch_dockerfile_restic_base

docker buildx build --no-cache --platform "${PLATFORM_ARG}" --push \
	--build-arg "RESTIC_BACKUP_HELPER_RELEASE=${RELEASE}" \
	-t "${LOCAL_REPO_ARG}:develop" \
	-t "${LOCAL_REPO_ARG}:${RELEASE}" \
	-f ./Dockerfile .

emit_sbom "${LOCAL_REPO_ARG}:${RELEASE}"

echo ""
echo "Pushed ${LOCAL_REPO_ARG}:develop and ${LOCAL_REPO_ARG}:${RELEASE} (RESTIC_BACKUP_HELPER_RELEASE=${RELEASE})"
