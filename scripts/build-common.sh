#!/usr/bin/env bash
# Shared helpers for restic-backup-helper Docker builds (sourced by build.sh / build-testing.sh).

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_COMMON_DIR}/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

# Set by set_release_from_version for use by callers (image tag / build-arg).
RESTIC_NEW_RELEASE=""

# DOCKER_IMAGE_REPO, BUILD_PLATFORM en VERSION_RESTIC: géén defaults hier —
# die zouden apply_optional_env_file laten denken dat de shell variabelen al
# “user-export” zijn en daarmee build.env overschrijven. Defaults alleen aan het
# eind van apply_optional_env_file.

# Laadt één optioneel bestand (build.env of build-testing.env).
# Pad wordt doorgegeven door run_stable_build / run_testing_build.
# Precedence: niet-lege export vóór ./build.sh > env-bestand > defaults hieronder.
apply_optional_env_file() {
	local env_file="$1"
	local saved_repo saved_plat saved_restic
	local has_repo=0 has_plat=0 has_restic=0

	case ${DOCKER_IMAGE_REPO+x} in
	x)
		saved_repo="${DOCKER_IMAGE_REPO}"
		has_repo=1
		;;
	esac
	case ${BUILD_PLATFORM+x} in
	x)
		saved_plat="${BUILD_PLATFORM}"
		has_plat=1
		;;
	esac
	case ${VERSION_RESTIC+x} in
	x)
		saved_restic="${VERSION_RESTIC}"
		has_restic=1
		;;
	esac

	if [[ -f "${env_file}" ]]; then
		echo "[build] Env-bestand laden: ${env_file}"
		# shellcheck disable=SC1090
		source "${env_file}"
		DOCKER_IMAGE_REPO="${DOCKER_IMAGE_REPO//$'\r'/}"
		BUILD_PLATFORM="${BUILD_PLATFORM//$'\r'/}"
		VERSION_RESTIC="${VERSION_RESTIC//$'\r'/}"
	else
		echo "[build] Geen env-bestand (optioneel): ${env_file} — defaults uit dit script"
	fi

	# Alleen overschrijven als de shell een niet-lege waarde had (lege export mag env-bestand niet verliezen).
	if [[ "${has_repo}" -eq 1 ]] && [[ -n "${saved_repo}" ]]; then
		DOCKER_IMAGE_REPO="${saved_repo}"
	fi
	if [[ "${has_plat}" -eq 1 ]] && [[ -n "${saved_plat}" ]]; then
		BUILD_PLATFORM="${saved_plat}"
	fi
	if [[ "${has_restic}" -eq 1 ]] && [[ -n "${saved_restic}" ]]; then
		VERSION_RESTIC="${saved_restic}"
	fi

	DOCKER_IMAGE_REPO="${DOCKER_IMAGE_REPO:-marc0janssen/restic-backup-helper}"
	BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64,linux/arm64}"
	VERSION_RESTIC="${VERSION_RESTIC:-0.18.1}"
}

trim_value() {
	printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

show_build_usage() {
	local script_name="$1"
	cat <<EOF
Usage: ${script_name} [--docker-repo <namespace/name>] [--platform <platforms>] [--base <restic-tag>]
       ${script_name} --help

Options:
  --docker-repo <repo>  Docker image repository without tag.
  --platform <list>    docker buildx --platform value.
  --base <tag>         Restic base image tag, e.g. 0.18.1.
                       Special value 'newest' (alias 'latest') resolves to
                       the concrete version embedded in restic/restic:latest
                       so the published image tag and the Dockerfile FROM
                       never contain the literal 'newest' / 'latest'.
                       Special value 'prerelease' (aliases 'rc' / 'beta')
                       resolves to the newest Docker Hub restic/restic tag
                       that looks like a Restic rc/beta version.
                       The resolved tag is verified against Docker Hub before
                       the Dockerfile is patched; non-existent tags abort the
                       build instead of producing an image whose tag suffix
                       does not match the base actually used.

Precedence: CLI flags > non-empty exported variables > env file > defaults.
EOF
}

parse_common_build_args() {
	local script_name="$1"
	shift

	while [[ "$#" -gt 0 ]]; do
		local arg
		arg="$(trim_value "$1")"
		case "$1" in
		-h | --help)
			show_build_usage "${script_name}"
			exit 0
			;;
		--docker-repo)
			if [[ "$#" -lt 2 ]]; then
				echo "--docker-repo requires a value" >&2
				exit 1
			fi
			DOCKER_IMAGE_REPO="$(trim_value "$2")"
			shift 2
			;;
		--docker-repo=*)
			DOCKER_IMAGE_REPO="$(trim_value "${arg#--docker-repo=}")"
			shift
			;;
		--platform)
			if [[ "$#" -lt 2 ]]; then
				echo "--platform requires a value" >&2
				exit 1
			fi
			BUILD_PLATFORM="$(trim_value "$2")"
			shift 2
			;;
		--platform=*)
			BUILD_PLATFORM="$(trim_value "${arg#--platform=}")"
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
			echo "Unknown option: $1" >&2
			show_build_usage "${script_name}" >&2
			exit 1
			;;
		*)
			echo "Unexpected argument: $1" >&2
			show_build_usage "${script_name}" >&2
			exit 1
			;;
		esac
	done

	if [[ -z "${DOCKER_IMAGE_REPO}" ]]; then
		echo "--docker-repo / DOCKER_IMAGE_REPO must not be empty" >&2
		exit 1
	fi
	if [[ -z "${BUILD_PLATFORM}" ]]; then
		echo "--platform / BUILD_PLATFORM must not be empty" >&2
		exit 1
	fi
	if [[ -z "${VERSION_RESTIC}" ]]; then
		echo "--base / VERSION_RESTIC must not be empty" >&2
		exit 1
	fi
}

