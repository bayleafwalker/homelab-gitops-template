# Cluster Troubleshooting Guide

Cross-cutting troubleshooting patterns that don't fit a single subsystem — networking,
external NFS storage, and Gateway/edge symptoms. These are distilled from recurring
real-world cluster investigations.

For storage-specific issues (Longhorn volumes, VolSync/restic backups, PVC provisioning,
stale `VolumeAttachment` recovery) see [storage-troubleshooting.md](storage-troubleshooting.md).
For Flux/GitOps drift, the readiness-aware health check, DNS/Gateway discovery delays, and
alert hygiene see [operations.md](operations.md).

## Table of Contents

- [NFS export ACL drift after node/subnet migration](#nfs-export-acl-drift-after-nodesubnet-migration)
- [Node-level stale NFS client (app healthy, I/O wedged)](#node-level-stale-nfs-client-app-healthy-io-wedged)
- [Cilium denies external NodePort / VIP traffic as `world`](#cilium-denies-external-nodeport--vip-traffic-as-world)
- [Gateway 502 / upstream-refusal vs backend crashloop](#gateway-502--upstream-refusal-vs-backend-crashloop)

## NFS export ACL drift after node/subnet migration

When you migrate worker nodes to a new subnet/VLAN (or add nodes), pods that reschedule
onto the migrated nodes can fail to mount TrueNAS NFS exports even though nothing in Git
changed. The TrueNAS export ACL still only allows the **old** node subnet, so the new
node's mount is refused.

**Symptoms:**
- `FailedMount` events on NFS-backed pods (media, downloads, anything on `truenas-rwx`/NFS PVs)
- Failures correlate with pods landing on freshly migrated/added nodes
- In-cluster manifests are unchanged — this is **external** storage-side drift

**Investigation:**

```bash
# Which pods are failing to mount, and on which node?
kubectl get pods -A -o wide | grep -v Running
kubectl get events -A --field-selector reason=FailedMount --sort-by=.lastTimestamp

# What does the export actually allow right now?
showmount -e truenas.yourdomain.com
```

**Remediation:**

```bash
# Add the new node subnet to the affected export ACLs (keep the legacy CIDR until the
# migration is fully complete so rollback coverage stays intact).
ssh <TRUENAS_HOST> 'midclt call sharing.nfs.update <SHARE_ID> \
  "{\"networks\":[\"<LEGACY_CIDR>\",\"<NEW_CIDR>\"]}"'

# Confirm both subnets are now accepted, then recreate the stuck pods
showmount -e <TRUENAS_NEW_SUBNET_IP>
kubectl -n <namespace> delete pod <affected-pods>
```

**Prevention:**
- Add "update TrueNAS NFS export ACLs" to the node/VLAN migration checklist.
- A migration preflight that compares Kubernetes NFS PV `server`/`path` values against
  TrueNAS export ACLs catches this before pods reschedule.
- Consider alerting on recurring `FailedMount` events for NFS-backed workloads.

## Node-level stale NFS client (app healthy, I/O wedged)

A subtler NFS failure: the application's own health endpoint stays **green** while any
real I/O against a shared NFS mount hangs. The mount handle on one node has gone stale
(common after a storage-path change, node migration, or a TrueNAS-side restart), so reads
against the shared export block indefinitely on the affected node only.

**Symptoms:**
- App reports healthy (`/health` 200) but user-facing requests time out
- Readiness/liveness probes intermittently time out without a clear crash
- Multiple pods that share the same NFS mount are affected **on the same node(s)**

**Investigation:**

```bash
# Bound a read against the shared mount; if it hangs, the client state is wedged
kubectl -n <namespace> exec <pod> -- timeout 5 stat /path/to/nfs/mount || echo "WEDGED"

# Prove it's node-local: a fresh mount from an unaffected node should work fine
kubectl get pods -A -o wide | grep <affected-mount-consumers>   # note the node
```

**Remediation:**
- Confirm a fresh mount works from an **unaffected** node (isolates it to node-level
  client state, not the export or the data).
- Recreate the affected pods so they get a clean mount; if I/O is still wedged, the node's
  NFS client needs recovery (drain/reboot the node out of band).
- For a GPU/single-home workload, a reversible scheduling workaround (temporarily move the
  pod to a healthy node) restores service while you recover the bad node.

## Cilium denies external NodePort / VIP traffic as `world`

A healthy in-cluster Service and a programmed Cilium NodePort/LoadBalancer can still time
out from outside the cluster. After NodePort/VIP DNAT, Cilium classifies the external
client's source as the `world` identity. If the destination pod's ingress policy (in a
default-deny namespace) doesn't allow `world` or an equivalent CIDR, the SYN is dropped at
the endpoint — the process is fine, the policy is the problem.

A closely related failure: when you **change a Service's ports**, the matching
NetworkPolicy allow-list does not move automatically. New ports get default-denied until
you add them to the policy.

**Symptoms:**
- `curl`/`docker push`/SSH to a NodePort or static VIP times out (often `ERR`/connection
  timeout), while in-cluster checks to the same Service succeed
- Pod, Service, and EndpointSlice all look healthy
- Recently added Service ports are unreachable while old ones still work

**Investigation:**

```bash
# In-cluster reachability is fine, external is not → suspect endpoint ingress policy
kubectl -n <namespace> get pod,svc,endpointslice

# Watch for policy-denied drops to the destination endpoint
CILIUM_POD=$(kubectl -n kube-system get pods -l k8s-app=cilium \
  --field-selector spec.nodeName=<node-owning-the-vip> -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- \
  cilium monitor --type drop --related-to <ENDPOINT_ID>

# Confirm the service map has backends for *all* expected ports
kubectl -n kube-system exec "$CILIUM_POD" -c cilium-agent -- cilium service list
```

**Remediation:**
- Add a **narrow, CIDR-scoped** ingress allow (approved LAN / tailnet ranges) to the
  destination port — do **not** open it to unrestricted `world`. Keep these policies in
  `clusters/main/kubernetes/system/networkpolicies` so Flux doesn't prune them. See
  [networkpolicies.md](networkpolicies.md).
- When changing Service ports, update the corresponding `allow-ingress-*` policy in the
  **same** change so the new ports are permitted as soon as they exist.
- For VIP-owning-node ingress specifically: a pod policy can allow remote-node forwarding
  paths yet still block direct `world` traffic to the node that owns the VIP — add `world`
  (or the client CIDR) explicitly if direct-to-VIP access is required.

> Raw NodePort exposure is typically the pod's **plain HTTP** listener. TLS/auth belong on
> the Gateway-routed hostname, not the raw NodePort.

## Gateway 502 / upstream-refusal vs backend crashloop

A user-facing `502` or `upstream connect error or disconnect/reset before headers` almost
always means the **backend** has no serving endpoint — not that the Gateway is broken.
Confirm the edge is healthy, then chase the backend.

**Symptoms:**
- Browser/`curl` returns 502 or "upstream connect error …"
- `HTTPRoute` is `Accepted`/`ResolvedRefs`, Gateway is `Programmed`

**Investigation:**

```bash
# Edge is fine if the route is admitted and the Gateway is programmed
kubectl get httproute -A
kubectl -n gateway get gateway internal -o wide

# The backend is the suspect: no ready endpoint, crashloop, or dead-node deadlock
kubectl -n <namespace> get pods,endpointslice -o wide
kubectl -n <namespace> describe pod <backend-pod>
kubectl -n <namespace> logs <backend-pod> --previous
```

**Common root causes:**
- Backend container crashlooping on a bad newer image digest behind the same tag — roll the
  HelmRelease back to the known-good revision (see GitOps drift in [operations.md](operations.md)).
- Dead-node rollout deadlock with stale `VolumeAttachment` — see
  [storage-troubleshooting.md](storage-troubleshooting.md#stale-volumeattachment-after-node-failure-dead-node-rollout-deadlock).
- Backend OOM/CrashLoop hidden behind a `Running` pod phase — use the readiness-aware query
  in [operations.md](operations.md).

> If the in-cluster Service path returns 200 but the **browser** fails (e.g.
> `ERR_TUNNEL_CONNECTION_FAILED`) for an internal-only hostname, the problem is on the
> client side (proxy, VPN, secure-DNS, or tunnel), not the cluster. Verify with an in-pod
> fetch and a `curl --resolve <host>:443:<gateway-ip>` from the workstation.
