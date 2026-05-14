#!/bin/sh
set -eu

log_info() {
	echo "[info] [quality] $*"
}

log_crit() {
	echo "[crit] [quality] $*" >&2
}

require_cmd() {
	cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		log_crit "Missing required command: ${cmd}"
		exit 1
	fi
}

is_truthy() {
	value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
	case "${value}" in
	yes | true | 1)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

run_conflict_marker_check() {
	log_info "Checking repository for unresolved merge conflict markers"
	if git grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- . >/dev/null 2>&1; then
		log_crit "Found unresolved merge conflict markers in tracked files"
		git grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- .
		exit 1
	fi
}

run_readme_size_guard() {
	readme_path="README-containers.md"
	max_bytes="25000"
	readme_bytes="$(wc -c <"${readme_path}" | tr -d '[:space:]')"
	log_info "Validating ${readme_path} size: ${readme_bytes}/${max_bytes} bytes"
	if [ "${readme_bytes}" -gt "${max_bytes}" ]; then
		log_crit "${readme_path} exceeds Docker Hub limit (${readme_bytes} > ${max_bytes} bytes)"
		exit 1
	fi
}

run_version_metadata_guard() {
	required_files="VERSION CHANGELOG.md README.md README-containers.md"
	changed_files="$(mktemp)"
	commit_range="${CI_CHANGED_FILES_RANGE:-${CI_CONVENTIONAL_COMMIT_RANGE:-}}"
	has_non_metadata_change="0"
	missing_required="0"
	required_file=""

	if [ -n "${commit_range}" ] && git rev-parse "${commit_range}" >/dev/null 2>&1; then
		log_info "Collecting changed files from range: ${commit_range}"
		git diff --name-only "${commit_range}" >"${changed_files}"
	elif git rev-parse HEAD~20 >/dev/null 2>&1; then
		log_info "Collecting changed files from HEAD~20..HEAD fallback"
		git diff --name-only HEAD~20..HEAD >"${changed_files}"
	else
		root_sha="$(git rev-list --max-parents=0 HEAD 2>/dev/null || true)"
		log_info "Collecting changed files from root..HEAD fallback"
		git diff --name-only "${root_sha}"..HEAD >"${changed_files}"
	fi

	if [ ! -s "${changed_files}" ]; then
		log_info "No changed files detected for version metadata guard; skipping"
		rm -f "${changed_files}"
		return
	fi

	while IFS= read -r changed_file; do
		case "${changed_file}" in
		"" | VERSION | CHANGELOG.md | README.md | README-containers.md)
			continue
			;;
		*)
			has_non_metadata_change="1"
			;;
		esac
	done <"${changed_files}"

	if [ "${has_non_metadata_change}" = "1" ]; then
		for required_file in ${required_files}; do
			if ! grep -Fxq "${required_file}" "${changed_files}"; then
				log_crit "Versioning guard: '${required_file}' must be updated when non-metadata files change"
				missing_required="1"
			fi
		done
	fi

	version_value="$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' VERSION)"
	restic_base="$(sed -n 's/^FROM restic\/restic://p' Dockerfile | head -n1)"
	if [ -z "${restic_base}" ]; then
		log_crit "Versioning guard: could not read FROM restic/restic tag in Dockerfile"
		rm -f "${changed_files}"
		exit 1
	fi
	expected_release="${version_value}-${restic_base}"

	readme_release="$(sed -n 's/^release: //p' README.md | head -n1)"
	container_readme_release="$(sed -n 's/^release: //p' README-containers.md | head -n1)"

	if [ "${expected_release}" != "${readme_release}" ]; then
		log_crit "Versioning guard: README.md release '${readme_release}' does not match VERSION+Dockerfile (${expected_release})"
		missing_required="1"
	fi
	if [ "${expected_release}" != "${container_readme_release}" ]; then
		log_crit "Versioning guard: README-containers.md release '${container_readme_release}' does not match (${expected_release})"
		missing_required="1"
	fi

	if [ "${missing_required}" != "0" ]; then
		rm -f "${changed_files}"
		exit 1
	fi
	rm -f "${changed_files}"
}

run_yamllint() {
	yaml_tmp="$(mktemp)"
	# Helm files under charts/*/templates/ are Go-templated YAML; yamllint cannot parse them.
	git ls-files | grep -E '\.(yml|yaml)$' | grep -v '^\.nzbgetvpn-reference/' | grep -v '^charts/.*/templates/' >"${yaml_tmp}" || true

	if [ ! -s "${yaml_tmp}" ]; then
		log_info "No YAML files matched for yamllint"
		rm -f "${yaml_tmp}"
		return 0
	fi

	log_info "Running yamllint on tracked YAML files"
	if command -v yamllint >/dev/null 2>&1; then
		yamllint_impl=1
	elif python3 -m yamllint -h >/dev/null 2>&1; then
		yamllint_impl=2
	else
		log_crit "Missing yamllint (apt install yamllint, or: pip install yamllint and ensure python3 -m yamllint works)"
		rm -f "${yaml_tmp}"
		exit 1
	fi

	while IFS= read -r yaml_file; do
		[ -z "${yaml_file}" ] && continue
		case "${yamllint_impl}" in
		1)
			yamllint -c .yamllint "${yaml_file}"
			;;
		2)
			python3 -m yamllint -c .yamllint "${yaml_file}"
			;;
		esac
	done <"${yaml_tmp}"
	rm -f "${yaml_tmp}"
}

