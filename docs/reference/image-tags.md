# Image tags

This page is the canonical reference for the tags published to
[`marc0janssen/restic-backup-helper`](https://hub.docker.com/r/marc0janssen/restic-backup-helper)
on Docker Hub.

## Tag schema

```text
<helper-semver>-<restic-version>          # stable, e.g. 2.2.2-0.18.1
<helper-semver>-<restic-version>-dev      # testing, e.g. 2.2.2-0.18.1-dev
```

Two moving aliases also exist:

| Alias | Points at | Use for |
| --- | --- | --- |
| `latest` | Most recent stable tag. | Production when you accept rolling updates. |
| `develop` | Most recent testing tag. | Pre-release / CI; expect occasional rough edges. |

!!! warning "Don't use floating tags in production"

    `latest` and `develop` are moving targets. Pin to a full
    `<helper>-<restic>` tag so an unattended `docker compose pull`
    cannot silently flip you onto a new Restic minor or a new helper
    major. See [Versioning policy](../concepts/versioning.md).

## All tag categories

| Tag | Meaning |
| --- | --- |
| `latest` | Current stable. |
| `<semver>-<restic>` | Pinned stable, e.g. `2.2.2-0.18.1`. |
| `develop` | Latest testing build. |
| `<semver>-<restic>-dev` | Pinned testing image. |

The `<semver>` portion matches the value in `VERSION`. The
`<restic>` portion matches the `FROM restic/restic:<tag>` line in the
`Dockerfile`. The CI version-guard enforces that all four release
strings (`VERSION` + `Dockerfile`, `README.md`, `README-containers.md`)
stay consistent.

## How to read a tag

```text
2.2.2-0.18.1-dev
│   │ │   │
│   │ │   └── -dev suffix → testing train
│   │ └────── Restic base image tag (FROM restic/restic:0.18.1)
│   └──────── helper PATCH (e.g. CI/docs fix)
└──────────── helper MAJOR.MINOR (e.g. replicate rename + snapshot-export)
```

Concrete example: `2.2.2-0.18.1-dev` is "helper 2.2.2 on top of Restic
0.18.1, testing build".

## Where each tag comes from

| Workflow | Source branch | Image train |
| --- | --- | --- |
| Manual `./build.sh` | Whatever you have locally | `latest`, `<semver>-<restic>` |
| Manual `./build-testing.sh` | `develop` | `develop`, `<semver>-<restic>-dev` |
| Manual `./build-testing-local.sh` | Whatever you have locally | Private registry `:testing` only |
| CI release on `v*` tag push | The tag's commit | `latest` and pinned stable |

The `build*.sh` scripts read `VERSION` and the `VERSION_RESTIC` env var
to compute the published tag. Manual hand-built images **must** pass
`--build-arg RESTIC_BACKUP_HELPER_RELEASE=…` (same string as the
versioned image tag), otherwise the value defaults to `unknown` in the
`Dockerfile` and `RESTIC_BACKUP_HELPER_RELEASE` ends up `unknown` at
runtime.

## Where the tag shows up at runtime

- **JSON summaries** `last-<job>.json` → `release` field.
- **Prometheus metrics** are not labelled with the release on purpose
  (label cardinality), but the JSON next to them carries it.
- **`/bin/doctor` Runtime section**.
- **Mail subjects** do not include the release; mail bodies do via the
  log content.
- **OCI image labels**:

    ```text
    org.opencontainers.image.title=restic-backup-helper
    org.opencontainers.image.version=2.2.2-0.18.1
    ```

    Inspect with `docker inspect --format '{{ .Config.Labels }}' marc0janssen/restic-backup-helper:latest`.

## Verifying you got the tag you asked for

```shell
docker pull marc0janssen/restic-backup-helper:2.2.2-0.18.1
docker run --rm marc0janssen/restic-backup-helper:2.2.2-0.18.1 \
  printenv RESTIC_BACKUP_HELPER_RELEASE
# → 2.2.2-0.18.1
```

If you see `unknown`, the image was hand-built without the
`--build-arg` (see above) — re-pull the published tag.

## See also

- [Versioning policy](../concepts/versioning.md) — what each bump
  means.
- [Upgrading](../getting-started/upgrading.md) — version-by-version
  upgrade notes.
- [Supply chain](supply-chain.md) — SBOM and Trivy results for each
  published image.
