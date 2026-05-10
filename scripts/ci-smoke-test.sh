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

# Wait until entry.sh has finished restic snapshots/init (Running is true before init completes).
wait_for_restic_repository_ready() {
	local service="$1"
	local attempts="${2:-90}"
	local sleep_secs="${3:-2}"
	local i

	for ((i = 1; i <= attempts; i += 1)); do
		if docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
			sh -c 'test -f "${RESTIC_REPOSITORY:-/data/repo}/config"' 2>/dev/null; then
			log_info "Restic repository is initialized (${RESTIC_REPOSITORY:-/data/repo})"
			return 0
		fi
		sleep "${sleep_secs}"
	done

	log_crit "Restic repository did not become ready (missing config) within timeout"
	docker compose -f ci/docker-compose.smoke.yml logs --no-color "${service}" || true
	return 1
}

main() {
	local service="restic-smoke"
	local smoke_platform="${SMOKE_PLATFORM:-linux/amd64}"

	trap cleanup EXIT

	# Ensure hook stubs are executable for bind-mount (lost +x on some checkouts).
	chmod +x ./ci/smoke-hooks/*.sh

	log_info "Starting smoke stack (platform ${smoke_platform})"
	export DOCKER_DEFAULT_PLATFORM="${smoke_platform}"
	docker compose -f ci/docker-compose.smoke.yml up -d --build

	if ! wait_for_container_running "${service}"; then
		log_crit "Smoke startup failed"
		docker compose -f ci/docker-compose.smoke.yml logs --no-color || true
		exit 1
	fi

	if ! wait_for_restic_repository_ready "${service}"; then
		exit 1
	fi

	log_info "Seeding smoke volume (backup source + bisync dirs)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'mkdir -p /data/backup_src /data/sync_a /data/sync_b && printf "%s\n" smoke-ci > /data/backup_src/smoke.txt && printf "%s\n" bisync-a > /data/sync_a/a.txt'

	log_info "Checking restic binary"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" restic version

	log_info "Checking baked release metadata"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'test "${RESTIC_BACKUP_HELPER_RELEASE}" = "ci-smoke"'

	log_info "Running config-check"
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps "${service}" config-check

	log_info "Running backup (includes hooks + optional forget)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/backup

	log_info "Verifying snapshots exist"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'restic snapshots >/dev/null'

	log_info "Running repository check"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/check

	log_info "Running bisync (local pair)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/bisync

	log_info "Verifying bisync replicated file"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'test -f /data/sync_b/a.txt'

	log_info "Triggering cron.log rotation path"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'printf x >> /var/log/cron.log'
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/rotate_log

	log_info "Verifying rotation archive created"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'ls /var/log/cron_log_*.tar.gz >/dev/null'

	log_info "Smoke test passed (backup, check, bisync, rotate_log, hooks, forget policy)"
}

main "$@"
