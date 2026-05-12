# AGENTS.md

Instructions for Codex and other coding agents working in this repository.

## Scope

These instructions apply to the whole repository.

## Project Context

This repository builds **`marc0janssen/restic-backup-helper`**, a Docker image for scheduled [Restic](https://restic.net) backups, repository checks, optional Rclone replicate jobs, logging and mail notifications.

The image is based on **`restic/restic`** (Alpine). This repository owns application scripts under `app/`, container entrypoint behaviour, cron wiring, configuration samples, build tooling and documentation—not the Restic core itself.

## General Rules

- Act as a strong shell programmer, Docker/container engineer, and backup/storage engineer (Restic, Rclone, NFS/SFTP/S3, cron).
- Prefer robust, boring, auditable solutions over clever shortcuts.
- Treat the project as **security-sensitive**: repository passwords, cloud credentials, mail and mount paths must never leak into git or logs inappropriately.
- Keep changes small and directly related to the requested task.
- Do not remove or rewrite user changes unless explicitly asked.
- Do not commit secrets, passwords, tokens, private keys, **`*.env`** files used for builds (`build.env`, `build-testing.env`, `build-testing-local.env`), `rclone.conf`, or other local/runtime config.
- Keep generated or local runtime data out of git.
- Build scripts use **Bash** (`#!/usr/bin/env bash`, `set -euo pipefail`); application scripts under `app/` follow the existing style (mostly Bash/sh compatible patterns—match surrounding code).
- Prefer ASCII in source files unless there is a strong reason not to.

## Shell Script Standards

- Prefer `#!/usr/bin/env bash` with `set -euo pipefail` (or `set -Eeuo pipefail` where strictly needed) for new Bash scripts.
- Quote variable expansions used in paths, remote targets and Docker arguments.
- Do not pipe untrusted data into `sh`, `bash`, `eval`, or command substitution that executes generated code.
- Use clear, grep-friendly log prefixes where helpful; build scripts use **`[build]`** for user-visible steps.
- Avoid macOS-only commands unless a portable fallback exists (many users build or validate on Linux CI).

## Layout

| Area | Role |
|------|------|
| `Dockerfile` | Image definition; `restic/restic:<tag>`; release string via `ARG` / `ENV RESTIC_BACKUP_HELPER_RELEASE` at build time (no repo `.release` file) |
| `app/entry.sh` | Container entrypoint |
| `app/backup.sh`, `app/check.sh`, `app/replicate.sh`, `app/rotate_log.sh` | Cron-invoked workers |
| `app/restore.sh`, `app/snapshot_export.sh`, `app/doctor.sh` | Operator-invoked helpers |
| `app/install_rclone.sh` | Rclone install during image build |
| `scripts/build-common.sh` | Shared logic for release versioning and Docker Hub builds |
| `build.sh`, `build-testing.sh` | Stable / dev Docker Hub builds (read optional `build.env` / `build-testing.env`) |
| `build-testing-local.sh` | Private-registry build; pushes only `:testing` (optional `build-testing-local.env`) |
| `scripts/start_restic_helper_agent_compose.sh`, `scripts/docker-compose.yml` | Example/runtime helpers |
| `config/` | Sample excludes, msmtp, replicate job definitions |
| **`README.md`** | Primary documentation (GitHub, full detail) |
| **`README-containers.md`** | Docker Hub description: short summary, tags, links; **must stay aligned** with release/pull-tag lines that build scripts auto-patch |

When adding or changing behaviour exposed to users, update **`README.md`** and, where it affects how users pull or understand the image on Docker Hub, **`README-containers.md`** as well (and **`CHANGELOG.md`** / **`VERSION`** when appropriate).

## README-containers.md (Docker Hub)

- **Role:** Published to Docker Hub via `docker pushrm --file README-containers.md` after **`./build.sh`** (`:latest`) and **`./build-testing.sh`** (`:develop`). It is the public-facing blurb, not the full manual.
- **Keep in sync:** `scripts/build-common.sh` applies the same `sed` updates to **`README.md`** and **`README-containers.md`** for `release:` and `docker pull …` lines. Do not hand-edit those lines to diverge between the two files before a release build.
- **Manual edits:** When you add user-facing features, refresh the short sections in **`README-containers.md`** (features, tags table, links) so Hub stays accurate—not only **`README.md`**.
- **Size:** Stay clearly under Docker Hub’s description limit (~25 000 bytes); run `wc -c README-containers.md` if in doubt.

## Versioning And Releases

The image **codebase semver** lives in **`VERSION`** at the repository root.

Release image tags follow **`${semver}-${RESTIC_VERSION}`** (stable) or **`${semver}-${RESTIC_VERSION}-dev`** (testing train), for example **`1.9.108-0.18.1`**. The Restic base image tag is tracked via **`VERSION_RESTIC`** in build scripts and must stay consistent with `FROM restic/restic:…` in the Dockerfile.

**Semantic versioning** for `VERSION` (manual policy when you change the repo without running the publish scripts):

- **PATCH**: bugfix, docs-only fixes, rebuild tweaks, Restic patch bump without behaviour change.
- **MINOR**: new feature, new environment variable, new script hook or materially new behaviour.
- **MAJOR**: breaking configuration, path, or runtime contract change.

Running **`./build.sh`** or **`./build-testing.sh`** does **not** change `VERSION` or README files: they build and push using the current **`VERSION`** line plus **`VERSION_RESTIC`** from env (stable: `x.y.z-<restic>`, testing: `x.y.z-<restic>-dev`). **`Dockerfile` `FROM restic/restic:`** is still rewritten from **`VERSION_RESTIC`** when you build. Bump **`VERSION`**, **`CHANGELOG.md`**, and README release lines yourself (or use **`./scripts/update-restic-base.sh`** when changing the Restic base tag — that script still bumps the helper patch semver by design).

### How versioning becomes visible in git

Without running the publish scripts, nothing updates **`VERSION`** or the README lines automatically—you have to do it yourself for commits to reflect semver policy:

| Artifact | What it is |
|----------|----------------|
| **`VERSION`** | Only `major.minor.patch` (no Restic suffix). Raise **PATCH** / **MINOR** / **MAJOR** per the rules above when you merge meaningful work. |
| **`CHANGELOG.md`** | Human-readable list of changes per release; add an entry when you bump version meaningfully. |
| **`README.md`** / **`README-containers.md`** | Must stay aligned: `release:` and example `docker pull …:<semver>-<restic>` / `-dev` tags. |

Before publishing a new image, manually bump **`VERSION`** (and MINOR/MAJOR when required), edit **`CHANGELOG.md`**, and align **`README.md`** / **`README-containers.md`** `release:` and pinned pull examples with **`VERSION`** + **`Dockerfile`** `FROM` (see CI versioning guard in `scripts/ci-quality-checks.sh`).

When you touch user-facing release metadata, keep **`README.md`** and **`README-containers.md`** consistent with each other and with **`VERSION`**. See **README-containers.md (Docker Hub)** above for Hub-specific rules.

## Build And Env Files

- **`build.env`** — optional; loaded by **`./build.sh`** (stable).
- **`build-testing.env`** — optional; loaded by **`./build-testing.sh`**.
- **`build-testing-local.env`** — optional; loaded by **`./build-testing-local.sh`** for private registries. That script pushes **only** `<LOCAL_REPO>:testing` (no extra versioned or `:develop` tags). The release string is baked into the image as **`ENV RESTIC_BACKUP_HELPER_RELEASE`** via **`docker build --build-arg`** (no host `.release` file).

Templates are **`*.env.example`**. Real env files are gitignored; do not commit them.

Precedence is documented in each script: generally **CLI overrides > non-empty exported variables > env file > defaults**.

Hand-built images must pass **`--build-arg RESTIC_BACKUP_HELPER_RELEASE=…`** (same string as the versioned image tag, e.g. `1.9.0-0.18.1` or `1.9.0-0.18.1-dev`); otherwise the value defaults to `unknown` in the Dockerfile.

Do not run **`docker buildx`**, **`docker push`**, or registry pushes unless the user explicitly asks.

## Security

- Never hardcode `RESTIC_PASSWORD`, cloud API keys, SMTP passwords or Rclone secrets.
- Secrets belong in environment variables, Docker secrets or mounted files outside version control.
- Be cautious with logging paths that might include sensitive filenames or repository URLs.

## Validation Checklist

Before finishing changes, run checks that apply:

```sh
bash -n build.sh build-testing.sh build-testing-local.sh scripts/build-common.sh scripts/start_restic_helper_agent_compose.sh app/*.sh
```

If **`shellcheck`** is installed:

```sh
shellcheck -x scripts/build-common.sh build-testing-local.sh
```

```sh
git status --short
```

For behaviour changes in cron scripts, reason through failure modes (empty env, missing mounts, network errors) without requiring live backups.

## Git

- Do not commit unless the user asks.
- Keep commits focused.
- Use clear commit messages.
- Preferred commit identity for this repository is `Marco Janssen <marco@mjanssen.nl>`; do not change git config automatically, but use or recommend this email when commit identity needs to be set explicitly.
- Check `git status --short` before and after staging.
- Do not stage unrelated files or gitignored local env files.
