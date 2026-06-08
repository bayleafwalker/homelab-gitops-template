# Storage Troubleshooting Guide

## Overview

This guide provides troubleshooting procedures for common storage-related issues in the cluster, focusing on Longhorn distributed storage and VolSync backup systems.

## Table of Contents

- [Longhorn Storage Issues](#longhorn-storage-issues)
- [VolSync Backup Issues](#volsync-backup-issues)
- [PVC Provisioning Issues](#pvc-provisioning-issues)
- [Performance Troubleshooting](#performance-troubleshooting)
- [Monitoring and Alerts](#monitoring-and-alerts)

## Longhorn Storage Issues

### Volume Stuck in Detached State

**Symptoms:**
- Volume shows `detached` state in `kubectl get volumes.longhorn.io -n longhorn-system`
- Pods using the volume fail to start with mount errors
- Applications report storage unavailability

**Investigation:**

```bash
# Check volume status
kubectl get volumes.longhorn.io -n longhorn-system <volume-name> -o yaml

# Check Longhorn manager logs
kubectl logs -n longhorn-system longhorn-manager-* | grep -i <volume-name>

# Check node status where volume should be attached
kubectl get nodes
kubectl describe node <node-name>

# Check Longhorn UI for volume details
```

**Remediation:**

1. **Manual Reattach:**
   ```bash
   # Find the volume and manually attach it
   kubectl get volumes.longhorn.io -n longhorn-system <volume-name> -o yaml
   # Edit the volume to set nodeID to desired node
   ```

2. **Restart Longhorn Manager:**
   ```bash
   kubectl rollout restart deployment -n longhorn-system longhorn-manager
   ```

3. **Check Node Conditions:**
   ```bash
   kubectl describe node <node-name> | grep -A 10 "Conditions"
   ```

### Volume Stuck in Unknown Robustness

**Symptoms:**
- Volume shows `robustness: unknown`
- Volume may be detached or have replica issues
- Storage operations may be slow or failing

**Investigation:**

```bash
# Check volume details
kubectl get volumes.longhorn.io -n longhorn-system <volume-name> -o yaml

# Check replicas
kubectl get replicas.longhorn.io -n longhorn-system | grep <volume-name>

# Check Longhorn events
kubectl get events -n longhorn-system | grep -i <volume-name>
```

**Remediation:**

1. **Check Replica Health:**
   ```bash
   kubectl get replicas.longhorn.io -n longhorn-system -o wide
   ```

2. **Rebuild Unhealthy Replicas:**
   ```bash
   # Find unhealthy replicas and delete them (Longhorn will rebuild)
   kubectl delete replica.longhorn.io -n longhorn-system <unhealthy-replica-name>
   ```

3. **Increase Replica Count (if needed):**
   ```bash
   # Edit the volume to increase replica count
   kubectl edit volume.longhorn.io -n longhorn-system <volume-name>
   ```

## VolSync Backup Issues

### Mount Timeout Errors

**Symptoms:**
- `volsync-src-*` pods stuck in `Error` or `ContainerCreating` state
- Pod logs show: `MountVolume.MountDevice failed for volume "pvc-*" : rpc error: code = DeadlineExceeded`
- Backup jobs fail to complete

**Investigation:**

```bash
# Check failing pods
kubectl get pods -A | grep volsync | grep -v Running

# Get detailed pod information
kubectl describe pod -n <namespace> <pod-name>

# Check volume status
kubectl get volumes.longhorn.io -n longhorn-system <volume-name>

# Check job status
kubectl get jobs -n <namespace> <job-name>
```

**Remediation:**

1. **Immediate Fix - Restart Pod:**
   ```bash
   kubectl delete pod -n <namespace> <pod-name>
   ```

2. **Increase Mount Timeout:**
   - Edit volsync HelmRelease to add pod annotations:
   ```yaml
   values:
     podAnnotations:
       "kubernetes.io/volume-mount-timeout": "10m"
   ```

3. **Check Longhorn Performance:**
   ```bash
   # Check for slow volume operations
   kubectl logs -n longhorn-system longhorn-manager-* | grep -i slow
   
   # Check worker node resource usage
   kubectl describe node <worker-node> | grep -A 10 "Allocated resources"
   ```

4. **Resource Limits:**
   - Add resource requests/limits to volsync pods:
   ```yaml
   resources:
     requests:
       memory: "512Mi"
       cpu: "500m"
     limits:
       memory: "1Gi"
       cpu: "1"
   ```

### Backup Job Failures

**Symptoms:**
- VolSync jobs show `Failed` status
- Pods complete but exit with non-zero status
- Backup repository may be corrupted or inaccessible

**Investigation:**

```bash
# Check job status
kubectl get jobs -n <namespace> <job-name>

# Check job logs
kubectl logs -n <namespace> job/<job-name>

# Check ReplicationSource status
kubectl describe replicationsource -n <namespace> <name>
```

**Remediation:**

1. **Check Restic Repository:**
   ```bash
   # Find a running volsync pod with restic access
   RUNNING_POD=$(kubectl get pods -n <namespace> -l app.kubernetes.io/created-by=volsync --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n <namespace> $RUNNING_POD -- restic -r /restic/repo snapshots
   ```

2. **Manual Backup Trigger:**
   ```bash
   # Delete and recreate the ReplicationSource to trigger new backup
   kubectl delete replicationsource -n <namespace> <name>
   # Wait for Flux to recreate it
   ```

3. **Repository Repair:**
   ```bash
   # If repository is corrupted, may need to initialize new repository
   # Backup existing data first, then:
   kubectl exec -n <namespace> $RUNNING_POD -- restic -r /restic/repo init
   ```

## PVC Provisioning Issues

### PVC Stuck in Pending State

**Symptoms:**
- PVC shows `Pending` status
- No volume bound to PVC
- Applications waiting for storage cannot start

**Investigation:**

```bash
# Check PVC details
kubectl get pvc -n <namespace> <pvc-name> -o yaml

# Check StorageClass
kubectl get storageclass <storage-class-name> -o yaml

# Check for available PVs
kubectl get pv
```

**Common Causes and Solutions:**

1. **WaitForFirstConsumer Binding Mode:**
   - **Symptom**: StorageClass has `volumeBindingMode: WaitForFirstConsumer`
   - **Solution**: Create a pod that requests the PVC, or change binding mode

2. **No Matching StorageClass:**
   - **Symptom**: StorageClass doesn't exist or doesn't match PVC requirements
   - **Solution**: Create appropriate StorageClass or update PVC

3. **Insufficient Capacity:**
   - **Symptom**: Cluster doesn't have enough storage for requested size
   - **Solution**: Add more storage nodes or reduce PVC size

4. **Manual Provisioning Required:**
   - **Symptom**: StorageClass uses `kubernetes.io/no-provisioner`
   - **Solution**: Manually create PV that matches PVC requirements

### Example: Trigger Provisioning for WaitForFirstConsumer

```bash
# Create a temporary pod to trigger provisioning
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: trigger-provisioning
  namespace: <namespace>
spec:
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: <pvc-name>
EOF

# After PVC is bound, delete the trigger pod
kubectl delete pod -n <namespace> trigger-provisioning
```

## Performance Troubleshooting

### Slow Volume Operations

**Symptoms:**
- Applications report slow I/O operations
- Volume mounting takes longer than expected
- Backup operations timeout or take excessive time

**Investigation:**

```bash
# Check Longhorn volume performance
kubectl get volumes.longhorn.io -n longhorn-system <volume-name> -o yaml

# Check node resource usage
kubectl top nodes
kubectl top pods -n longhorn-system

# Check for disk pressure
kubectl describe node <node-name> | grep -A 5 "DiskPressure"

# Check Longhorn metrics (if Prometheus monitoring enabled)
```

**Remediation:**

1. **Check Replica Distribution:**
   ```bash
   # Ensure replicas are distributed across different nodes
   kubectl get replicas.longhorn.io -n longhorn-system -o wide
   ```

2. **Adjust Replica Count:**
   ```bash
   # For performance-critical volumes, consider reducing replica count
   kubectl edit volume.longhorn.io -n longhorn-system <volume-name>
   ```

3. **Node Resource Optimization:**
   - Ensure worker nodes have sufficient CPU/memory for storage operations
   - Consider dedicating nodes for storage workloads

4. **Schedule During Off-Peak:**
   - Move backup operations to low-usage periods
   - Update ReplicationSource schedules

## Monitoring and Alerts

### Key Metrics to Monitor

```bash
# VolSync pod health
kubectl get pods -A -l app.kubernetes.io/created-by=volsync

# Longhorn volume status
kubectl get volumes.longhorn.io -n longhorn-system

# PVC provisioning status
kubectl get pvc -A --sort-by=.status.phase

# Storage capacity usage
kubectl get pvc -A --sort-by=.status.capacity
```

### Recommended Alerts

```yaml
# Example Prometheus alert rules for storage monitoring

# Alert on failed VolSync pods
- alert: VolSyncPodFailed
  expr: kube_pod_status_phase{phase="Failed", pod=~"volsync-.*"} == 1
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "VolSync pod failed"
    description: "VolSync pod {{ $labels.pod }} in {{ $labels.namespace }} has failed"

# Alert on pending PVCs
- alert: PVCPending
  expr: kube_persistentvolumeclaim_status_phase{phase="Pending"} == 1
  for: 30m
  labels:
    severity: warning
  annotations:
    summary: "PVC pending provisioning"
    description: "PVC {{ $labels.persistentvolumeclaim}} in {{ $labels.namespace }} has been pending for 30+ minutes"

# Alert on Longhorn volume issues
- alert: LonghornVolumeUnhealthy
  expr: longhorn_volume_robustness != "healthy"
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Longhorn volume unhealthy"
    description: "Longhorn volume {{ $labels.volume }} has robustness: {{ $value }}"
```

### Monitoring Dashboard Recommendations

1. **Longhorn Dashboard**: Monitor volume health, capacity, and performance
2. **Storage Capacity**: Track PVC usage and growth trends
3. **Backup Status**: Monitor VolSync job completion and duration
4. **Node Storage**: Track disk usage and I/O performance on worker nodes

## Best Practices

### Backup Strategy

1. **Regular Verification**: Periodically verify backup integrity
2. **Multiple Retention Policies**: Use daily/weekly/monthly backup retention
3. **Offsite Backups**: Consider configuring VolSync to backup to remote storage
4. **Monitor Backup Duration**: Track backup job duration for performance trends

### Storage Configuration

1. **Appropriate Replica Count**: Balance between data safety and performance
2. **Volume Size**: Right-size volumes to avoid waste and performance issues
3. **StorageClass Selection**: Choose appropriate storage class for workload requirements
4. **Resource Limits**: Set appropriate resource limits for storage-intensive pods

### Troubleshooting Workflow

1. **Identify Symptoms**: Clearly define what's not working
2. **Gather Information**: Collect logs, events, and status from relevant components
3. **Isolate Issue**: Determine if it's storage, network, or application problem
4. **Test Remediation**: Apply fixes in order of least to most invasive
5. **Monitor Results**: Verify the fix resolves the issue without side effects
6. **Document**: Record the issue and solution for future reference

## Reference Commands

### Common Storage Commands

```bash
# List all PVCs with status
kubectl get pvc -A -o wide

# List Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system

# List VolSync resources
kubectl get replicationsources,replicationdestinations -A

# Check storage capacity
kubectl get pvc -A --sort-by=.status.capacity

# Find pods using specific PVC
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{.spec.volumes[?(@.persistentVolumeClaim.claimName=="<pvc-name>")].persistentVolumeClaim.claimName}{"\n"}{end}' | grep <pvc-name>
```

### Debugging Commands

```bash
# Get detailed volume information
kubectl get volumes.longhorn.io -n longhorn-system <volume-name> -o yaml

# Get Longhorn manager logs
kubectl logs -n longhorn-system longhorn-manager-* --tail=100

# Get CSI driver logs
kubectl logs -n longhorn-system csi-attacher-* --tail=50

# Check node disk usage
kubectl describe node <node-name> | grep -A 20 "Allocated resources"
```

## Additional Resources

- [Longhorn Documentation](https://longhorn.io/docs/)
- [VolSync Documentation](https://volsync.readthedocs.io/)
- [Kubernetes Storage Documentation](https://kubernetes.io/docs/concepts/storage/)
- [Restic Documentation](https://restic.readthedocs.io/)

## Change Log

- **2026-02-15**: Initial version based on cluster health check findings
- Added VolSync mount timeout troubleshooting
- Added PVC provisioning patterns
- Added performance troubleshooting section