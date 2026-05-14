# Support bundle

`/bin/support-bundle` creates a redacted diagnostics archive for support
handoff. It reads local state only and does not run backups, restores,
replicate jobs, hooks, mail or webhooks.

The bundle includes:

- `status --json`
- `doctor --json`
- `config-check --json`
- `cron-list`
- Restic / Rclone / Bash / kernel versions
- recent `/var/log/last-*.json` files
- redacted tails of `/var/log/cron.log`, `*-last.log` and
  `*-error-last.log`

## Usage

```shell
docker exec restic-backup-helper /bin/support-bundle
docker exec restic-backup-helper /bin/support-bundle --output /var/log/support.tar.gz
docker run --rm --env-file restic.env \
  -v ./config:/config:ro \
  -v ./restic.password:/run/secrets/restic_password:ro \
  -v ./logs:/var/log \
  marc0janssen/restic-backup-helper:latest \
  support-bundle --output /var/log/support.tar.gz
```

When `--output` points at a directory, the helper creates
`support-bundle-<timestamp>.tar.gz` inside that directory. Without
`--output`, it writes to `/var/log/support-bundle-<timestamp>.tar.gz`.
The archive is made mode `0755` when the filesystem permits it.

## Redaction

The helper redacts common URL userinfo, webhook paths, passwords, tokens,
authorization headers and client secrets before writing text into the
archive.

!!! warning "Still operationally sensitive"

    Redaction is a safety net, not a confidentiality proof. Logs can still
    contain filenames, hook output, mount paths, repository names and other
    operational context. Review the archive before sharing it outside your
    trusted support path.

## Full logs

By default the bundle contains the last 200 lines of each matching log file.
Use `--include-full-logs` only when you deliberately want full redacted log
files in the archive:

```shell
docker exec restic-backup-helper /bin/support-bundle --include-full-logs
```

