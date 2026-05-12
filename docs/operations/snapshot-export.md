# Snapshot export

`/bin/snapshot-export` is a wrapper around `restic restore` plus `tar`.
It restores a selected snapshot into a temporary work directory,
packages the restored tree as a `.tar.gz` archive, and removes the
temporary tree again unless `--keep-workdir` is set.

Use it for:

- **Offline transfer** — produce an archive that fits on a USB drive
  for an air-gapped audit, customer handoff, or warm-standby seeding.
- **Support handoff** — package a single subtree
  (`--include /data/documents`) for a third party without granting them
  Restic repository access.
- **Spot-check restorability** — `--dry-run` runs the restore part
  without writing the archive.

By default it exports `latest` for the configured `RESTIC_TAG` and
`HOSTNAME`, writes to
`/restore/snapshot-export-latest-<timestamp>.tar.gz`, and refuses to
overwrite an existing archive unless `--force` is passed.

## Quick start

```shell
# Export the latest snapshot for this host+tag.
docker exec -ti restic-backup-helper /bin/snapshot-export --id latest

# Export a specific subtree from a specific snapshot to a chosen archive.
docker exec -ti restic-backup-helper /bin/snapshot-export \
  --id 5a3f2c8b \
  --include /data/documents \
  --output /restore/documents-5a3f2c8b.tar.gz

# Dry-run a restore before producing the archive.
docker exec -ti restic-backup-helper /bin/snapshot-export \
  --id latest \
  --include /host/home/admin \
  --dry-run

# One-shot via docker run (no need for a running container).
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  -v ./restore:/restore \
  marc0janssen/restic-backup-helper:latest \
  snapshot-export --id latest --include /data/documents
```

## Flags

| Flag | Meaning |
| --- | --- |
| `--id HEX\|latest` | Snapshot ID to export; defaults to `latest`. |
| `--tag TAG`, `--host HOST` | Snapshot filters; default to `RESTIC_TAG` and container `HOSTNAME`. |
| `--include PATH`, `--exclude PATH` | Scope the restore before packaging; repeatable. Include filters that restore 0 files/dirs exit `3`. |
| `--output FILE` | Archive path; default is under `/restore`. |
| `--work-dir DIR` | Use a specific temporary work directory; must be empty unless `--force` is set. |
| `--keep-workdir` | Keep the restored temporary tree for inspection after packaging. |
| `--force` | Allow overwriting an existing archive and reusing a non-empty work directory. |
| `--dry-run` | Run `restic restore --dry-run` only; no archive is created. |
| `--verify` | Pass Restic's `--verify` during restore before packaging. |
| `--verbose`, `-v` | Stream Restic restore output live while still logging to `/var/log/snapshot-export-last.log`. |

## What it does

```mermaid
flowchart TD
    A[snapshot-export] --> B[pre-snapshot-export hook]
    B --> C{Validate flags + RESTIC_*}
    C --> D[Create temp work dir<br/>or honour --work-dir]
    D --> E[restic restore --target WORK/restore<br/>--include/--exclude]
    E --> F{--dry-run?}
    F -- yes --> X[Skip archive; cleanup]
    F -- no  --> G[tar -czf OUTPUT.tmp -C WORK/restore .]
    G --> H[mv OUTPUT.tmp OUTPUT]
    H --> I[Write last-snapshot-export.json]
    I --> J[Optional METRICS_DIR/.prom]
    J --> K{MAILX_RCPT? WEBHOOK_URL?}
    K --> L[mail + webhook]
    L --> M[Cleanup: rm -rf WORK<br/>unless --keep-workdir]
    M --> N[post-snapshot-export hook with "$rc"]
```

### Work directory

By default the helper auto-creates a unique temp directory under
`${TMPDIR:-/tmp}/snapshot-export.<random>` and removes it at the end.
This avoids accidental data loss in user-mounted paths.

When you pass `--work-dir DIR`:

- The directory must exist and be empty (or `--force` to reuse).
- The helper creates `DIR/restore/` and points restic's `--target` at
  that subdirectory.
- On exit it removes `DIR/restore/` but **leaves `DIR` itself**, on the
  assumption that you intentionally chose a path you want to keep.

### Archive path

Default: `/restore/snapshot-export-<sanitised-id>-<timestamp>.tar.gz`.
The sanitiser strips anything that is not `[A-Za-z0-9_.-]` from the
snapshot ID so `latest` becomes `latest` and a long ID stays itself.

Override with `--output PATH`. The helper refuses to overwrite an
existing path unless `--force` is passed.

The archive is written via `<output>.tmp` + `mv` so a partial archive
never appears at the final path.

### Verbose / dry-run

`--verbose` works the same way as in `/bin/restore` — see
[Restore verbose mode](restore.md#verbose-mode-internals).

`--dry-run` short-circuits **after** the restore step and **skips** the
`tar` packaging. The result: a confirmation that the snapshot is
restorable without any disk writes outside the temp work directory.

### Notifications

Same plumbing as the other workers:

- `MAILX_RCPT` + `MAILX_ON_ERROR` → mail.
- `WEBHOOK_URL` + `WEBHOOK_ON_ERROR` → JSON POST.
- `METRICS_DIR` → `restic_snapshot_export.prom`.

Subjects use the standard `[OK|FAIL N] Snapshot export …` shape:

```text
Subject: [OK] Snapshot export larak · 1m12s · 4523 files (567.89 MiB) → /restore/snapshot-export-….tar.gz
Subject: [FAIL 3] Snapshot export larak · 0s · include-zero-match
```

### Hooks

```text
/hooks/pre-snapshot-export.sh                # informational
/hooks/post-snapshot-export.sh "$exit_code"  # exit code as $1
```

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Archive written successfully (or `--dry-run` succeeded). |
| `1` | Generic restic failure during the restore step. |
| `2` | Operator-side validation error (bad flags, missing repo, …). |
| `3` | `--include` filter matched 0 files/dirs. `include_zero_match=true` in JSON. |
| `12` | Wrong password. |
| `130` | Operator cancelled via `Ctrl+C`. |

## When to use restore vs snapshot-export

| Need | Use |
| --- | --- |
| Get data back onto a server's disk. | `/bin/restore` |
| Send the data somewhere as a single file. | `/bin/snapshot-export` |
| Restore a specific subtree to a chosen target. | `/bin/restore --include` |
| Package a specific subtree for offline transfer. | `/bin/snapshot-export --include --output` |
| Verify a snapshot is restorable. | Either, with `--dry-run`. |

## What's *inside* the archive

The archive is a `tar.gz` of the **contents** of the restore target —
no `./restore/` prefix. So after extracting:

```text
$ tar -tzf snapshot-export-latest-20260511-120000.tar.gz | head
data/documents/manifest.txt
data/documents/2026/Q1/...
data/documents/2026/Q2/...
```

Use `tar -xzvf <archive> -C /target` to extract on the destination.

## See also

- [Restore](restore.md) — the in-place restore wrapper.
- [Mount snapshot](mount-snapshot.md) — read-only FUSE browse of any
  snapshot under `/restore` without producing an archive on disk.
- [Manual runs](manual-runs.md) — `docker run … snapshot-export` for an
  ephemeral one-shot.
- [JSON summaries](../reference/json-summaries.md) —
  `last-snapshot-export.json` schema.
