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

	log_info "Seeding smoke volume (backup source + replicate dirs)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'mkdir -p /data/backup_src /data/sync_a /data/sync_b && printf "%s\n" smoke-ci > /data/backup_src/smoke.txt && printf "%s\n" bisync-a > /data/sync_a/a.txt'

	log_info "Checking restic binary"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" restic version

	log_info "Checking baked release metadata"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'test "${RESTIC_BACKUP_HELPER_RELEASE}" = "ci-smoke"'

	log_info "Running config-check"
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps "${service}" config-check

	log_info "Running config-check --json (schema + exit_code assertions)"
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps "${service}" \
		config-check --json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema"] == "restic-backup-helper.config-check/1", d
assert d["command"] == "config-check"
assert d["exit_code"] == 0 and d["errors"] == 0, d
keys = {c["key"] for c in d["checks"]}
for required in ("RESTIC_REPOSITORY", "RESTIC_PASSWORD", "RESTIC_TAG", "BACKUP_PATHS"):
    assert required in keys, (required, keys)
print("[smoke] config-check --json ok: checks={} warnings={}".format(len(d["checks"]), d["warnings"]))
'

	log_info "Running cron-list (env-preview mode via compose run)"
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps "${service}" cron-list

	log_info "Running backup (includes hooks + optional forget)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/backup

	log_info "Verifying snapshots exist"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'restic snapshots >/dev/null'

	log_info "Running repository check"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/check

	log_info "Running cron-list (rendered crontab inside long-running container)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/cron-list

	log_info "Running doctor --json (schema + sections + repository_probe ok)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/doctor --json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema"] == "restic-backup-helper.doctor/1", d
assert d["command"] == "doctor"
assert d["exit_code"] == 0 and d["errors"] == 0, d
for section in ("runtime", "environment", "repository_probe", "replicate", "hooks", "recent_json", "checks"):
    assert section in d, section
assert d["repository_probe"]["status"] == "ok", d["repository_probe"]
# Every known last-*.json is enumerated, even when missing.
assert len(d["recent_json"]) == 14, d["recent_json"]
print("[smoke] doctor --json ok: checks={} warnings={}".format(len(d["checks"]), d["warnings"]))
'

	log_info "Running replicate (local pair, bisync mode)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/replicate

	log_info "Verifying replicate copied file"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'test -f /data/sync_b/a.txt'

	log_info "Running sources-report (pre-flight source inventory)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/sources-report
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-sources-report.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "sources-report", d
assert d["exit_code"] == 0, d
assert int(d.get("sources_count", 0)) >= 1, d
assert int(d.get("total_files", 0)) >= 1, d
print("[smoke] sources-report JSON ok: sources_count={} total_files={} total_bytes={}".format(
    d.get("sources_count"), d.get("total_files"), d.get("total_bytes")))
