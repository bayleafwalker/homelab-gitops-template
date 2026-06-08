# Baseline NetworkPolicies

This repo is moving toward “default-deny per namespace” with explicit allows for:
- DNS egress (CoreDNS)
- Ingress from the Gateway dataplane (for services exposed via Gateway API `HTTPRoute`)
- Minimal egress required by the workload (e.g., HTTPS to public endpoints for probes/backups)

## Kubernetes API access (important)

Many controllers/operators (CNPG, VolSync, cert-manager, etc.) must talk to the Kubernetes API.

In this cluster, the API can be reached via:
- The Service `kubernetes.default` (ClusterIP `172.17.0.1:443`)
- The control-plane node IP on `:6443`

### Prefer selector-based allows where possible

When allowing egress to the API, prefer a selector-based `NetworkPolicy` that targets the `kube-apiserver` pod in `kube-system` (rather than hard-coding IP blocks). This is more stable across IP changes and avoids surprises with hostNetwork routing.

### If egress to node IP is still blocked under Cilium

We observed a failure mode where pods under default-deny could resolve DNS but could not connect to the API via the control-plane node IP (`:6443`) until an explicit Cilium policy allowed egress to host/remote-node.

Mitigation used here:
- A `CiliumClusterwideNetworkPolicy` allows egress to `toEntities: [host, remote-node]` on ports `443` and `6443` for selected namespaces.

This policy lives in `clusters/main/kubernetes/system/networkpolicies/app/` and is intended to cover the “pod → node IP” path in a Cilium-managed dataplane.

## Hardening guidance

- Avoid broad CIDRs for VPN ranges (e.g., `100.64.0.0/10`) in allowlists. Prefer explicit `/32` node IPs or selectors.
- If you must allow node access, restrict ports to the minimum required.

## Talos / node IP stability

We hit an outage when the control-plane advertised a Tailscale IP as the node `InternalIP`, breaking “pod → apiserver” connectivity.

Mitigation used here:
- Pin kubelet `node-ip` to the LAN address in Talos (see `clusters/main/talos/patches/controlplane.yaml`).

## Troubleshooting checklist

If a namespace goes unhealthy after applying default-deny:

1) Confirm DNS still works from a pod in that namespace.
2) Confirm API connectivity:
   - `curl -k https://kubernetes.default.svc` (expect `401` unauthenticated)
   - `curl -k https://<control-plane-LAN-IP>:6443` (expect `401`)
3) If DNS works but API times out, check:
   - NetworkPolicy egress rules in that namespace
   - Whether the Cilium CCNP for host/remote-node egress is applied
4) Verify Flux is actually applying your latest commit (GitRepository revision and Kustomization lastAppliedRevision).

## Rollout strategy (recommended)

1) Start with *new* namespaces (lowest blast radius).
2) Apply:
   - `default-deny` (Ingress+Egress)
   - `allow-dns`
   - app-specific allows (Gateway API ingress, HTTPS egress, API access, etc.)
3) Verify health, then expand to additional namespaces one-by-one.

## Current Enforcement Status

Baseline `default-deny` coverage now exists for most workload namespaces, with manifests under:
- `clusters/main/kubernetes/system/networkpolicies/app/`

`gatus` now runs in Track A steady state:
- Namespace-wide `default-deny` is active for `gatus` with explicit DNS and ingress allowances.
- `gatus` monitors internal service paths only (`*.svc.cluster.local`).
- Edge/public-path monitoring is owned by `blackbox-exporter`.
- Internal monitoring uses explicit cross-namespace ingress allows from `gatus`:
  - `apps-homepage-allow-ingress-gatus-internal.cnp.yaml`
  - `authentik-allow-ingress-gatus-internal.cnp.yaml`
  - `nextcloud-allow-ingress-gatus-internal.cnp.yaml`
  - `paperless-allow-ingress-gatus-internal.cnp.yaml`
- Core `gatus` baseline policies:
  - `gatus-default-deny.yaml`
  - `gatus-allow-dns.yaml`
  - `gatus-allow-ingress-cilium-gateway.cnp.yaml`
  - `gatus-internal-allow-egress-core-services.cnp.yaml`
- Ongoing validation and diagnostics should use the consolidated maintenance script:
  - `bash docs/scripts/gatus-maintenance.sh validate-internal-all`
  - `bash docs/scripts/gatus-maintenance.sh diagnose-hairpin`

Use live commands rather than static lists for current coverage:
- `direnv exec . kubectl get networkpolicy -A`
- `direnv exec . kubectl get ciliumnetworkpolicy -A`

## Namespace expectations

Some policies target namespaces for services that may be intentionally disabled (e.g. `vaultwarden`). To keep GitOps reconciliation stable, this repo includes lightweight `Namespace` manifests alongside the policies so the policy bundle can apply cleanly even when the corresponding app is not deployed.
