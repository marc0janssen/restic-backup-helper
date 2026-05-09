# Backlog

Ideas and planned enhancements for **restic-backup-helper**. Ordering is not strict priority; tick items when shipped and note version/date like the done section.

---

## Done

- [x] Start time and date of container @20250312 1.6.54-0.17.3
- [x] Health check container @20250325 1.7.68-0.17.3
- [x] Cycle the cron.log (cycle, tar, delete after x) @20250326 1.7.68-0.17.3
- [x] Uniform date notations in all scripts @20250326 1.7.68-0.17.3

---

## Observability & notifications

- [ ] Optional **webhook** after backup / check / sync (HTTPS POST with exit code, duration, hostname; configurable URL + optional secret header).
- [ ] Optional **`last-run.json`** (or similar) under `/var/log` with timestamps and exit codes for external tooling.
- [ ] **Prometheus** metrics endpoint or simple **node_exporter textfile** companion doc (push gateway pattern).
- [x] Documented **Compose HEALTHCHECK** recipes (weak vs strong: `restic version` vs `restic cat config` / `snapshots`) — 1.11.3-0.18.1.

---

## Restic & scheduling

- [ ] First-class **`RESTIC_CACERT`** (or documented `--cacert`) wiring in backup/check entry paths without relying only on `RESTIC_JOB_ARGS`.
- [ ] Optional **separate cron for `prune`** (decouple retention from post-backup `forget`).
- [x] **`RESTIC_PASSWORD_FILE`** + **Docker/Kubernetes secrets** as primary examples in README / Compose samples — 1.11.3-0.18.1.
- [ ] Pre/post **hook timeouts** and clearer logging of hook exit codes (today hooks run without enforced timeout).

---

## Security & supply chain

- [ ] **Checksum-pinned** Rclone download in `install_rclone.sh` (verify archive before unzip).
- [ ] **SBOM** artifact on release builds (e.g. Syft / build attestations) alongside existing Trivy CI.
- [ ] Optional **read-only root** + **non-root** exploration doc (likely separate “slim” image or documented trade-offs vs FUSE/NFS/cron-as-root).

---

## UX & operations

- [x] **`config-check` mode**: entrypoint or script that validates env + critical paths/mounts and exits non-zero before starting cron (CI / smoke friendly) — 1.11.3-0.18.1.
- [x] Clearer behaviour when **`BACKUP_ROOT_DIR` is empty** (warn loudly or documented single recommended pattern) — 1.11.3-0.18.1.
- [ ] **`RESTIC_TAG`** ergonomics: stronger validation message or optional safe default policy (breaking change — needs semver note).

---

## Rclone sync

- [ ] Optional **one-way** sync jobs (`rclone sync` / `copy`) in addition to **`bisync`** (same or parallel job file format).
- [ ] **Per-job** extra args (not only global `SYNC_JOB_ARGS`) — syntax TBD (e.g. optional fourth column or ini-style sections).

---

## Multi-job / scale (larger changes)

- [ ] **Multiple named backup jobs** (different roots, tags, crons) in one container **or** official **multi-container Compose** pattern with shared repo env.
- [ ] **Helm chart** or **Compose profiles** (`minimal`, `backup+sync`, `dev`) to reduce copy-paste.

---

## Docs & CI

- [ ] **Kubernetes** example manifest: `Secret`/`env`, `SecurityContext`, optional `emptyDir` cache, no plaintext passwords in YAML.
- [x] **Private registry** troubleshooting (proxy `NO_PROXY`, TLS to LAN registry) in README FAQ — 1.11.3-0.18.1.
- [x] **Dependabot** (or Renovate) for GitHub Actions pin bumps — 1.11.3-0.18.1 (Dependabot weekly on `/`).
