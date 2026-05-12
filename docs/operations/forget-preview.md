# Forget preview

`/bin/forget-preview` is a safe wrapper around `restic forget --dry-run`.
It lets you see which snapshots your configured retention policy would
keep or remove before the real post-backup `restic forget` runs.

It is **operator-initiated** and never cron-driven by itself.

## Why it exists

`RESTIC_FORGET_ARGS` is powerful and easy to get subtly wrong, especially
when several hosts share one repository. A raw repository-wide
`restic forget --dry-run --keep-daily 7` answers "what would happen to
the whole repo?", but most helper deployments really want "what would
happen to this container's host/tag snapshots?".

`/bin/forget-preview` makes the safer question the default:

- always passes `--dry-run`,
- uses `RESTIC_FORGET_ARGS` as the retention policy,
- adds `--host "$HOSTNAME"` and `--tag "$RESTIC_TAG"` by default,
- requires explicit `--repo-wide` before previewing repository-wide
  retention.

## Quick start

```shell
# Preview the configured policy for this container's host + RESTIC_TAG.
docker exec -ti restic-backup-helper /bin/forget-preview

# Preview with an ad-hoc policy, still host/tag-scoped.
docker exec -ti restic-backup-helper /bin/forget-preview \
  --policy "--keep-daily 14 --keep-weekly 8 --keep-monthly 12"

# Explicit repository-wide preview.
docker exec -ti restic-backup-helper /bin/forget-preview --repo-wide

# One-shot via docker run (no need for cron startup).
docker run --rm \
  --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  marc0janssen/restic-backup-helper:latest \
  forget-preview --policy "--keep-daily 7 --keep-weekly 4"
```

## Flags

| Flag | Default | Purpose |
| --- | --- | --- |
| `--repo-wide` | off | Do not add host/tag filters. Required for repository-wide retention previews. |
| `--host HOST` | container `$HOSTNAME` | Override the default host filter. Ignored with `--repo-wide`. |
| `--tag TAG` | `$RESTIC_TAG` | Override the default tag filter. Ignored with `--repo-wide`. |
| `--policy ARGS` | `$RESTIC_FORGET_ARGS` | Use these retention args instead of the configured policy. Quote as one shell argument. |
| `--extra ARGS` | *(empty)* | Append extra `restic forget` args after the policy and filters. Quote as one shell argument. |
| `--help` | – | Print usage and exit. |

## What it does

```mermaid
flowchart TD
    A[forget-preview] --> B[pre-forget-preview hook]
    B --> C{Validate repo auth + policy}
    C --> D[Build restic forget --dry-run]
    D --> E{--repo-wide?}
    E -- no --> F[Append --host HOSTNAME<br/>and --tag RESTIC_TAG]
    E -- yes --> G[No host/tag filters]
    F --> H[Run restic forget --dry-run]
    G --> H
    H --> I[Write last-forget-preview.json]
    I --> J[Optional restic_forget_preview.prom]
    J --> K{MAILX_RCPT? WEBHOOK_URL?}
    K --> L[mail + webhook]
    L --> M[post-forget-preview hook with "$rc"]
```

## Scope defaults

Default command shape:

```shell
restic forget --dry-run $RESTIC_FORGET_ARGS --host "$HOSTNAME" --tag "$RESTIC_TAG"
```

This mirrors the helper's backup behaviour, where `/bin/backup` writes
snapshots with `--tag "$RESTIC_TAG"`. It also protects shared
repositories: one host's preview does not accidentally include another
host's snapshots unless you deliberately opt in.

Use `--repo-wide` when your policy is intentionally global, for example
on a dedicated repository where all snapshots share one retention
contract.

## Audit trail

The helper writes:

- `/var/log/forget-preview-last.log`
- `/var/log/forget-preview-error-last.log` on failure
- `/var/log/last-forget-preview.json`
- `restic_forget_preview.prom` when `METRICS_DIR` is configured

Hooks:

```text
/hooks/pre-forget-preview.sh                # informational; failure does not abort the preview
/hooks/post-forget-preview.sh "$exit_code"  # always called with the restic exit code as $1
```

Mail and webhook notifications use the same `MAILX_*` and `WEBHOOK_*`
settings as the cron-driven workers.

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Preview completed successfully. |
| `2` | Configuration error: missing repository credentials, empty policy, or empty host/tag filter without `--repo-wide`. |
| other | Restic returned a failure. Inspect `/var/log/forget-preview-error-last.log`. |

## See also

- [Backup worker](../workers/backup.md) — runs the real `restic forget`
  after a successful backup.
- [Prune worker](../workers/prune.md) — performs expensive repository
  compaction separately from forget.
- [JSON summaries](../reference/json-summaries.md) — schema for
  `last-forget-preview.json`.
