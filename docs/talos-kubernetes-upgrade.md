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

### iSCSI node-record preflight — for iSCSI-backed storage (e.g. Longhorn)

```bash
mise run iscsi-preflight        # must not print BLOCKED
```

Talos ships open-iscsi via an extension image, and different open-iscsi
releases have, in practice, renamed persisted node-record parameters between
point releases. Neither side of such a rename parses the other's records, and
`iscsiadm -m node` parses the **whole** node database in one pass — so **one
incompatible record can break every iSCSI volume attach on that node**, not
just the volume that wrote it.

Three properties make this worse than it first looks:

- `/var/lib/iscsi` is host state that **survives both upgrade and rollback**,
  so rolling back does not undo it.
- The extension's own version string is not a reliable signal — it is possible
  for it to stay the same across a schematic bump while the embedded
  open-iscsi payload changes underneath it. Don't trust `talosctl get
  extensions` to tell you which side of a boundary a node is on.
- It is **per-node persistent state, not a release-wide regression**: a canary
  node upgrading cleanly proves nothing about the others, because each node
  carries its own copy of `/var/lib/iscsi`.

The script ships with **no known version mapping configured** — it fails
closed (`UNDETERMINED`) rather than silently passing an unrecognised boundary.
Open `scripts/iscsi-record-preflight.sh` and fill in `talos_to_iscsi()` for
your own schematic before relying on this; the comment above that function
explains how to work out your own mapping.

**Clearing a BLOCKED node:** drain its storage workloads, then re-run the
preflight to verify both the node-record database and active sessions are
empty — don't assume workload eviction guarantees deletion of every historical
node record; that verification is what this script is for. Quarantining
records by hand (moving them aside, confirming `iscsiadm -m node` then exits
0, and only then upgrading) is the fallback for a node that will not detach
cleanly or crashed mid-drain, not the normal procedure — and it should stay a
manual, deliberate step rather than something scripted, since deleting a
record whose session is still serving a mounted filesystem can lose the mount.

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

`talosctl upgrade` cordon-drains the node before rebooting. Longhorn's default
`node-drain-policy` is `block-for-eviction-if-contains-last-replica`, so the
`instance-manager` pod's PodDisruptionBudget deliberately blocks eviction while
it still holds the *last* healthy replica of any volume, until Longhorn
rebuilds that replica elsewhere. The drain retries the eviction every few
seconds until the context times out, exiting with:

```
error draining node "k8s-worker-N": error when evicting pods/"instance-manager-...":
context deadline exceeded
```

**That wait is correct behaviour, not a fault — do not delete the
instance-manager to "unstick" it.** Deleting it defeats the exact protection
the PDB exists to provide: if it's still holding a volume's only healthy
replica, killing it drops that volume to zero healthy copies instead of
letting the rebuild finish. The installer has already written the new image
and set `LoaderEntryDefault` before the drain starts, so the upgrade itself
is not lost while you wait — only the drain and reboot steps remain.

**First, tell a legitimate wait from a genuine deadlock — they look identical
for the first minute or two,** both showing the same `evicting pod …` retry.
Check whether it's progressing:

```bash
# volumes that still lack a healthy replica anywhere other than <node> —
# this count must be falling, not static
kubectl -n longhorn-system get volumes.longhorn.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.robustness}{"\n"}{end}' \
  | grep -v "healthy"

# replicas still running on the node being drained — this count must also fall
kubectl -n longhorn-system get replicas.longhorn.io \
  -o jsonpath='{range .items[*]}{.spec.nodeID}{" "}{.metadata.name}{"\n"}{end}' \
  | grep '^<node> '
```

If both counts are falling, it's rebuilding — wait it out; the interval is
throttled by `concurrent-replica-rebuild-per-node-limit` and can legitimately
take well past a short drain timeout on a node with many volumes.

If the "lacking a healthy replica elsewhere" count is already `0` **and** the
blocked pod set isn't shrinking, the drain cannot succeed on its own — the
instance-manager is blocked by something else with no failover target (for
example another PodDisruptionBudget-protected workload pinned to the same
node with no replica or standby elsewhere). Deleting the instance-manager
still isn't the fix here: find and resolve that other blocker (move or scale
the conflicting workload off the node, or provision a failover target for it)
and let the drain re-evaluate, rather than removing the protection.

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
