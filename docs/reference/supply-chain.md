# Supply chain (SBOM, Trivy)

Two complementary tools document what's inside this image and surface
CVEs against it.

## Trivy

[Trivy](https://aquasecurity.github.io/trivy/) scans the image in two
CI workflows:

| Workflow | When | Action |
| --- | --- | --- |
| [Security Scan](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/security-scan.yml) | Every push and weekly. | Uploads SARIF results to the GitHub Security tab. |
| [Release Orchestration](https://github.com/marc0janssen/restic-backup-helper/actions/workflows/release-orchestration.yml) | On tag pushes (`v*`). | **Fails on any `CRITICAL`/`HIGH` finding** so a tag never ships with a known critical vulnerability. |

To run Trivy locally against a pulled image:

```shell
trivy image --severity HIGH,CRITICAL marc0janssen/restic-backup-helper:2.8.0-0.18.1
```

`.trivyignore` in the repo root lists explicit suppressions with
rationale; review it before adding new ones.

## SBOMs

Software Bill of Materials documents are emitted in two places,
depending on whether you publish locally or via CI.

| Source | Tool | Where | When |
| --- | --- | --- | --- |
| Pushed image (preferred) | [`syft`](https://github.com/anchore/syft) | `./sbom/restic-backup-helper-<release>.{spdx,cyclonedx}.json` | After `./build.sh` / `./build-testing.sh` when `SBOM=ON` and `syft` is on `PATH`. |
| Source tree (fallback) | [`anchore/sbom-action`](https://github.com/anchore/sbom-action) | Workflow run artifact `release-orchestration-diagnostics` (`sbom-source.{spdx,cyclonedx}.json`). | Every tag push (`v*`) via the release workflow. |

Both SPDX and CycloneDX JSON are produced so you can feed
[Dependency-Track](https://dependencytrack.org/),
[GUAC](https://guac.sh/), or any SCA tool that prefers either format.

### Enable image-level SBOMs locally

```shell
# Install syft once (macOS/Linux):
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sudo sh -s -- -b /usr/local/bin

# Build with SBOM:
SBOM=ON ./build.sh
# → sbom/restic-backup-helper-2.8.0-0.18.1.spdx.json
# → sbom/restic-backup-helper-2.8.0-0.18.1.cyclonedx.json
```

The `sbom/` directory is gitignored. If `SBOM=ON` is set but `syft` is
not installed, the build logs a clear skip line and continues — it
never breaks an existing publish flow.

### What you can do with the SBOM

| Use case | How |
| --- | --- |
| Audit licenses of every binary/library inside the image. | Feed the CycloneDX SBOM into [`license-checker`](https://github.com/davglass/license-checker) or [`scancode-toolkit`](https://scancode-toolkit.readthedocs.io/). |
| Detect CVEs offline. | Run [`grype sbom:./sbom/restic-backup-helper-…spdx.json`](https://github.com/anchore/grype). |
| Ingest into Dependency-Track. | Upload the CycloneDX JSON via Dependency-Track's API; the SPDX one works too. |
| Prove provenance to an auditor. | Attach both SPDX and CycloneDX SBOMs to your change-management ticket alongside the pinned image tag and Trivy SARIF result. |
| Compare images. | Diff two SBOMs to see exactly which package versions changed between releases. |

## Verifying a pulled image

```shell
# Pull the pinned tag.
docker pull marc0janssen/restic-backup-helper:2.8.0-0.18.1

# Generate an SBOM locally.
syft marc0janssen/restic-backup-helper:2.8.0-0.18.1 -o spdx-json > local.spdx.json
syft marc0janssen/restic-backup-helper:2.8.0-0.18.1 -o cyclonedx-json > local.cdx.json

# Diff against the one shipped in this repo's sbom/ (after ./build.sh):
diff <(jq -S . local.spdx.json) <(jq -S . sbom/restic-backup-helper-2.8.0-0.18.1.spdx.json)
```

Differences mean the publisher's image differs from what you would
build from this commit — investigate before trusting it.

## Signing

The image is not currently signed with Sigstore/Cosign. If your
deployment workflow requires signed images, pin to a digest:

```shell
docker pull marc0janssen/restic-backup-helper:2.8.0-0.18.1
docker inspect --format '{{ index .RepoDigests 0 }}' marc0janssen/restic-backup-helper:2.8.0-0.18.1
# → marc0janssen/restic-backup-helper@sha256:….
```

Then deploy with the `@sha256:…` form so a re-tag at the registry
cannot change the bits under you.

## See also

- [Image tags](image-tags.md) — how to pin the moving parts.
- [Security](../security.md) — secret handling and credential masking
  at runtime.
