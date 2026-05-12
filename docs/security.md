# Security

This page summarises the helper's stance on secrets, credential
masking and the trust boundaries you control.

## Don't bake secrets into the image

- Never hardcode `RESTIC_PASSWORD`, cloud API keys (`AWS_*`, `B2_*`,
  `OS_*`, …), SMTP passwords or Rclone secrets into a `Dockerfile`,
  Compose file, or Kubernetes manifest checked into git.
- Prefer **`RESTIC_PASSWORD_FILE`** over `RESTIC_PASSWORD`. The former
  reads from a file at runtime; the latter shows up in `docker
  inspect`, `kubectl get pods -o yaml`, environment dumps and probably
  some log somewhere you forgot about.
- For Docker:

    ```yaml
    secrets:
      restic_password:
        file: ./restic.password    # gitignored, chmod 600
    services:
      restic-backup:
        secrets:
          - restic_password
        environment:
          RESTIC_PASSWORD_FILE: /run/secrets/restic_password
    ```

- For Kubernetes: mount a `Secret` as a volume (or use `subPath`) and
  set `RESTIC_PASSWORD_FILE` to that path so the literal password does
  not appear in the Pod spec env values:

    ```yaml
    volumeMounts:
      - name: restic-password
        mountPath: /run/secrets
        readOnly: true
    volumes:
      - name: restic-password
        secret:
          secretName: restic-password
    env:
      - name: RESTIC_PASSWORD_FILE
        value: /run/secrets/restic_password
    ```

## What gets masked automatically

The helper is intentionally chatty about what it ran and why, but
never about secrets. The masking and redaction rules:

| Surface | Masked |
| --- | --- |
| Repository URLs (`scheme://user:password@host`, `backend:user:password@host`) | Userinfo replaced with `:***` via `mask_repository` before being printed, written to `last-<job>.json`, posted to webhooks, or used in mail subjects. |
| Replicate source/destination URLs with inline credentials | Same masking via `mask_endpoint`. Configured `rclone:` remotes have credentials in `rclone.conf` and never leak through. |
| Webhook URL | Only `scheme://host/...` is logged; per-recipient secrets in path/query (healthchecks.io UUIDs, Slack tokens, ntfy topics) are stripped via `mask_webhook_url`. |
| Webhook auth header (`WEBHOOK_HEADER_AUTH`) | Never echoed; logs only mention "auth header set". |
| Restic / msmtp passwords | Read from env or password file by restic/msmtp directly; never echoed by the helper scripts. |

What is **not** masked:

| Surface | Reasoning |
| --- | --- |
| `RESTIC_JOB_ARGS` / `RESTIC_FORGET_ARGS` / `RESTIC_PRUNE_ARGS` / `REPLICATE_JOB_ARGS` | Caller-controlled, printed verbatim. Avoid stuffing secrets into these (use `RESTIC_PASSWORD_FILE` and `--password-command` files instead). |
| Hook script stdout/stderr | Logged as the hook emits them. Make sure your hook does not echo secrets to stdout. |
| Backup paths and exclude patterns | Filenames may be sensitive in some industries (medical, legal). Use `:ro` mounts and consider scrubbing logs before mailing them. |

## Audit checklist

Run these to confirm nothing unexpected is leaking:

```shell
docker exec restic-backup-helper cat /var/log/cron.log
docker exec restic-backup-helper cat /var/log/last-backup.json
docker exec restic-backup-helper /bin/doctor
```

Then in your monitoring stack:

- **Webhook endpoint logs**: confirm `Authorization` header is *not*
  echoed back in any error / debug logs.
- **Mail relay logs**: confirm subjects do not contain inline
  credentials.
- **node-exporter scrape**: the `restic_<job>_last_*` metric set does
  not include the repository URL — only `hostname` is labelled. So
  even a public Prometheus endpoint cannot leak credentials this way.

## Hardening

The container **runs as root** (upstream-style for cron, FUSE, NFS).
Prefer least privilege at the orchestration layer:

- `cap_drop: [ALL]` + `cap_add: [DAC_READ_SEARCH, SYS_ADMIN]`
- `read_only: true` with tmpfs for `/tmp`, `/run`, `/var/run`,
  `/var/spool/cron`
- `no-new-privileges:true`
- `:ro` bind-mounts on backup sources and SSH keys
- seccomp / AppArmor default profiles (already on by default in modern
  Docker)

See [Hardening](deployment/hardening.md) for the full discussion of
trade-offs.

## Mail relay trust

- **`MAILX_RCPT`** is passed as a single quoted argument to `mail` (no
  `sh -c` wrapper). Treat it as trusted configuration; odd characters
  in addresses are discouraged.
- msmtp refuses to read its config file unless it is mode `0600`. Keep
  it tight.

## Repository write boundary

Multi-host writes are technically supported, but make sure you
understand the implications:

- Keep **`RESTIC_AUTO_UNLOCK=OFF`** (the default since 1.12.0).
  Otherwise a failed run on host A can clear host B's legitimate lock.
- Run `PRUNE_CRON` and `CHECK_CRON` from **exactly one** host /
  container to avoid lock thrashing.
- Consider using one repository per host instead, especially if the
  hosts have very different retention requirements.

## Reporting a vulnerability

Open a private security advisory at
[github.com/marc0janssen/restic-backup-helper/security/advisories](https://github.com/marc0janssen/restic-backup-helper/security/advisories)
or mail the maintainer (contact details in the [project README](https://github.com/marc0janssen/restic-backup-helper)).
Do not file a public issue for security-sensitive reports.

## See also

- [Supply chain](reference/supply-chain.md) — SBOM and Trivy.
- [Hardening](deployment/hardening.md) — orchestration-layer
  tightening.
- [Webhooks](configuration/webhooks.md) — masking rules and auth
  header handling.
