# Installation

The image is published to [Docker Hub](https://hub.docker.com/r/marc0janssen/restic-backup-helper)
on two release trains. Pick the train that matches how comfortable you are
running pre-release builds in production.

## Release trains

| Train | When to use | Example pull |
| --- | --- | --- |
| **Stable** | Production. Tags are cut from `main` after stabilising on `develop`. | `docker pull marc0janssen/restic-backup-helper:latest` |
| **Testing** | Pre-release / CI. Cut from `develop`; carries `-dev` suffix. | `docker pull marc0janssen/restic-backup-helper:develop` |

## Pinning a specific version

Tags follow the schema `<helper-semver>-<restic-version>`, e.g. `2.11.0-0.18.1`,
so you can pin **both** the helper logic and the Restic base image in lockstep.
Testing builds add a `-dev` suffix, e.g. `2.11.0-0.18.1-dev`.

=== "Stable"

    ```shell
    docker pull marc0janssen/restic-backup-helper:2.11.0-0.18.1
    ```

=== "Testing"

    ```shell
    docker pull marc0janssen/restic-backup-helper:2.11.0-0.18.1-dev
    ```

!!! tip "Why pin?"

    `latest` and `develop` are moving targets. Pinning the full
    `<helper>-<restic>` tag means an unattended `docker compose pull` cannot
    silently flip you onto a new Restic minor or a new helper major release.
    See [Image tags](../reference/image-tags.md) for the full taxonomy.

## Verify signatures and SBOM

- **Trivy** scans every push and every tag release; SARIF results land in the
  GitHub Security tab and tag releases fail on `CRITICAL` / `HIGH` findings.
- **SBOMs** in SPDX and CycloneDX JSON are emitted by `./build.sh` and
  `./build-testing.sh` when `SBOM=ON` and [`syft`](https://github.com/anchore/syft)
  is on `PATH`. The release CI also uploads source-tree SBOMs on tag pushes.

See [Supply chain](../reference/supply-chain.md) for verification steps.

## Required runtime ingredients

1. **`RESTIC_REPOSITORY`** — Restic repository location. Any backend Restic
   supports: local path, `s3:`, `sftp:`, `rclone:`, `swift:`, `b2:`, …
2. **A password** — preferably `RESTIC_PASSWORD_FILE` pointing at a Docker
   secret or read-only mounted file; `RESTIC_PASSWORD` works but appears in
   `docker inspect`.
3. **`RESTIC_TAG`** — explicitly empty is a hard failure since 1.14.0. Pick
   something meaningful (`daily`, `${HOSTNAME}-data`, …) so snapshots can be
   filtered by tag later.
4. **`BACKUP_CRON`** — when the backup runs (`crond` 5-field syntax).
5. **Source data mounted somewhere** the container can read — typically
   `/data`, sometimes a wider read-only `/host`.

That is the minimum. Everything else is optional and additive.

## Next steps

- [Quick start](quick-start.md) — minimal `docker run` and Compose example.
- [Environment variables](../configuration/environment-variables.md) — the
  complete option surface.
- [Architecture](../concepts/architecture.md) — how the container is wired
  together internally.