is_semver() {
	[[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Accepts restic-style version tags: 0.18.1, 0.18.2, optional pre-release
# suffix like 0.18.2-rc.1 or 0.18.2.1. Sentinels 'newest' / 'latest' must
# be resolved before this check; see finalize_restic_base_tag.
is_valid_restic_tag() {
	[[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]]
}

is_restic_prerelease_tag() {
	[[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+[-.]([Rr][Cc]|[Bb][Ee][Tt][Aa])[.-]?[0-9A-Za-z.]*$ ]]
}

# Runs the published restic/restic:latest image and parses its `version`
# subcommand for the concrete semver baked into the binary. Output shape:
#   restic 0.18.1 compiled with go1.23.5 on linux/amd64
# Pulls the image if missing (same network cost as the build itself).
resolve_newest_restic_tag() {
	local raw v
	if ! command -v docker >/dev/null 2>&1; then
		echo "Cannot resolve 'newest' / 'latest': docker is not on PATH." >&2
		exit 1
	fi
	if ! raw="$(docker run --rm restic/restic:latest version 2>/dev/null | head -n1)"; then
		echo "Cannot resolve 'newest' / 'latest': 'docker run --rm restic/restic:latest version' failed." >&2
		echo "Hint: check Docker daemon connectivity and that restic/restic:latest is pullable." >&2
		exit 1
	fi
	v="$(printf '%s\n' "${raw}" | awk '{print $2}')"
	if ! is_valid_restic_tag "${v}"; then
		echo "Cannot resolve 'newest' / 'latest': unexpected output from 'restic version': '${raw}'" >&2
		exit 1
	fi
	printf '%s' "${v}"
}

# Reads Docker Hub tags and returns the newest tag that looks like an rc/beta
# Restic tag (e.g. 0.19.0-rc.1). This intentionally resolves against image tags
# rather than GitHub releases so --base never points at a non-pullable base.
resolve_prerelease_restic_tag() {
	local raw v curl_args
	if ! command -v curl >/dev/null 2>&1; then
		echo "Cannot resolve 'prerelease' / 'rc' / 'beta': curl is not on PATH." >&2
		exit 1
	fi
	curl_args=(
		-fsSL
		-H "Accept: application/json"
		-H "User-Agent: restic-backup-helper-build"
	)
	raw="$(
		curl "${curl_args[@]}" \
			"https://hub.docker.com/v2/repositories/restic/restic/tags?page_size=100"
	)" || {
		echo "Cannot resolve 'prerelease' / 'rc' / 'beta': Docker Hub tags API request failed." >&2
		echo "Hint: check network access and that https://hub.docker.com/r/restic/restic/tags is reachable." >&2
		exit 1
	}
	v="$(
		printf '%s' "${raw}" | tr '\n' ' ' | sed -e 's/"name"/\
"name"/g' | awk '
			/"name"[[:space:]]*:/ {
				tag = $0
				sub(/^.*"name":[[:space:]]*"/, "", tag)
				sub(/".*$/, "", tag)
				sub(/^v/, "", tag)
				if (tag ~ /^[0-9]+\.[0-9]+\.[0-9]+[-.](rc|RC|beta|BETA)[.-]?[0-9A-Za-z.]*$/) {
					print tag
					exit
				}
			}
		'
	)"
	if ! is_restic_prerelease_tag "${v}"; then
		echo "Cannot resolve 'prerelease' / 'rc' / 'beta': no rc/beta tag found in the first page of Docker Hub restic/restic tags." >&2
		echo "Hint: pass a concrete published tag explicitly, e.g. --base 0.19.0-rc.1, if Docker Hub has one." >&2
		exit 1
	fi
	printf '%s' "${v}"
}

# Verifies that restic/restic:<VERSION_RESTIC> is actually published before any
# consumer (Dockerfile FROM, image tag, build-arg) bakes it in. Without this
# check, a typo'd or future-dated --base value would still produce a tagged
# image because some flows (e.g. build-testing-local.sh) leave Dockerfile FROM
# untouched, so buildx silently keeps using the pre-existing base while the
# published image tag advertises a different version. Uses
# `docker buildx imagetools inspect` because it queries the registry without
# pulling layers and works on the buildx that the build flow already requires.
verify_restic_base_tag_exists() {
	local tag="${VERSION_RESTIC:-}"

	if ! command -v docker >/dev/null 2>&1; then
		echo "Cannot verify restic base tag: docker is not on PATH." >&2
		exit 1
	fi
	echo "[build] Verifying restic/restic:${tag} exists on Docker Hub..."
	if ! docker buildx imagetools inspect "restic/restic:${tag}" >/dev/null 2>&1; then
		echo "Restic base image tag 'restic/restic:${tag}' does not exist (or is not reachable from Docker Hub)." >&2
		echo "Refusing to build — would produce a tagged image whose --base does not match what is actually pullable." >&2
		echo "Pass an existing tag, e.g. --base 0.18.1, or --base newest to auto-resolve restic/restic:latest." >&2
		exit 1
	fi
}

# Materialises VERSION_RESTIC into a concrete semver tag before any consumer
# (Dockerfile FROM, image tag, build-arg) reads it. Rejects bogus values like
# "newest-typo" so they never end up in published artefacts as "2.5.0-<typo>-dev".
finalize_restic_base_tag() {
	local original resolved
	case "${VERSION_RESTIC:-}" in
	newest | latest)
		original="${VERSION_RESTIC}"
		echo "[build] Resolving VERSION_RESTIC=${original} via restic/restic:latest..."
		if ! resolved="$(resolve_newest_restic_tag)"; then
			# resolve_newest_restic_tag already printed a clear error to stderr.
			exit 1
		fi
		VERSION_RESTIC="${resolved}"
		echo "[build] Resolved VERSION_RESTIC=${original} -> ${VERSION_RESTIC}"
		;;
	prerelease | rc | beta)
		original="${VERSION_RESTIC}"
		echo "[build] Resolving VERSION_RESTIC=${original} via Docker Hub restic/restic tags..."
		if ! resolved="$(resolve_prerelease_restic_tag)"; then
			# resolve_prerelease_restic_tag already printed a clear error to stderr.
			exit 1
		fi
		VERSION_RESTIC="${resolved}"
		echo "[build] Resolved VERSION_RESTIC=${original} -> ${VERSION_RESTIC}"
		;;
	esac

	if ! is_valid_restic_tag "${VERSION_RESTIC:-}"; then
		echo "VERSION_RESTIC must look like a restic version (e.g. 0.18.1); got '${VERSION_RESTIC:-}'." >&2
		echo "Pass --base 0.18.2, set VERSION_RESTIC=0.18.2, use --base newest for restic/restic:latest, or use --base prerelease for the newest rc/beta." >&2
		exit 1
	fi

	verify_restic_base_tag_exists
}

