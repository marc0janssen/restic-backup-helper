# restic-backup-helper Helm chart

Official-style chart for deploying [`marc0janssen/restic-backup-helper`](https://github.com/marc0janssen/restic-backup-helper) as a long-running **Deployment** (internal cron), aligned with [`examples/kubernetes/restic-backup-helper.yaml`](https://github.com/marc0janssen/restic-backup-helper/blob/develop/examples/kubernetes/restic-backup-helper.yaml).

## Prerequisites

- Kubernetes 1.22+
- Helm 3.10+

## Quick install

From the repository root:

```bash
helm install backup ./charts/restic-backup-helper \
  --namespace backup --create-namespace \
  --set-string credentials.resticPassword="$RESTIC_PASSWORD" \
  --set-string environment.RESTIC_REPOSITORY='s3:https://s3.example.com/bucket/restic' \
  --set-string environment.RESTIC_TAG=daily \
  --set-string volumeSource.hostPath=/srv/data
```

Use an existing Secret (keys `restic-password`, optional `msmtprc`):

```bash
helm install backup ./charts/restic-backup-helper \
  --namespace backup --create-namespace \
  --set credentials.create=false \
  --set-string credentials.existingSecret=my-restic-secret \
  --set-string environment.RESTIC_REPOSITORY='s3:https://s3.example.com/bucket/restic'
```

## Values overview

| Area | Key |
| --- | --- |
| Image | `image.repository`, `image.tag`, `image.pullPolicy` |
| Credentials | `credentials.create`, `credentials.existingSecret`, `credentials.resticPassword`, `credentials.msmtprc`, `credentials.mountMsmtprc` |
| Env | `environment` map (empty values omitted), `extraEnv` |
| Logs / cache | `persistence.logs`, `persistence.cache` |
| Data to back up | `volumeSource` (`hostPath`, `pvc`, `emptyDir`) |
| Files under `/config` | `configMap.enabled`, `configMap.data` |
| Probes | `probes.liveness`, `probes.readiness` (default liveness is local scheduler health: `cron.log` + `crond`) |

See `values.yaml` for defaults and comments.

## Documentation

- [Kubernetes deployment guide](https://marc0janssen.github.io/restic-backup-helper/deployment/kubernetes/) (project docs site)
- [Environment variables](https://marc0janssen.github.io/restic-backup-helper/configuration/environment-variables/)
