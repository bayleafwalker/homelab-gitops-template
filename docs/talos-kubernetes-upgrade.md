# Talos + Kubernetes version upgrades

This repo upgrades Talos and Kubernetes via:
- Talos machine config generation in `clusters/main/talos/talconfig.yaml` (and `clusters/main/talos/generated/*.yaml` outputs).
- System Upgrade Controller (SUC) Plans in `clusters/main/kubernetes/core/system-upgrade-controller-plans/app/`, driven by substitutions from `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml`.

The SUC Plans are already configured to be safe-by-default:
- `spec.concurrency: 1` and `spec.exclusive: true` (one node at a time).
- Gate upgrades behind the node label `${UPGRADE_NODE_LABEL}=true` (sample value: `upgrade.example.com/enabled=true`).

## What changes for a version bump

1. Update versions in **both** places (they must stay aligned):
   - `clusters/main/talos/talconfig.yaml`
     - `talosVersion: vX.Y.Z`
     - `kubernetesVersion: vA.B.C`
   - `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml`
     - `TALOS_VERSION: vX.Y.Z`
     - `TALOS_INSTALLER_IMAGE_DEFAULT: factory.talos.dev/...:vX.Y.Z` (must match your schematic/extensions)
     - `TALOS_INSTALLER_IMAGE_NVIDIA: factory.talos.dev/...:vX.Y.Z` (only if you use a separate schematic for GPU nodes)
     - `KUBERNETES_VERSION: vA.B.C`

2. Regenerate Talos machine configs:
   - `clusters/main/talos/generated/main-k8s-control-*.yaml`
   - `clusters/main/talos/generated/main-k8s-worker-*.yaml`

3. Commit/push, then reconcile Flux:
   - `direnv exec . flux reconcile source git cluster`
   - `direnv exec . flux reconcile kustomization flux-entry`
   - (optional, faster) `direnv exec . flux reconcile kustomization system-upgrade-controller-plans -n flux-system`

## Pre-flight checks (before upgrading)

- Flux is healthy:
  - `direnv exec . flux get ks -A --status-selector ready=false`
  - `direnv exec . flux get hr -A --status-selector ready=false`
- Nodes are Ready:
  - `direnv exec . kubectl get nodes -o wide`
- SUC plans are present:
  - `direnv exec . kubectl -n system-upgrade get plan -o wide`

## One-by-one upgrade procedure

SUC is configured for one-at-a-time, but it doesn’t guarantee *which* eligible node goes next.
If you want a strict order, only enable one node at a time.

### Step 1: Talos OS upgrade (all nodes)

Enable upgrades on exactly one node:
```bash
direnv exec . kubectl label node <node> upgrade.example.com/enabled=true --overwrite
```

Confirm the Talos plan resolved the desired version:
```bash
direnv exec . kubectl -n system-upgrade get plan talos -o yaml | rg -n "spec:|  version:|latestVersion:"
```

Watch SUC jobs:
```bash
direnv exec . kubectl -n system-upgrade get jobs -w
```

Verify node Talos version after it returns:
```bash
direnv exec . talosctl -n <node-ip> version
direnv exec . kubectl get nodes -o wide
```

Repeat for each node (recommended order: control planes first, then workers). When done, keep the label enabled if you want future automated patch upgrades; otherwise remove it.

### Step 2: Kubernetes upgrade (control planes)

The `kubernetes` SUC plan runs `talosctl upgrade-k8s` on control plane nodes only.

Confirm it resolved the desired version:
```bash
direnv exec . kubectl -n system-upgrade get plan kubernetes -o yaml | rg -n "spec:|  version:|latestVersion:"
```

Watch SUC jobs and node versions:
```bash
direnv exec . kubectl -n system-upgrade get jobs -w
direnv exec . kubectl get nodes -o wide
```

## Applying updated machine configs (when required)

Upgrading Talos/Kubernetes versions in `talconfig.yaml` updates the **generated** machine configs, but Talos does not automatically pull those from Git.

Apply a generated machine config to a node (one at a time):
```bash
direnv exec . talosctl -n <node-ip> apply-config --mode=auto -f clusters/main/talos/generated/<node>.yaml
```

This is typically required to roll out kubelet image changes (`machine.kubelet.image`) and other config changes introduced by the generation.

## Known issues during node-by-node upgrades

### Longhorn instance-manager PDB blocks drain

`talosctl upgrade` cordon-drains the node before rebooting. Longhorn's
`instance-manager` pod has a PodDisruptionBudget that blocks eviction when
doing so would leave a volume replica under its minimum count. The drain will
loop indefinitely on the eviction until the context times out, exiting with:

```
error draining node "k8s-worker-N": error when evicting pods/"instance-manager-...":
context deadline exceeded
```

The installer has already written the new image and set `LoaderEntryDefault`
before the drain starts, so the upgrade is not lost — only the drain and reboot
steps remain.

**Resolution:**

1. Identify the stuck pod:
   ```bash
   kubectl get pod -n longhorn-system -o wide | grep instance-manager | grep <node>
   ```
2. Delete it (Longhorn will rebuild replicas on remaining nodes):
   ```bash
   kubectl delete pod -n longhorn-system <instance-manager-pod>
   ```
3. Check Longhorn volume health and wait for recovery:
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system \
     -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.robustness}{"\n"}{end}' \
     | grep -v "healthy\|unknown"
   ```
4. Reboot the node manually:
   ```bash
   talosctl reboot --nodes <node-ip>
   ```
5. Wait for Ready, then uncordon:
   ```bash
   kubectl wait --for=condition=Ready node/<node> --timeout=300s
   kubectl uncordon <node>
   ```

### EFI Boot entry with trailing null bytes (malformed device path)

Some nodes accumulate stale or firmware-quirky EFI boot entries where the
device path ends with extra `0000` null bytes after the end-of-path terminator.
The Talos installer enumerates all `Boot*` EFI variables to find old UKI
entries to clean up, and panics on any entry it cannot parse:

```
failed to install bootloader: failed to create boot entry:
failed to list existing Talos boot entries:
failed to get boot entry Boot000N: failed unmarshaling ExtraPath:
dangling bytes at the end of device path: 0000
```

The firmware itself boots fine with such an entry (it ignores trailing bytes),
so the node continues running normally. The installer fails after writing the
new UKI file and setting `LoaderEntryDefault` to it, but before creating the
EFI NVRAM boot entry.

**Detection:** `talosctl ls /sys/firmware/efi/efivars/ --nodes <ip>` will show
only `Boot0003` and `Boot0004` (or similar very low count) instead of the
usual set of named Talos entries.

**Resolution:** The `LoaderEntryDefault` is already pointing at the new UKI,
so a plain reboot is sufficient — sd-boot uses that variable and does not
require a specific NVRAM boot entry for the UKI itself:

```bash
kubectl cordon <node>
talosctl reboot --nodes <node-ip>
kubectl wait --for=condition=Ready node/<node> --timeout=300s
kubectl uncordon <node>
```

The node will come up on the new Talos version. The malformed `Boot000N` entry
remains but does not affect booting. It can be cleaned up by booting a rescue
environment with `efibootmgr` if desired.

## Post-upgrade health checks

- Cluster + Flux health:
  - `direnv exec . flux get ks -A --status-selector ready=false`
  - `direnv exec . flux get hr -A --status-selector ready=false`
- Nodes and core pods:
  - `direnv exec . kubectl get nodes -o wide`
  - `direnv exec . kubectl get pods -n kube-system`
- Optional: reconcile once more to clear transient drift:
  - `direnv exec . flux reconcile kustomization flux-entry`