read_image_version() {
	sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "${VERSION_FILE}"
}

require_commands() {
	local c
	for c in docker sed; do
		if ! command -v "${c}" >/dev/null 2>&1; then
			echo "Missing required command: ${c}" >&2
			exit 1
		fi
	done
}

cd_repo_root() {
	cd "${REPO_ROOT}" || exit 1
}

# Optional SBOM generation against the pushed image. Gated by SBOM=ON so
# unset/local builds stay fast; logs and skips when syft is not installed so
# CI matrices that don't pre-install syft don't break the publish flow.
# Args:
#   $1 — fully-qualified image reference, e.g. repo/name:1.16.0-0.18.1
emit_sbom() {
	local image_ref="$1"
	local out_dir base

	case "${SBOM:-}" in
	[Oo][Nn] | 1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) ;;
	*)
		echo "[build] SBOM generation disabled (set SBOM=ON to enable)"
		return 0
		;;
	esac

	if ! command -v syft >/dev/null 2>&1; then
		echo "[build] SBOM=ON but 'syft' is not on PATH; skipping. Install via: https://github.com/anchore/syft#installation"
		return 0
	fi

	out_dir="${SBOM_DIR:-${REPO_ROOT}/sbom}"
	mkdir -p "${out_dir}"
	base="${out_dir}/restic-backup-helper-${RESTIC_NEW_RELEASE}"

	echo "[build] Generating SBOM for ${image_ref} via syft -> ${base}.{spdx.json,cyclonedx.json}"
	syft "${image_ref}" \
		-o "spdx-json=${base}.spdx.json" \
		-o "cyclonedx-json=${base}.cyclonedx.json"
	echo "[build] SBOM written:"
	ls -1 "${base}".*.json
}

