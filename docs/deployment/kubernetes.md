# Kubernetes

A full single-Pod manifest (Deployment + Secret + PVC, FUSE-friendly
capabilities, strong liveness probe and pre-wired `METRICS_DIR`) ships
at [`examples/kubernetes/restic-backup-helper.yaml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/kubernetes/restic-backup-helper.yaml).

This page summarises the production-relevant choices in that manifest
and the typical adaptations for different cluster shapes.

## Why a Deployment

Cron lives inside the container, so what Kubernetes schedules is **one
long-running Pod** with cron firing inside, not a `CronJob`. A `CronJob`
would re-create the container on every tick which loses:

- The Restic cache (`/.cache/restic`).
- The `last-*.json` files (unless persisted out to a PV that survives
  the Pod).
- Most of the helper's locking guarantees.

A `Deployment` (or `StatefulSet`) with `replicas: 1` is the right shape.

## Reference manifest shape

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: restic-password
type: Opaque
data:
  restic_password: dXNlLWEtc3Ryb25nLXNlY3JldA==

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restic-cache
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restic-logs
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restic-backup-helper
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: restic-backup-helper
  template:
    metadata:
      labels:
        app: restic-backup-helper
    spec:
      hostname: backup-node
      containers:
        - name: restic-backup-helper
          image: marc0janssen/restic-backup-helper:2.9.0-0.18.1
          imagePullPolicy: IfNotPresent
          env:
            - name: RESTIC_REPOSITORY
              value: s3:https://s3.example.com/bucket/restic
            - name: RESTIC_PASSWORD_FILE
              value: /run/secrets/restic_password
            - name: RESTIC_TAG
              value: backup-node-data
            - name: BACKUP_CRON
              value: "0 2 * * *"
            - name: BACKUP_ROOT_DIR
              value: /data
            - name: RESTIC_JOB_ARGS
              value: "--exclude-file /config/exclude_files.txt --one-file-system"
            - name: RESTIC_FORGET_ARGS
              value: "--retry-lock=5m --keep-daily 7 --keep-weekly 5 --keep-monthly 12"
            - name: CHECK_CRON
              value: "37 3 * * 0"
            # Optional: opt into the dedicated /bin/forget worker
            # (since 2.5.0). When set, /bin/backup skips its inline
            # forget and this worker owns the exclusive lock window.
            # - name: FORGET_CRON
            #   value: "30 1 * * *"
            - name: PRUNE_CRON
              value: "0 4 * * 0"
            - name: METRICS_DIR
              value: /var/log/textfile_collector
            - name: TZ
              value: Europe/Amsterdam
          securityContext:
            runAsUser: 0
            capabilities:
              drop: [ALL]
              add: [DAC_READ_SEARCH, SYS_ADMIN]
            readOnlyRootFilesystem: false
            allowPrivilegeEscalation: false
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - restic cat config >/dev/null 2>&1 || exit 1
            initialDelaySeconds: 60
            periodSeconds: 900
            timeoutSeconds: 30
          volumeMounts:
            - name: restic-password
              mountPath: /run/secrets
              readOnly: true
            - name: config
              mountPath: /config
              readOnly: true
            - name: data
              mountPath: /data
              readOnly: true
            - name: cache
              mountPath: /.cache/restic
            - name: logs
              mountPath: /var/log
      volumes:
        - name: restic-password
          secret:
            secretName: restic-password
            items:
              - key: restic_password
                path: restic_password
        - name: config
          configMap:
            name: restic-config
        - name: data
          hostPath:
            path: /srv/documents
            type: Directory
        - name: cache
          persistentVolumeClaim:
            claimName: restic-cache
        - name: logs
          persistentVolumeClaim:
            claimName: restic-logs
```

`hostPath` is the simplest way to mount backup sources from the host but
ties the Pod to a specific node. For real clusters consider:

- A dedicated `PersistentVolume` per source, with appropriate
  `nodeAffinity`.
- A `Daemonset` so every node runs its own helper Pod backing up its
  own local volumes.

## Adaptations

### Bring-your-own SMTP

Add an env var, a ConfigMap with `msmtprc` and a volumeMount:

```yaml
env:
  - name: MAILX_RCPT
    value: ops@example.com
  - name: MAILX_ON_ERROR
    value: "ON"
volumeMounts:
  - name: msmtp
    mountPath: /etc/msmtprc
    subPath: msmtprc
    readOnly: true
volumes:
  - name: msmtp
    configMap:
      name: restic-msmtp
      items:
        - key: msmtprc
          path: msmtprc
```

### Webhook (healthchecks.io)

```yaml
env:
  - name: WEBHOOK_URL
    valueFrom:
      secretKeyRef:
        name: restic-webhook
        key: url
  - name: WEBHOOK_TIMEOUT
    value: "15"
```

### Prometheus textfile metrics

The reference manifest already sets `METRICS_DIR=/var/log/textfile_collector`
and persists `/var/log` on a PVC. To scrape, run node-exporter as a
sidecar in the same Pod with `--collector.textfile.directory=/textfile_collector`
and a shared `emptyDir` (or the same PVC).

### Hooks

Ship hooks via a ConfigMap with `defaultMode: 0o755`:

```yaml
volumeMounts:
  - name: hooks
    mountPath: /hooks
    readOnly: true
volumes:
  - name: hooks
    configMap:
      name: restic-hooks
      defaultMode: 0755
```

`ConfigMap` keys become filenames inside `/hooks`. Use one ConfigMap key
per hook script (`pre-backup.sh`, `post-backup.sh`, …).

## What about `CronJob`?

A `CronJob` could in theory replace `BACKUP_CRON`. Trade-offs:

| Concern | Long-running Deployment (this image) | Kubernetes `CronJob` |
| --- | --- | --- |
| Cache locality | PVC persists across runs. | PVC needs to be `ReadWriteMany` or a sidecar to share the cache. |
| `last-*.json` persistence | PVC. | PVC, but tricky to mount RWX. |
| Locking | `flock` + Restic's own lock. | Need `concurrencyPolicy: Forbid`. |
| Hooks & notifications | Built in. | Need to re-implement at the manifest level. |
| Restic auto-init | Built into the entrypoint. | Need an init container. |
| Restore / snapshot-export / forget-preview / mount-snapshot | `kubectl exec -it … /bin/restore …`, `/bin/forget-preview` and `/bin/mount-snapshot` work. | Need a one-shot Pod for standalone runs. |

In practice the long-running Deployment shape is what most users want.
If you absolutely need `CronJob` semantics, you are probably better off
running raw `restic backup` from a custom image and re-implementing the
helper's plumbing — there is not much benefit to mixing the two.

## Hardening

For the full `securityContext`, network policies and admission controller
matrix, see [Hardening](hardening.md).
