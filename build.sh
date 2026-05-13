#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Name: restic-backup-helper (stable image)
# Coder: Marco Janssen (micro.blog @marc0janssen https://micro.mjanssen.nl)
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build-common.sh
source "${SCRIPT_DIR}/scripts/build-common.sh"

# Optional repo-root env: ./build.env — wordt gelezen als eerste stap in
# run_stable_build() → apply_optional_env_file() in scripts/build-common.sh
run_stable_build "$@"
