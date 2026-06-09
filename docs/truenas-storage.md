# TrueNAS Storage Integration Guide

This guide documents the integration of TrueNAS permanent storage with the Kubernetes cluster.

## Overview

The cluster uses TrueNAS to provide:
1. **Shared RWX storage** - ReadWriteMany persistent volumes for services needing multi-pod access
2. **Longhorn backups** - Automated backup target for all Longhorn-managed volumes
3. **Volsync targets** - Point-in-time backup destinations for critical application data

## TrueNAS NFS Export Configuration

### Dataset Structure
```
/mnt/storage_layer/weave/
├── rwx/                    # Shared storage for K8s services (RWX PVCs)
├── longhorn-backups/       # Longhorn backup target
└── volsync/               # Volsync backup destinations
    ├── omada/
    └── <app-name>/
```

### Required NFS Export Settings

The commands below use `/mnt/storage_layer/weave` as an example dataset path.
Replace it with your own pool/dataset before applying anything to a real
TrueNAS host.

Export `/mnt/storage_layer/weave` from TrueNAS with the following configuration:

**Path:** `/mnt/storage_layer/weave`

**Network/Hosts:** 
- Add all cluster node IPs (or use subnet range)
- Example: `192.168.1.0/24` or individual IPs

**Permissions:**
- Read/Write access enabled
- `maproot=root` (or `no_root_squash` equivalent)
- This allows Kubernetes pods running as root to write properly

**NFS Options:**
```
vers=4.1
hard
tcp
```

**Protocol:** NFSv4 (NFSv4.1 specifically)

**Security:** 
- sys (AUTH_SYS) authentication is sufficient for home lab
- For production, consider Kerberos or NFSv4 ACLs

### TrueNAS Configuration Steps

1. **Create Dataset**
   ```bash
   # In TrueNAS Shell or via UI
   zfs create storage_layer/weave
   zfs create storage_layer/weave/rwx
   zfs create storage_layer/weave/longhorn-backups
   zfs create storage_layer/weave/volsync
   ```

2. **Set Permissions**
   ```bash
   chmod 755 /mnt/storage_layer/weave
   chmod 777 /mnt/storage_layer/weave/rwx
   chmod 777 /mnt/storage_layer/weave/longhorn-backups
   chmod 755 /mnt/storage_layer/weave/volsync
   ```

3. **Configure NFS Share via TrueNAS UI**
   - Navigate to: Sharing → Unix Shares (NFS)
   - Click "Add"
   - Path: `/mnt/storage_layer/weave`
   - Add authorized networks: Your cluster subnet or node IPs
   - Advanced Options:
     - Maproot User: `root`
     - Maproot Group: `wheel` (or appropriate root group)
   - Enable NFSv4
   - Save and enable the share

4. **Verify Export**
   ```bash
   # From a cluster node
   showmount -e truenas.yourdomain.com
   # Should show: /mnt/storage_layer/weave
   
   # Test mount
   mkdir -p /tmp/nfs-test
   mount -t nfs -o nfsvers=4.1,hard,tcp truenas.yourdomain.com:/mnt/storage_layer/weave /tmp/nfs-test
   ls -la /tmp/nfs-test
   umount /tmp/nfs-test
   ```

## Kubernetes Storage Configuration

### StorageClass: truenas-rwx

Located at: `clusters/main/kubernetes/system/truenas-rwx/app/pvc.yaml`

This provides a reusable StorageClass for services that need shared storage across multiple pods.

**Usage Pattern:**
1. StorageClass is cluster-wide (`truenas-rwx`)
2. Create PV pointing to NFS path
3. Create PVC in target namespace
4. Reference PVC in HelmRelease via `existingClaim`

**Example for new service:**
```yaml
# Add to truenas-rwx/app/pvc.yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <service-name>-pvc
  namespace: <namespace>
spec:
  storageClassName: truenas-rwx
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Mi
```

Then in HelmRelease:
```yaml
persistence:
  data:
    enabled: true
    existingClaim: <service-name>-pvc
```

### Longhorn Backup Configuration

**Backup Target:** `nfs://truenas.${DOMAIN_0}:/mnt/storage_layer/weave/longhorn-backups`

Configured in: `clusters/main/kubernetes/system/longhorn/app/helm-release.yaml`

**Automated Backup Schedule:**
- **Daily backups** (2 AM): Omada Controller - 7 day retention
- **Weekly backups** (Sunday 1 AM): All volumes - 4 week retention

**RecurringJobs:** Defined in `clusters/main/kubernetes/system/longhorn/app/recurring-jobs.yaml`

**Manual Backup/Restore:**
```bash
# View backups via Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# CLI backup (example)
kubectl exec -n longhorn-system <longhorn-manager-pod> -- \
  longhorn-manager backup create <volume-name>

# Restore from backup
# Via Longhorn UI: Backup → Select backup → Restore
```

## Current Services Using TrueNAS Storage

### Omada Controller
- **PVC:** `truenas-weave-pvc` in `omada-controller` namespace
- **Mount paths:**
  - `/omada/data` - Configuration and database
  - `/omada/work` - Working directory
  - `/omada/logs` - Application logs