run_actionlint() {
	require_cmd actionlint
	log_info "Running actionlint on .github/workflows"
	actionlint
}

run_hadolint() {
	log_info "Running hadolint on Dockerfile"
	if command -v hadolint >/dev/null 2>&1; then
		hadolint --config .hadolint.yaml Dockerfile
		return 0
	fi
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		docker run --rm -i \
			-v "$(pwd)/.hadolint.yaml:/.hadolint.yaml:ro" \
			-v "$(pwd)/Dockerfile:/Dockerfile:ro" \
			hadolint/hadolint hadolint --config /.hadolint.yaml /Dockerfile
		return 0
	fi
	log_crit "Missing hadolint (install release binary or Docker with image hadolint/hadolint)"
	exit 1
}

run_compose_config_validate() {
	if ! command -v docker >/dev/null 2>&1; then
		log_info "Skipping Docker Compose config validation (docker not installed)"
		return 0
	fi
	if ! docker info >/dev/null 2>&1; then
		log_info "Skipping Docker Compose config validation (docker daemon unavailable)"
		return 0
	fi

	log_info "Validating Docker Compose files (docker compose config -q)"
	docker compose -f ci/docker-compose.smoke.yml config -q

	(
		export RESTIC_REPOSITORY=ci-quality-dummy
		export RESTIC_PASSWORD=ci-quality-dummy
		export RESTIC_TAG=ci-quality-dummy
		docker compose -f scripts/docker-compose.yml config -q
	)
}

run_conventional_commit_lint() {
	default_pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?(!)?: .+'
	commit_pattern="${CI_CONVENTIONAL_COMMIT_PATTERN:-${default_pattern}}"
	commit_range="${CI_CONVENTIONAL_COMMIT_RANGE:-HEAD~20..HEAD}"
	failed="0"

	log_info "Running optional conventional commit lint on range: ${commit_range}"
	if ! git rev-parse "${commit_range}" >/dev/null 2>&1; then
		log_crit "Invalid CI_CONVENTIONAL_COMMIT_RANGE: ${commit_range}"
		exit 1
	fi

	while IFS= read -r subject; do
		if [ -z "${subject}" ]; then
			continue
		fi
		if ! printf '%s\n' "${subject}" | grep -Eq "${commit_pattern}"; then
			log_crit "Non-conventional commit subject: ${subject}"
			failed="1"
		fi
	done <<EOF
$(git log --format=%s "${commit_range}")
EOF

	if [ "${failed}" != "0" ]; then
		log_crit "Conventional commit lint failed; adjust subjects or pattern/range overrides"
		exit 1
	fi
}

main() {
	file_list="$(mktemp)"
	trap 'rm -f "${file_list}"' EXIT INT TERM
	default_shellcheck_excludes="SC1007,SC1091,SC2002,SC2016,SC2027,SC2034,SC2086,SC2154,SC2236"

	require_cmd git
	require_cmd bash
	require_cmd shellcheck
	require_cmd shfmt

	run_conflict_marker_check
	run_readme_size_guard
	run_version_metadata_guard

	run_yamllint
	run_actionlint
	run_hadolint
	run_compose_config_validate

	log_info "Collecting tracked shell scripts"
	git ls-files "*.sh" >"${file_list}"
	if [ ! -s "${file_list}" ]; then
		log_crit "No tracked *.sh files found"
		exit 1
	fi

	log_info "Running syntax checks on all scripts"
	while IFS= read -r file; do
		shebang="$(sed -n '1p' "${file}")"
		case "${shebang}" in
		*"bash"*)
			bash -n "${file}"
			;;
		*)
			sh -n "${file}"
			;;
		esac
	done <"${file_list}"

	log_info "Running shellcheck"
	if [ "${SHELLCHECK_EXCLUDES+x}" = "x" ]; then
		shellcheck_excludes="${SHELLCHECK_EXCLUDES}"
	else
		shellcheck_excludes="${default_shellcheck_excludes}"
	fi

	if [ -n "${shellcheck_excludes}" ]; then
		log_info "Using shellcheck baseline excludes: ${shellcheck_excludes}"
		# shellcheck disable=SC2046
		shellcheck -e "${shellcheck_excludes}" $(cat "${file_list}")
	else
		log_info "Running shellcheck in strict mode (no excludes)"
		# shellcheck disable=SC2046
		shellcheck $(cat "${file_list}")
	fi

	log_info "Running shfmt --diff"
	# shellcheck disable=SC2046
	shfmt --diff $(cat "${file_list}")

	log_info "README-containers byte count (Docker Hub readme limit reminder)"
	wc -c README-containers.md
	git status --short

	if is_truthy "${CI_CONVENTIONAL_COMMIT_LINT:-}"; then
		run_conventional_commit_lint
	else
		log_info "Skipping conventional commit lint (set CI_CONVENTIONAL_COMMIT_LINT=true to enable)"
	fi

	log_info "Quality checks passed"
}

main "$@"
