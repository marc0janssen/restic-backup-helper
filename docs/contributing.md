# Contributing

For the canonical list of conventions, lint matrices and pre-commit
hooks, see [`CONTRIBUTING.md`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/CONTRIBUTING.md)
and [`AGENTS.md`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/AGENTS.md)
in the repo root. This page is a short orientation for contributors
who want to get a local development loop running quickly.

## Get the source

```shell
git clone https://github.com/marc0janssen/restic-backup-helper.git
cd restic-backup-helper
```

## Install local hooks

```shell
pip install pre-commit         # or brew install pre-commit
pre-commit install
```

The hooks run the same `shellcheck` / `shfmt` / `hadolint` /
`yamllint` / `actionlint` checks CI runs, so you can catch findings
before pushing.

## Build the image locally

```shell
./build-testing.sh             # builds and pushes the testing tag
./build-testing-local.sh       # builds and pushes to a private registry (build-testing-local.env)
```

Hand-built images **must** pass
`--build-arg RESTIC_BACKUP_HELPER_RELEASE=…` (same string as the
versioned image tag, e.g. `2.4.0-0.18.1-dev`) so the `release` field
in `last-<job>.json` is accurate. The `build-testing.sh` scripts
handle this automatically.

## Lint matrix

CI runs all of these via `scripts/ci-quality-checks.sh`:

| Tool | Targets |
| --- | --- |
| `shellcheck` | Every tracked `.sh` and the `app/` workers. |
| `shfmt` | Same. |
| `hadolint` | `Dockerfile`. |
| `yamllint` | Tracked YAML (`.github/workflows`, `.hadolint.yaml`, `.pre-commit-config.yaml`, `examples/kubernetes/*.yaml`). |
| `actionlint` | `.github/workflows`. |
| `docker compose config -q` | Compose YAML files in `examples/compose/` and `scripts/`. |

Run locally:

```shell
shellcheck -x app/*.sh scripts/build-common.sh build*.sh
shfmt -d app/*.sh
hadolint Dockerfile
yamllint .
actionlint
bash scripts/ci-quality-checks.sh   # the whole matrix
```

The `ci-quality-checks.sh` script also enforces:

- README size limit for Docker Hub (`README-containers.md` ≤ 25 000
  bytes).
- Versioning guard: when any non-metadata file changes, `VERSION`,
  `CHANGELOG.md`, `README.md` and `README-containers.md` must all be
  touched and the release strings must line up.

## Building the docs site

```shell
pip install -r docs/requirements.txt
mkdocs serve
# Open http://127.0.0.1:8000
```

Edit any file under `docs/`, save, and the dev server hot-reloads.

To produce a static build:

```shell
mkdocs build --strict
# Output in ./site
```

`--strict` fails on broken internal links and unknown nav entries —
good to run before opening a PR that touches docs.

## Worker-script invariants

If you add or modify a worker under `app/`:

1. Source `app/lib.sh` for `log`, `errorlog`, `logLast`, `copyErrorLog`,
   `mask_repository`, `mask_endpoint`, `notify_mail`, `notify_webhook`,
   `render_last_run_json`, `write_last_run_json`,
   `write_metrics_for_job`.
2. Write `/var/log/<worker>-last.log` for the per-run log and
   `/var/log/last-<job>.json` for the structured summary.
3. Call `notify_mail` and `notify_webhook` so `MAILX_RCPT` /
   `WEBHOOK_URL` plumbing applies consistently.
4. Emit `restic_<job>.prom` via `write_metrics_for_job` when
   `METRICS_DIR` is set.
5. Add `/hooks/pre-<worker>.sh` and `/hooks/post-<worker>.sh` invocations
   at the right places, with `HOOK_TIMEOUT` honoured.
6. Update `app/doctor.sh` to report relevant config for the new
   worker.
7. Add tests/smoke coverage where appropriate.

## Versioning

See [Versioning policy](concepts/versioning.md) for the semver rules.
Short version:

- PATCH: bugfix, docs-only, rebuild tweaks.
- MINOR: new feature, env var, hook, materially new behaviour.
- MAJOR: breaking config / path / runtime contract change.

The version guard in `ci-quality-checks.sh` forces `VERSION`,
`CHANGELOG.md`, `README.md` and `README-containers.md` to stay in sync.

## Pull request checklist

1. Run `pre-commit run --all-files`.
2. Run `bash scripts/ci-quality-checks.sh` locally if you can.
3. Update `CHANGELOG.md` with a one-line entry under the next version.
4. Update `VERSION` and the `release:` lines in both READMEs if your
   change touches non-metadata files.
5. Open the PR against `develop`.

## See also

- [Architecture](concepts/architecture.md) — for understanding the
  pieces you might touch.
- [Versioning policy](concepts/versioning.md) — for picking the right
  bump.
