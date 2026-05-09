#!/usr/bin/env bash
set -Eeuo pipefail

log_info() {
	echo "[info] [smoke] $*"
}

log_crit() {
	echo "[crit] [smoke] $*" >&2
}

cleanup() {
	if [[ "${KEEP_SMOKE_STACK:-no}" == "yes" ]]; then
		log_info "Keeping smoke stack up (KEEP_SMOKE_STACK=yes)"
		return 0
	fi

	log_info "Stopping smoke stack"
	docker compose -f ci/docker-compose.smoke.yml down -v --remove-orphans >/dev/null 2>&1 || true
}

wait_for_container_running() {
	local service="$1"
	local attempts="${2:-45}"
	local sleep_secs="${3:-2}"
	local cid=""
	local i

	for ((i = 1; i <= attempts; i += 1)); do
		cid="$(docker compose -f ci/docker-compose.smoke.yml ps -q "${service}" 2>/dev/null || true)"
		if [[ -n "${cid}" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null || true)" == "true" ]]; then
			log_info "Container ${service} is running"
			return 0
		fi
		sleep "${sleep_secs}"
	done

	log_crit "Container ${service} did not reach running state in time"
	return 1
}

main() {
	local service="restic-smoke"
	local smoke_platform="${SMOKE_PLATFORM:-linux/amd64}"

	trap cleanup EXIT

	log_info "Starting smoke stack (platform ${smoke_platform})"
	export DOCKER_DEFAULT_PLATFORM="${smoke_platform}"
	docker compose -f ci/docker-compose.smoke.yml up -d --build

	if ! wait_for_container_running "${service}"; then
		log_crit "Smoke startup failed"
		docker compose -f ci/docker-compose.smoke.yml logs --no-color || true
		exit 1
	fi

	log_info "Checking restic binary"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" restic version

	log_info "Checking baked release metadata"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'test "${RESTIC_BACKUP_HELPER_RELEASE}" = "ci-smoke"'

	log_info "Running config-check"
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps "${service}" config-check

	log_info "Smoke test passed"
}

main "$@"
