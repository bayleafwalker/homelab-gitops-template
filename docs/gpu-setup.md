# NVIDIA GPU Enablement Guide

This walks through passing an NVIDIA GPU through to a Talos worker node and
making it available to a workload in the cluster (e.g. a media server doing
hardware transcoding, or an AI/ML workload doing inference).

Substitute your own node name, IP, and GPU model for the examples below —
this guide was written against a GeForce GTX 1060 3GB on a node named
`k8s-gpu-1`, but the steps generalize to any consumer NVIDIA GPU.

## Hardware
- **GPU**: NVIDIA GeForce GTX 1060 3GB (GP106) — *example; substitute your card*
- **PCI Address**: 0000:07:00.0 — *example; find yours with `lspci | grep -i nvidia`*
- **Node**: k8s-gpu-1 — *example; substitute your worker's name*

## Template changes to review

### 1. Talos Configuration (talconfig.yaml)
Enable GPU support on the target worker node:
- **NVIDIA Extensions**:
  - `siderolabs/nonfree-kmod-nvidia-lts` - NVIDIA kernel modules
  - `siderolabs/nvidia-container-toolkit-lts` - Container runtime support
- **GPU Patch**: `@./patches/gpu.yaml` - Kernel modules and sysctls

### 2. Kubernetes RuntimeClass
Create an NVIDIA RuntimeClass at `kube-system/nvidia-runtimeclass.yaml`:
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```

### 3. Workload Configuration
Point any GPU-consuming workload's HelmRelease/Deployment at the GPU:
- RuntimeClass: `nvidia`
- Resource limit: `nvidia.com/gpu: 1`

## Deployment Steps

### Step 1: Regenerate Talos Configuration
The worker node needs a new schematic with NVIDIA extensions:

```bash
cd <repo-root>/clusters/main/talos

# Generate new configs with NVIDIA extensions
talosctl genconfig --with-secrets talsecret.yaml

# This will create a new schematic ID with NVIDIA extensions
# The schematic will be embedded in the generated config
```

### Step 2: Apply New Configuration to Worker Node
```bash
# Apply config (will trigger reboot with new schematic)
talosctl -n <node-ip> apply-config --file generated/main-<node-name>.yaml

# Monitor reboot
watch kubectl get nodes

# Check for NVIDIA modules after reboot
talosctl -n <node-ip> read /proc/modules | grep nvidia
```

### Step 3: Verify NVIDIA Installation
```bash
# Check if NVIDIA device plugin is running
kubectl get pods -n kube-system | grep nvidia

# Check GPU resources on node
kubectl describe node <node-name> | grep nvidia.com/gpu

# Verify RuntimeClass
kubectl get runtimeclass nvidia
```

### Step 4: Deploy RuntimeClass and Reconcile the Workload
```bash
# Commit and push changes
git add -A
git commit -m "Enable NVIDIA GPU support for <workload> transcoding/inference"
git push

# Reconcile Flux
flux reconcile source git cluster
flux reconcile kustomization flux-entry

# Restart the workload to pick up the GPU
kubectl rollout restart -n <namespace> deployment <deployment>
```

## Verification

### Check GPU is Available
```bash
# Inside the workload's pod
kubectl exec -n <namespace> -it $(kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app> -o jsonpath='{.items[0].metadata.name}') -- nvidia-smi

# Should show:
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 5xx.xx       Driver Version: 5xx.xx       CUDA Version: xx.x    |
# |-------------------------------+----------------------+----------------------+
# | GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
# | Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
# |===============================+======================+======================|
# |   0  GeForce GTX 106...  Off  | 0000:07:00.0     Off |                  N/A |
```

### Configure In-App Hardware Acceleration
Most apps that use a GPU (media servers for transcoding, ML/AI tools for
inference) need an in-app setting in addition to the Kubernetes-level wiring.
For a media server with NVENC support, that typically looks like:
1. Open the app's dashboard → playback/transcoding settings
2. **Hardware Acceleration**: select the NVIDIA/NVENC option
3. **Enable hardware decoding** for the codecs you need (H264, HEVC, VP9, etc.)
4. **Enable hardware encoding** (NVENC) for your target codecs
5. Save and test

Consult your specific app's documentation for the exact menu names.

### Test Under Load
```bash
# Monitor GPU usage while the workload is active
watch -n 1 'kubectl exec -n <namespace> $(kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app> -o jsonpath="{.items[0].metadata.name}") -- nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv'

# Should show GPU utilization while the workload is running
```

## Troubleshooting

### GPU Not Detected
```bash
# Check NVIDIA modules loaded
talosctl -n <node-ip> read /proc/modules | grep nvidia

# Check device plugin logs
kubectl logs -n kube-system -l app=nvidia-device-plugin

# Check node has GPU resource
kubectl get node <node-name> -o json | jq '.status.capacity'
```

### Workload Can't Access GPU
```bash
# Check pod is using NVIDIA runtime
kubectl get pod -n <namespace> -o yaml | grep runtimeClassName

# Check GPU allocation
kubectl describe pod -n <namespace> | grep -A 5 "nvidia.com/gpu"

# Check container runtime
kubectl exec -n <namespace> -it <pod> -- ls -la /dev | grep nvidia
```

### NVML libraries missing
```bash
# Confirm NVML is installed on the worker
talosctl -n <node-ip> list /usr/local/lib | grep libnvidia-ml
talosctl -n <node-ip> list /usr/lib | grep libnvidia-ml
talosctl -n <node-ip> list /usr/local/glibc/lib64 | grep libnvidia-ml
```
If `libnvidia-ml.so.*` is absent, the NVIDIA user-space driver artifacts were not installed. Make sure the worker schematic pulls in the full NVIDIA utility extension or rerun the bundled `/usr/local/bin/nvidia-installer` so that `/usr/lib/libnvidia-ml.so.*` and the supporting symlinks exist. Once those libraries land in `/usr/lib` and `/usr/lib64`, the device plugin can run in `nvml` mode (our config change) and use the newly added hostPath mounts to see the driver backends.

### Schematic Issues
If schematic generation fails or doesn't include NVIDIA extensions:
```bash
# Check talconfig.yaml syntax
cd clusters/main/talos
talenv genconfig validate

# Manually verify schematic at https://factory.talos.dev/
# Use the schematic ID from generated config
```

## Expected Performance Improvement
With a GTX 1060 3GB-class card, NVENC hardware transcoding typically delivers:
- **4K HEVC → 1080p H264**: ~6-8 streams simultaneously
- **1080p → 720p**: ~10-12 streams
- **CPU usage**: Reduces from 80-100% to 10-20% per stream
- **Power efficiency**: Significantly better than CPU transcoding

## Notes
- The GTX 1060 3GB supports NVENC (6th gen) with H264 and HEVC encoding
- Concurrent stream limit: ~2-3 streams (NVIDIA driver limitation on consumer GPUs)
- For more streams, consider NVIDIA Quadro or datacenter GPUs
- The GPU is a node-level resource and can be shared across any workload that requests it

## Rollback
If GPU causes issues:
```bash
# Revert talconfig.yaml changes
git revert <commit>

# Disable GPU on the workload
kubectl edit helmrelease -n <namespace> <release>
# Comment out workload.main.podSpec.runtimeClassName

# Apply clean config without NVIDIA extensions
cd clusters/main/talos
# Edit talconfig.yaml to comment out NVIDIA extensions
talosctl genconfig --with-secrets talsecret.yaml
talosctl -n <node-ip> apply-config --file generated/main-<node-name>.yaml
```
