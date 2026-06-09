# TrueNAS Storage Setup Checklist

Use this checklist to decide whether to keep the bundled TrueNAS storage
example and to adapt it to your environment before bootstrap. The repo includes
example Kubernetes manifests for a `truenas-rwx` StorageClass, Omada RWX
storage, Longhorn NFS backups, and Longhorn RecurringJobs, but they are not
evidence that your TrueNAS system or cluster has already been configured.

## Bundled template manifests

Review and keep, edit, or remove these examples:

- `clusters/main/kubernetes/system/truenas-rwx/` - NFS-backed RWX StorageClass,
  PV, and PVC examples.
- `clusters/main/kubernetes/system/longhorn/app/` - Longhorn backup target and
  RecurringJob examples.
- `clusters/main/kubernetes/network/omada-controller/app/` - example service
  using a TrueNAS-backed existing PVC.
- `docs/truenas-storage.md` - deeper operational notes and troubleshooting.

If you do not use TrueNAS, remove `truenas-rwx/ks.yaml` from the system
`kustomization.yaml`, remove or replace the Longhorn backup target, and adjust
any services that reference `truenas-weave-pvc`.

## Required TrueNAS configuration

Complete these steps on your own TrueNAS system before enabling the bundled
manifests:

The commands use `storage_layer/weave` and `/mnt/storage_layer/weave` as sample
dataset/export names. Replace them with your own pool and dataset names.

### 1. Create Dataset Structure
```bash
# Via TrueNAS Shell
zfs create storage_layer/weave
zfs create storage_layer/weave/rwx
zfs create storage_layer/weave/longhorn-backups
zfs create storage_layer/weave/volsync
```

Or via TrueNAS UI:
- Storage → Pools → storage_layer → Add Dataset
- Create: `weave`, `weave/rwx`, `weave/longhorn-backups`, `weave/volsync`

### 2. Set Permissions
```bash
chmod 755 /mnt/storage_layer/weave
chmod 777 /mnt/storage_layer/weave/rwx
chmod 777 /mnt/storage_layer/weave/longhorn-backups
chmod 755 /mnt/storage_layer/weave/volsync
```

### 3. Configure NFS Export

**Via TrueNAS UI:**
1. Navigate to: **Sharing → Unix Shares (NFS)**
2. Click **Add**
3. Configure:
   - **Path:** `/mnt/storage_layer/weave`
   - **Description:** "Kubernetes cluster storage"
   
4. **Networks:** Add your cluster subnet or individual node IPs
   - Example: `192.168.1.0/24`
   - Or list each node IP separately
   
5. **Advanced Options:**
   - **Maproot User:** `root`
   - **Maproot Group:** `wheel`
   
6. **Enable NFSv4** (should be enabled by default)

7. Click **Save** and **Enable Service** if not already running

### 4. Verify Export

From a cluster node:
```bash
# Check export is visible
showmount -e truenas.yourdomain.com

# Test mount
mkdir -p /tmp/nfs-test
mount -t nfs -o nfsvers=4.1,hard,tcp truenas.yourdomain.com:/mnt/storage_layer/weave /tmp/nfs-test
ls -la /tmp/nfs-test
touch /tmp/nfs-test/test-file
rm /tmp/nfs-test/test-file
umount /tmp/nfs-test
```

## Deploy to cluster

After TrueNAS is configured and the manifests are adapted:

### 1. Commit and Push Changes
```bash
git add clusters/main/kubernetes/system/truenas-rwx/
git add clusters/main/kubernetes/system/longhorn/app/
git add clusters/main/kubernetes/network/omada-controller/app/
git add clusters/main/kubernetes/system/kustomization.yaml
git add docs/truenas-storage.md

git commit -m "Add TrueNAS storage integration

- Add truenas-rwx StorageClass for RWX persistent volumes
- Configure Longhorn backup target to TrueNAS NFS
- Add automated backup RecurringJobs (daily/weekly)
- Migrate Omada Controller to TrueNAS storage
- Add TrueNAS setup documentation"

git push
```

### 2. Reconcile Flux
```bash
# Force immediate reconciliation
flux reconcile source git cluster
flux reconcile kustomization flux-entry

# Watch for truenas-rwx to become ready
flux get ks -A | grep truenas
kubectl get storageclass truenas-rwx
kubectl get pv truenas-weave-pv
kubectl get pvc -n omada-controller truenas-weave-pvc
```

### 3. Verify Longhorn Configuration
```bash
# Check Longhorn settings after reconciliation
kubectl get settings.longhorn.io -n longhorn-system backup-target -o yaml

# Port-forward to Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Visit http://localhost:8080
# Navigate to: Settings → General → Backup Target
# Should show: nfs://truenas.yourdomain.com:/mnt/storage_layer/weave/longhorn-backups
```