patch_dockerfile_restic_base() {
	local dockerfile="${REPO_ROOT}/Dockerfile"
	sed -i.bak "s#restic/restic:.*#restic/restic:${VERSION_RESTIC}#" "${dockerfile}"
	rm -f "${dockerfile}.bak"
}

# Args: optional dev suffix — "-dev" for testing train, empty for stable.
# Does not modify VERSION or README; tag is <semver from VERSION>-<VERSION_RESTIC><suffix>.
set_release_from_version() {
	local dev_suffix="${1:-}"
	local image_version

	image_version="$(read_image_version)"
	if ! is_semver "${image_version}"; then
		echo "VERSION must contain a semver like 1.0.0 (got '${image_version}')" >&2
		exit 1
	fi

	RESTIC_NEW_RELEASE="${image_version}-${VERSION_RESTIC}${dev_suffix}"
}

run_stable_build() {
	case "${1:-}" in
	-h | --help)
		show_build_usage "./build.sh"
		exit 0
		;;
	esac

	# Hier: ./build.env (repo root)
	apply_optional_env_file "${REPO_ROOT}/build.env"
	parse_common_build_args "./build.sh" "$@"
	require_commands
	finalize_restic_base_tag
	echo "[build] Build gebruikt DOCKER_IMAGE_REPO=${DOCKER_IMAGE_REPO}"
	echo "[build] Build gebruikt BUILD_PLATFORM=${BUILD_PLATFORM}"
	echo "[build] Build gebruikt VERSION_RESTIC=${VERSION_RESTIC}"
	cd_repo_root
	if [[ ! -f "${VERSION_FILE}" ]]; then
		echo "Missing ${VERSION_FILE}" >&2
		exit 1
	fi

	set_release_from_version ""

	patch_dockerfile_restic_base

	docker buildx build --no-cache --platform "${BUILD_PLATFORM}" --push \
		--build-arg "RESTIC_BACKUP_HELPER_RELEASE=${RESTIC_NEW_RELEASE}" \
		-t "${DOCKER_IMAGE_REPO}:${RESTIC_NEW_RELEASE}" \
		-t "${DOCKER_IMAGE_REPO}:latest" \
		-f ./Dockerfile .

	docker pushrm --file README-containers.md "${DOCKER_IMAGE_REPO}:latest"

	emit_sbom "${DOCKER_IMAGE_REPO}:${RESTIC_NEW_RELEASE}"

	echo ""
	echo "Docker image ${RESTIC_NEW_RELEASE} built"
}

run_testing_build() {
	case "${1:-}" in
	-h | --help)
		show_build_usage "./build-testing.sh"
		exit 0
		;;
	esac

	# Hier: ./build-testing.env (repo root)
	apply_optional_env_file "${REPO_ROOT}/build-testing.env"
	parse_common_build_args "./build-testing.sh" "$@"
	require_commands
	finalize_restic_base_tag
	echo "[build] Build gebruikt DOCKER_IMAGE_REPO=${DOCKER_IMAGE_REPO}"
	echo "[build] Build gebruikt BUILD_PLATFORM=${BUILD_PLATFORM}"
	echo "[build] Build gebruikt VERSION_RESTIC=${VERSION_RESTIC}"
	cd_repo_root
	if [[ ! -f "${VERSION_FILE}" ]]; then
		echo "Missing ${VERSION_FILE}" >&2
		exit 1
	fi

	set_release_from_version "-dev"

	patch_dockerfile_restic_base

	docker buildx build --no-cache --platform "${BUILD_PLATFORM}" --push \
		--build-arg "RESTIC_BACKUP_HELPER_RELEASE=${RESTIC_NEW_RELEASE}" \
		-t "${DOCKER_IMAGE_REPO}:${RESTIC_NEW_RELEASE}" \
		-t "${DOCKER_IMAGE_REPO}:develop" \
		-f ./Dockerfile .

	docker pushrm --file README-containers.md "${DOCKER_IMAGE_REPO}:develop"

	emit_sbom "${DOCKER_IMAGE_REPO}:${RESTIC_NEW_RELEASE}"

	echo ""
	echo "Docker image ${RESTIC_NEW_RELEASE} built"
}
