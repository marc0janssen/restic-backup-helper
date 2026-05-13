# Versioning policy

This image follows [semantic versioning](https://semver.org), with the
twist that the published tag combines **the helper semver** with **the
Restic base image version**:

```text
<helper-semver>-<restic-version>          # stable, e.g. 2.11.0-0.18.1
<helper-semver>-<restic-version>-dev      # testing, e.g. 2.11.0-0.18.1-dev
```

## What each bump means

| Bump | Trigger | Examples |
| --- | --- | --- |
| **PATCH** (`x.y.Z+1`) | Bugfix, docs-only change, rebuild tweak, Restic patch bump without behaviour change. | `2.2.0 → 2.2.1` (shellcheck cleanup), `2.2.1 → 2.2.2` (this docs site). |
| **MINOR** (`x.Y+1.0`) | New feature, new environment variable, new script hook or materially new behaviour. Drop-in compatible. | `2.0.0 → 2.1.0` (`/bin/doctor`), `2.1.0 → 2.2.0` (`/bin/snapshot-export`), `2.2.2 → 2.3.0` (`/bin/forget-preview`), `2.3.0 → 2.4.0` (`/bin/mount-snapshot`). |
| **MAJOR** (`X+1.0.0`) | Breaking configuration, path, or runtime contract change. | `1.18.0 → 2.0.0` (`bisync` → `replicate` rename). |

## What the tag tells you

```text
2.11.0-0.18.1-dev
│   │ │   │
│   │ │   └── -dev suffix → testing train
│   │ └────── Restic base image tag (FROM restic/restic:0.18.1)
│   └──────── helper PATCH
└──────────── helper MAJOR.MINOR (operator helper feature line)
```

So `2.11.0-0.18.1-dev` is "helper 2.10.1 on top of Restic 0.18.1, testing
build". Pinning the full tag locks both layers.

## Why a coupled tag

Restic is the dominant moving piece. A floating helper tag against an
unknown Restic version risks:

- Subtle behaviour changes in `restic backup` output that break the
  helper's stats parsing for `last-backup.json`.
- A new Restic version that requires a re-init (rare, but it has
  happened) silently breaking your repository.
- Diverging support questions where the helper version is known but the
  Restic version is not.

Coupling both into the tag makes the support story unambiguous.

## How releases get cut

| File | What it controls |
| --- | --- |
| `VERSION` | The helper semver only (`x.y.z`, no Restic suffix). |
| `Dockerfile` `FROM restic/restic:<tag>` | The Restic base version pinned at build time. |
| `build.sh` / `build-testing.sh` | Read `VERSION` and `VERSION_RESTIC` from env (or CLI `--base <restic-tag>`) to compute the published tag. |
| `README.md` `release: …` line | Must match `VERSION + Dockerfile FROM`. |
| `README-containers.md` `release: …` line | Must match the same string (Docker Hub blurb). |

CI guards via `scripts/ci-quality-checks.sh::run_version_metadata_guard`:

- If **any non-metadata file** changes, then **`VERSION`**,
  **`CHANGELOG.md`**, **`README.md`** and **`README-containers.md`** must
  all be updated in the same PR.
- The `release:` lines in both READMEs must equal `${VERSION}-${restic_base}`.

So manual version bumps need a CHANGELOG entry and aligned READMEs to
pass CI.

## The compatibility bridge

When the project does break things (e.g. the `1.18 → 2.0` replicate
rename), the breaking version ships a **compatibility bridge** that keeps
the old surface working with a deprecation warning until the next major.
For 2.x → 3.0:

- `/bin/bisync` is a symlink to `/bin/replicate`.
- Every `SYNC_*` env var is mapped at startup to its `REPLICATE_*`
  counterpart when the latter is unset, with a logged deprecation
  warning.

That means a 2.x upgrade is drop-in even from 1.x as long as you
eventually migrate within the major cycle. The bridge is removed in the
*next* major, never silently.

## Backports

Bugfixes are released against `develop` (testing) and merged to `main`
(stable) in the next tag cut. There is no maintenance branch for older
majors; if you are stuck on a previous major and need a backport, open
an issue at
[github.com/marc0janssen/restic-backup-helper/issues](https://github.com/marc0janssen/restic-backup-helper/issues).