### 4. Verify RecurringJobs
```bash
# Check recurring jobs after reconciliation
kubectl get recurringjobs.longhorn.io -n longhorn-system

# Example output after the template examples are applied:
# NAME                      AGE
# omada-daily-backup        Xm
# weekly-full-backup        Xm
```

### 5. Restart Omada Controller
```bash
# Omada needs restart to pick up new storage
kubectl delete pod -n omada-controller -l app.kubernetes.io/name=omada-controller

# Watch pod come back up
kubectl get pods -n omada-controller -w

# Check it can write to TrueNAS
kubectl exec -n omada-controller <pod-name> -- ls -la /omada/data /omada/work /omada/logs
```

## 🧪 Testing

### Test TrueNAS Storage Mount
```bash
# Check PVC is bound
kubectl get pvc -n omada-controller truenas-weave-pvc

# Check PV is bound
kubectl get pv truenas-weave-pv

# Verify mount in pod
kubectl exec -n omada-controller <omada-pod> -- df -h | grep omada
```

### Test Longhorn Backup
```bash
# Trigger manual backup via Longhorn UI
# or wait for scheduled backup (2 AM daily for Omada)

# Check backup status
kubectl get backups -n longhorn-system

# Verify files on TrueNAS
# On TrueNAS: ls -la /mnt/storage_layer/weave/longhorn-backups/
```

## Monitoring

### Check Backup Status
```bash
# Via Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# CLI - list all backups
kubectl get backups.longhorn.io -n longhorn-system

# Check specific backup
kubectl describe backup.longhorn.io -n longhorn-system <backup-name>
```

### Monitor TrueNAS Space
On TrueNAS:
```bash
# Check dataset usage
zfs list storage_layer/weave

# Set quota if needed
zfs set quota=500G storage_layer/weave/longhorn-backups
```

### Check Flux Status
```bash
# Overall cluster reconciliation
flux get ks -A

# Specific to storage
flux get ks -n flux-system truenas-rwx
flux get ks -n flux-system longhorn

# Check for errors
flux logs --kind=Kustomization --name=truenas-rwx
```

## Troubleshooting

If you encounter issues, see `docs/truenas-storage.md` section "Troubleshooting" for:
- NFS mount failures
- Permission denied errors
- Longhorn backup failures
- Variable substitution issues

Common quick fixes:
```bash
# Verify cluster-config has DOMAIN_0
kubectl get cm -n flux-system cluster-config -o yaml | grep DOMAIN_0

# Check Flux variable substitution enabled
kubectl get kustomization -n flux-system flux-entry -o yaml | grep postBuild -A5

# Restart Flux if needed
flux suspend kustomization flux-entry
flux resume kustomization flux-entry
```

## Next steps

After basic setup is working:

1. **Add more services to TrueNAS storage**
   - Copy PVC pattern from `truenas-rwx/app/pvc.yaml`
   - Update service HelmRelease to use `existingClaim`

2. **Set up Volsync for config backups**
   - Follow Volsync section in `docs/truenas-storage.md`
   - Create SSH keys and ReplicationSource CRs

3. **Test backup/restore procedures**
   - Perform test restore of Omada backup
   - Document restore procedures for your environment

4. **Monitor and tune**
   - Adjust RecurringJob schedules if needed
   - Set ZFS quotas based on actual usage
   - Consider snapshots on TrueNAS side for additional protection

## Template configuration summary

**Bundled examples:**

- **StorageClass:** `truenas-rwx` (cluster-wide)
- **PersistentVolume:** `truenas-weave-pv` → `/mnt/storage_layer/weave/rwx`
- **PersistentVolumeClaim:** `truenas-weave-pvc` in `omada-controller` namespace
- **Longhorn backup target:** `nfs://truenas.${DOMAIN_0}:/mnt/storage_layer/weave/longhorn-backups`
- **RecurringJobs:**
  - `omada-daily-backup` - 2 AM, 7 day retention
  - `weekly-full-backup` - Sunday 1 AM, 4 week retention

**Template files to review if you keep this integration:**

- `clusters/main/kubernetes/system/kustomization.yaml` - added truenas-rwx
- `clusters/main/kubernetes/system/longhorn/app/helm-release.yaml` - backup target
- `clusters/main/kubernetes/system/longhorn/app/kustomization.yaml` - recurring-jobs
- `clusters/main/kubernetes/network/omada-controller/app/helm-release.yaml` - TrueNAS storage

**Domain variable used:** `${DOMAIN_0}` (substituted by Flux from cluster-config ConfigMap)