'

	log_info "Running forget-preview (host+tag scoped dry-run)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/forget-preview
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-forget-preview.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "forget-preview", d
assert d["exit_code"] == 0, d
print("[smoke] forget-preview JSON ok")
'

	log_info "Running init-repo --dry-run --yes (existing repo path → exit 0, repo_existed=true)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/init-repo --dry-run --yes
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-init-repo.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "init-repo", d
assert d["exit_code"] == 0, d
assert str(d.get("dry_run")) == "ON", d
assert str(d.get("repo_existed")) == "true", d
print("[smoke] init-repo --dry-run JSON ok: repo_existed={}".format(d.get("repo_existed")))
'

	log_info "Running notify-test --all --dry-run (ephemeral MAILX_RCPT / WEBHOOK_URL)"
	# Forge a configured-targets env just for this invocation; --dry-run skips
	# the actual mail / curl, so no external delivery is attempted.
	docker compose -f ci/docker-compose.smoke.yml exec -T \
		-e MAILX_RCPT=ops@smoke.invalid \
		-e WEBHOOK_URL=https://webhook.smoke.invalid/test \
		"${service}" /bin/notify-test --all --dry-run
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-notify-test.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "notify-test", d
assert d["exit_code"] == 0, d
assert str(d.get("dry_run")) == "ON", d
assert d.get("mail_result") == "dry-run", d
assert d.get("webhook_result") == "dry-run", d
print("[smoke] notify-test --dry-run JSON ok: mail={} webhook={}".format(d.get("mail_result"), d.get("webhook_result")))
'

	log_info "Running restore --dry-run --yes (latest snapshot → /tmp/restore-smoke)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'mkdir -p /tmp/restore-smoke && /bin/restore --dry-run --yes --target /tmp/restore-smoke'
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-restore.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "restore", d
assert d["exit_code"] == 0, d
# restore.sh records dry_run as the string "ON"/"OFF" (consistent with
# other helpers); accept either string or bool for forward-compat.
dry = d.get("dry_run")
assert dry in ("ON", True), d
print("[smoke] restore --dry-run JSON ok: target={}".format(d.get("target")))
'

	log_info "Running snapshot-export --dry-run (latest snapshot, no archive written)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/snapshot-export --dry-run
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-snapshot-export.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "snapshot-export", d
assert d["exit_code"] == 0, d
dry = d.get("dry_run")
assert dry in ("ON", True), d
# snapshot-export records the planned archive path even in dry-run; we
# only care that it did NOT actually create a file (which is verified
# implicitly by exit_code==0 and dry_run=="ON" together).
print("[smoke] snapshot-export --dry-run JSON ok: archive={}".format(d.get("archive")))
'

	log_info "Running restore-test (canary checksum + auto tempdir cleanup)"
	# Pre-compute the SHA-256 of the seeded canary file *inside* the container
	# so the rehearsal asserts the bytes restored by restic match the bytes
	# that were originally backed up. The canary path is the snapshot-
	# absolute path (BACKUP_ROOT_DIR=/data/backup_src, file smoke.txt).
	canary_sha="$(docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" sha256sum /data/backup_src/smoke.txt | awk '{print $1}')"
	if [[ -z "${canary_sha}" ]]; then
		log_crit "Could not compute canary sha256 for smoke restore-test"
		exit 1
	fi
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		/bin/restore-test --min-files 1 --canary "/data/backup_src/smoke.txt=${canary_sha}"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-restore-test.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "restore-test", d
assert d["exit_code"] == 0, d
assert d.get("verification") == "passed", d
assert int(d.get("files_restored", 0)) >= 1, d
# Seeded canary smoke.txt is "smoke-ci\n" = 9 bytes; restore-test counts
# the bytes that actually landed on disk, so this should be > 0.
assert int(d.get("bytes_restored", 0)) > 0, d
assert int(d.get("min_files", 0)) == 1, d
assert d.get("min_files_met") in ("true", True), d
assert int(d.get("canary_total", 0)) == 1, d
assert int(d.get("canary_passed", 0)) == 1, d
assert int(d.get("canary_failed", 0)) == 0, d
assert d.get("target_autotmp") == "ON", d
assert d.get("cleanup_status") == "cleaned", d
results = d.get("canary_results") or []
assert len(results) == 1 and results[0]["status"] == "passed", results
print("[smoke] restore-test JSON ok: files={} canaries={}/{} cleanup={}".format(
    d.get("files_restored"), d.get("canary_passed"), d.get("canary_total"), d.get("cleanup_status")))
'

	log_info "Running restore-test --dry-run (no verification, no tempdir mutation)"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/restore-test --dry-run
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		cat /var/log/last-restore-test.json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["job"] == "restore-test", d
assert d["exit_code"] == 0, d
assert d.get("dry_run") == "ON", d
assert d.get("verification") == "skipped", d
print("[smoke] restore-test --dry-run JSON ok: verification={}".format(d.get("verification")))
'

	log_info "Testing RESTIC_REPOSITORY_FILE precedence (file wins over baked default)"
	# Seed the URL file inside the container (volume is shared across compose
	# exec / run on the same project). First non-blank, non-comment line wins.
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'printf "%s\n%s\n" "# Repo URL for smoke RESTIC_REPOSITORY_FILE test" "/data/repo" > /data/repo.url'
	# Override RESTIC_REPOSITORY to empty so the resolver promotes
	# RESTIC_REPOSITORY_FILE without the dual-set warning fighting the test.
	# config-check --json must succeed and the resolved URL must be /data/repo.
	docker compose -f ci/docker-compose.smoke.yml run --rm --no-deps \
		-e RESTIC_REPOSITORY= \
		-e RESTIC_REPOSITORY_FILE=/data/repo.url \
		"${service}" config-check --json |
		python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["exit_code"] == 0 and d["errors"] == 0, d
repo_checks = [c for c in d["checks"] if c["key"] == "RESTIC_REPOSITORY"]
assert repo_checks and repo_checks[0]["status"] == "ok", repo_checks
assert "/data/repo" in repo_checks[0]["message"], repo_checks[0]
# RESTIC_REPOSITORY_FILE must NOT appear as a separate failing check;
# successful resolution unsets it before validation runs.
file_checks = [c for c in d["checks"] if c["key"] == "RESTIC_REPOSITORY_FILE"]
assert not file_checks, file_checks
print("[smoke] RESTIC_REPOSITORY_FILE resolution ok: {}".format(repo_checks[0]["message"]))
'

	log_info "Triggering cron.log rotation path"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'printf x >> /var/log/cron.log'
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" /bin/rotate_log

	log_info "Verifying rotation archive created"
	docker compose -f ci/docker-compose.smoke.yml exec -T "${service}" \
		sh -c 'ls /var/log/cron_log_*.tar.gz >/dev/null'

	log_info "Smoke test passed (backup, check, replicate, rotate_log, hooks, forget policy, cron-list, sources-report, forget-preview, init-repo --dry-run, notify-test --dry-run, restore --dry-run, snapshot-export --dry-run, config-check --json, doctor --json, RESTIC_REPOSITORY_FILE precedence)"
}

main "$@"