- **Backup:** Daily at 2 AM, 7 day retention

### Other RWX Workloads
- **StorageClass:** `<app>-nfs` (per-app NFS exports, see `system/truenas-rwx/app/pvc.yaml`)
- Used for any application needing shared/large-volume storage outside Longhorn

## Volsync Integration (Future)

For application-level backups independent of Longhorn:

1. Create SSH key pair for TrueNAS access:
   ```bash
   ssh-keygen -t ed25519 -f volsync-truenas-key -C "volsync@cluster"
   ```

2. Add public key to TrueNAS user with access to `/mnt/storage_layer/weave/volsync`

3. Create SOPS-encrypted secret in app namespace:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: volsync-ssh-secret
     namespace: <app-namespace>
   type: Opaque
   stringData:
     source: |
       -----BEGIN OPENSSH PRIVATE KEY-----
       <private key content>
       -----END OPENSSH PRIVATE KEY-----
     source.pub: <public key>
   ```

4. Create ReplicationSource:
   ```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationSource
   metadata:
     name: <app>-backup
     namespace: <app-namespace>
   spec:
     sourcePVC: <pvc-name>
     trigger:
       schedule: "0 4 * * *"  # 4 AM daily
     rsyncTLS:
       sshKeys: volsync-ssh-secret
       address: truenas.${DOMAIN_0}
       path: /mnt/storage_layer/weave/volsync/<app>
       copyMethod: Snapshot
     retain:
       daily: 7
       weekly: 4
   ```

## Troubleshooting

### NFS Mount Issues

**Symptom:** Pods stuck in `ContainerCreating` with mount errors

**Check:**
```bash
# On cluster node
showmount -e truenas.yourdomain.com

# Check node can mount
mount -t nfs -o nfsvers=4.1 truenas.yourdomain.com:/mnt/storage_layer/weave /mnt/test

# Check pod events
kubectl describe pod <pod-name> -n <namespace>
```

**Common fixes:**
- Verify NFS service is running on TrueNAS
- Check firewall allows NFS (port 2049)
- Verify export permissions include cluster nodes
- Ensure `maproot=root` is set

### Permission Denied Errors

**Symptom:** Pods can mount but can't write files

**Fix:**
```bash
# On TrueNAS
chmod 777 /mnt/storage_layer/weave/rwx
# Or set proper ownership for the app's UID/GID
```

### Longhorn Backup Failures

**Check backup target:**
```bash
# Via Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Visit http://localhost:8080 → Settings → Backup Target

# Check connectivity from longhorn pods
kubectl exec -n longhorn-system <longhorn-manager-pod> -- \
  mount -t nfs truenas.yourdomain.com:/mnt/storage_layer/weave/longhorn-backups /tmp/test
```

**Verify NFS path exists and is writable:**
```bash
# On TrueNAS
ls -la /mnt/storage_layer/weave/longhorn-backups
chmod 777 /mnt/storage_layer/weave/longhorn-backups
```

### Variable Substitution Issues

**Symptom:** Literal `${DOMAIN_0}` in resource instead of actual domain

**Check:**
```bash
# Verify flux-entry has variable substitution enabled
kubectl get kustomization -n flux-system flux-entry -o yaml

# Check cluster-config ConfigMap
kubectl get cm -n flux-system cluster-config -o yaml
```

## Maintenance

### Monitoring Backup Space
```bash
# On TrueNAS
zfs list storage_layer/weave
df -h /mnt/storage_layer/weave/longhorn-backups

# Set up ZFS quota if needed
zfs set quota=500G storage_layer/weave/longhorn-backups
```

### Backup Verification
```bash
# List Longhorn backups
kubectl get backups -n longhorn-system

# Test restore periodically
# 1. Create test namespace
# 2. Restore backup to new volume
# 3. Verify data integrity
# 4. Clean up
```

### Rotating Volsync Backups
```bash
# On TrueNAS, old snapshots are retained based on ReplicationSource spec
# Manual cleanup if needed:
find /mnt/storage_layer/weave/volsync -type d -mtime +30 -exec rm -rf {} \;
```

## Migration Path

To migrate existing Longhorn PVCs to TrueNAS:

1. **Backup existing volume** via Longhorn
2. **Create TrueNAS PVC** for the service
3. **Update HelmRelease** to reference new PVC
4. **Restore data** manually if needed:
   ```bash
   kubectl cp <old-pod>:/data/. /tmp/backup
   # Update HelmRelease, wait for new pod
   kubectl cp /tmp/backup/. <new-pod>:/data
   ```
5. **Verify** service functionality
6. **Delete old PVC** after confirming migration

## References

- [Longhorn Backup & Restore](https://longhorn.io/docs/latest/snapshots-and-backups/backup-and-restore/)
- [Kubernetes NFS Persistent Volumes](https://kubernetes.io/docs/concepts/storage/volumes/#nfs)
- [Volsync Documentation](https://volsync.readthedocs.io/)
- Project docs: `docs/service-deployment-guide.md`
