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

is_semver() {
	[[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
	# Hier: ./build.env (repo root)
	apply_optional_env_file "${REPO_ROOT}/build.env"
	echo "[build] Build gebruikt DOCKER_IMAGE_REPO=${DOCKER_IMAGE_REPO}"
	echo "[build] Build gebruikt BUILD_PLATFORM=${BUILD_PLATFORM}"
	echo "[build] Build gebruikt VERSION_RESTIC=${VERSION_RESTIC}"
	require_commands
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

	echo ""
	echo "Docker image ${RESTIC_NEW_RELEASE} built"
}

run_testing_build() {
	# Hier: ./build-testing.env (repo root)
	apply_optional_env_file "${REPO_ROOT}/build-testing.env"
	echo "[build] Build gebruikt DOCKER_IMAGE_REPO=${DOCKER_IMAGE_REPO}"
	echo "[build] Build gebruikt BUILD_PLATFORM=${BUILD_PLATFORM}"
	echo "[build] Build gebruikt VERSION_RESTIC=${VERSION_RESTIC}"
	require_commands
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

	echo ""
	echo "Docker image ${RESTIC_NEW_RELEASE} built"
}
