# VolSync backups (Restic → Hetzner S3)

VolSync is used for “high value / low volume” PVCs (mostly config + small app data) and is stored off-cluster in Hetzner Object Storage (S3-compatible) using Restic encryption + retention.

## What is backed up

ReplicationSources (GitOps-managed, VolSync):
- `apps/homepage-config`
- `authentik/authentik-data`
- `authentik/authentik-media` (weekly; larger)
- `kube-prometheus-stack/storage-kube-prometheus-stack-grafana-0`
- `mosquitto/mosquitto-data`
- `nextcloud/nextcloud-data` (daily; large NFS source)
- `obsidian/obsidian-config`
- `omada-controller/omada-controller-data` (weekly; larger)
- `omada-controller/omada-controller-work` (weekly; larger)
- `paperless/paperless-data`
- `vaultwarden/vaultwarden-data`
- `registry/registry-data`

These are defined in:
- `clusters/main/kubernetes/apps/homepage/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/apps/authentik/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/apps/vaultwarden/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/apps/obsidian/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/network/mosquitto/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/apps/nextcloud/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/network/omada-controller/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/apps/paperless/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/system/registry/app/volsync-hetzner.yaml`
- `clusters/main/kubernetes/system/kube-prometheus-stack/app/volsync-hetzner.yaml`

### Workspace PVC backup (restic CronJob)

`vscode/truenas-workspace-pvc` is backed up by a restic `CronJob` (not a VolSync `ReplicationSource`) because VolSync 0.9 removed exclude-pattern support and the workspace contains large ephemeral trees that must be excluded.

- **Schedule:** daily at 03:55 UTC
- **Excludes:** `node_modules`, `.venv`, `__pycache__`, `.pytest_cache`, `.cache`, `dist`, `build`, `.eggs`, `*.egg-info`, `.tools`, `homelab/tmp`
- **Restic repo path:** `volsync/vscode/workspace-projects` (same Hetzner S3 bucket as all other backups)
- **Restore drill:** `ReplicationDestination/workspace-projects-restore-drill` runs on the 1st of each month and exercises a full restore into a 20 Gi temp Longhorn PVC, then cleans it up.
- **Manifests:** `clusters/main/kubernetes/apps/vscode/app/workspace-backup.yaml`

## Where backups live

Each ReplicationSource has its own Restic repo path:
- `s3:https://${HETZNER_S3_BUCKET_ENDPOINT}/${HETZNER_S3_BUCKET_NAME}/volsync/<namespace>/<pvc-name>`

## Health checks

```bash
kubectl get replicationsource -A
kubectl get replicationdestination -A
kubectl -n <ns> describe replicationsource <name>
kubectl -n <ns> get jobs,pods | rg -i volsync
```

Prometheus also scrapes `system/backup-observability`, which exports `homelab_volsync_replicationsource_last_sync_timestamp` and alerts when a ReplicationSource has no successful sync or is stale for more than 36 hours.

## Runbook: mover pod stuck in `ContainerCreating`

Symptoms:
- VolSync mover pod (e.g. `volsync-src-…`) sits in `ContainerCreating` / `Pending`.
- Pod events show `FailedAttachVolume` with messages like `volume <pvc-…> is not ready for workloads`.

Checklist:
1) Look at pod events:
```bash
kubectl -n <ns> describe pod <volsync-pod>
```
2) Map the failing volume to the PVC:
```bash
kubectl -n <ns> get pod <volsync-pod> -o jsonpath='{range .spec.volumes[*]}{.name}{"\t"}{.persistentVolumeClaim.claimName}{"\n"}{end}'
kubectl -n <ns> get pvc <claim> -o wide
```
3) If it’s a Longhorn attach/readiness issue:
```bash
kubectl -n longhorn-system get volumes.longhorn.io <pvc-volume-name>
kubectl -n longhorn-system describe volumes.longhorn.io <pvc-volume-name>
```

Safe reset steps (VolSync-managed temp resources):
- Delete the mover Job (it will be recreated):
```bash
kubectl -n <ns> delete job -l app.kubernetes.io/created-by=volsync --wait=false
```
- Delete VolSync temp PVCs if present (names commonly include `volsync-…-src` and `volsync-src-…-cache`).

If the temp PVC is `Pending` with a CSI error about verifying the data source, and the message references a missing Longhorn volume (404 `volume.longhorn.io "pvc-…" not found`):
- This usually indicates a stale `VolumeSnapshotContent` referencing a deleted Longhorn volume handle.
- Delete the stale snapshot objects and let VolSync recreate fresh ones:
```bash
kubectl -n <ns> delete volumesnapshot <name> --wait=false
kubectl delete volumesnapshotcontent <name> --wait=false
```

Then either wait for the next schedule, or trigger a manual sync:
```bash
kubectl -n <ns> patch replicationsource <name> --type=merge -p '{"spec":{"trigger":{"manual":"trigger-<timestamp>"}}}'
```

If the source PVC is an RWX/NFS claim and the Restic cache PVC is landing on Longhorn as `RWX`, force the cache to `ReadWriteOnce` so VolSync uses a direct-attached block volume instead of a Longhorn share-manager export:
```yaml
spec:
  restic:
    copyMethod: Direct
    cacheStorageClassName: longhorn
    cacheAccessModes:
      - ReadWriteOnce
```

After Flux applies the change, delete the old cache PVC once so VolSync can recreate it with the new access mode:
```bash
kubectl -n <ns> delete pvc volsync-src-<name>-cache
kubectl -n <ns> delete job -l app.kubernetes.io/created-by=volsync --wait=false
```

## Restore drill (recommended)

Restore drills are implemented as `ReplicationDestination` objects with a schedule and `cleanupTempPVC: true` (no permanent restore PVC is left behind).

Example (already implemented for several PVCs):

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: homepage-config-restore-drill
  namespace: apps
spec:
  trigger:
    schedule: "10 5 1 * *"
  restic:
    repository: volsync-restic-homepage-config
    copyMethod: None
    cleanupTempPVC: true
    cleanupCachePVC: true
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    capacity: 1Gi
```

To manually force a restore test, you can temporarily add a `manual` trigger (or create a one-off ReplicationDestination) and watch the VolSync mover job.

## What is NOT covered by VolSync

Notes:
- Databases should generally be backed up using DB-native tooling (e.g., CNPG backups) rather than raw PVC snapshots.
- `truenas-workspace-pvc` (namespace `vscode`) is covered by the restic CronJob described above, not a VolSync ReplicationSource. TrueNAS ZFS snapshots provide an additional layer of protection at the storage layer.
