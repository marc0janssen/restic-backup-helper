# Contributing to restic-backup-helper

Quick reference for contributors. The full project context lives in [`AGENTS.md`](AGENTS.md) (intended for AI coding agents but the conventions apply to humans too).

## Local quality checks

The same matrix that CI enforces is also runnable locally. Two ways:

### 1. Run the CI script directly

```shell
bash scripts/ci-quality-checks.sh
```

This expects `shellcheck`, `shfmt`, `hadolint`, `yamllint` and `actionlint` on your `PATH`. On macOS install them with Homebrew, on Alpine/Debian use the matching package manager.

### 2. Pre-commit (recommended)

Install [pre-commit](https://pre-commit.com) once and the linter matrix runs automatically on every `git commit`:

```shell
pip install pre-commit          # or: brew install pre-commit / apk add ...
pre-commit install              # writes .git/hooks/pre-commit
pre-commit run --all-files      # one-shot full repo lint
```

The configuration lives in [`.pre-commit-config.yaml`](.pre-commit-config.yaml) and pins versions of every linter so contributors get a reproducible result.

## Style highlights

- **Shell:** Bash with `#!/usr/bin/env bash` and `set -Eeuo pipefail` for new scripts; quote variable expansions; match the surrounding style under `app/` for worker scripts.
- **Strings:** Prefer ASCII; emojis used sparingly in user-facing log lines (already established convention).
- **Secrets:** Never commit `.env`, `restic.password`, `rclone.conf`, `msmtprc`, webhook tokens, or other secret-bearing files. The repository's `.gitignore` already covers the common cases.
- **Versioning:** Bump `VERSION` (`MAJOR.MINOR.PATCH`) when you change behaviour, update `CHANGELOG.md`, and keep `README.md` + `README-containers.md` `release:` and pinned pull lines aligned. CI's versioning guard fails otherwise.
- **Docker Hub copy:** When you change user-visible behaviour, refresh both `README.md` (full manual) and `README-containers.md` (Docker Hub blurb, must stay under 25 000 bytes).

## Worker-script invariants

Anything new should keep these end-to-end guarantees so existing operators are not surprised:

- Worker scripts source `/bin/lib.sh` and use the shared helpers (`log`, `errorlog`, `mask_repository`, `mask_endpoint`, `format_subject`, `notify_mail`, `notify_webhook`, `write_last_run_json`, `write_metrics_for_job`, `run_hook`, `should_auto_unlock`, `build_restic_cacert_args`).
- Cron entries are wrapped in `/bin/locked_run` (no exceptions; that wrapper provides the "skipped: previous run still active" log line).
- Sensitive values (passwords, webhook tokens, repo URL credentials, sync source/destination credentials) must not leak into stdout/stderr or `last-*.json`/`*.prom` files. The `mask_*` helpers exist for this.
- Hook exit codes are logged but never propagate to the worker exit code; the underlying restic/rclone command exit is authoritative.
- `last-*.json`, webhook payload and `*.prom` metrics are written from a single `last_run_extras` array per worker so the three surfaces stay in sync.

## Building images

The build scripts (`build.sh`, `build-testing.sh`, `build-testing-local.sh`) use the values in `VERSION` + `VERSION_RESTIC` (build-script env). Hand-built images must pass `--build-arg RESTIC_BACKUP_HELPER_RELEASE=…` so `docker inspect` shows the right release string. See [`AGENTS.md`](AGENTS.md) for the full publish flow and Docker Hub `README-containers.md` integration.
