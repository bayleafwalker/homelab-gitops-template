
# homelab

GitOps repository for a Talos-based Kubernetes cluster managed by Flux and TrueForge (clustertool) tooling. Flux continuously reconciles the desired state under `clusters/main`, while secrets stay encrypted with SOPS/age.

## Stack at a glance

- Talos/Kubernetes: `clusters/main/talos/talconfig.yaml` defines the machine config (Talos v1.13.3, Kubernetes v1.36.1) with network values pulled from the encrypted `clusterenv.yaml`.
- GitOps: Flux controllers come from the OCI manifest repo `ghcr.io/fluxcd/flux-manifests` (`clusters/main/kubernetes/repositories/oci/flux-manifests.yaml`, tag v2.8.8). `clusters/main/kubernetes/flux-system/flux` holds bootstrap assets; `flux-entry.yaml` reconciles `clusters/main/kubernetes` with SOPS decryption and substitution from `cluster-config` and `upgrade-settings`.
- Sources: Helm, Git and OCI repositories live under `clusters/main/kubernetes/repositories/`; TrueCharts is the primary catalog (`clusters/main/kubernetes/repositories/helm/truecharts.yaml`, `clusters/main/kubernetes/repositories/git/truecharts.yaml`) alongside mirrors for networking, storage and monitoring charts.
- Networking/ingress: Cilium CNI (kube-proxy replacement), MetalLB + `core/metallb-config` for L2 pools, Traefik (TrueCharts) and nginx internal/external ingress controllers, plus supporting services like Blocky and Omada.
- Storage & data safety: Longhorn and OpenEBS CSI, snapshot-controller, Volsync, and System Upgrade Controller plans in `core/system-upgrade-controller-plans`.
- Observability/ops: kube-prometheus-stack, Prometheus Operator, metrics-server, node-feature-discovery, descheduler and Spegel image cache.
- Service health model: `gatus` is used for in-cluster service checks (`*.svc.cluster.local`) with explicit cross-namespace policy allows; edge/public-path probes remain in blackbox-exporter.

## Repository layout

```
.
├── .sopsrc                    # Points to the local Age key used for SOPS encryption
├── docs/                      # Documentation index and guides
├── repositories/              # Source definitions for Helm, Git and OCI feeds
└── clusters/main
    ├── talos/                 # Talos cluster configuration and patches
    └── kubernetes/            # All Kubernetes manifests organised by function
        ├── flux-system/       # Flux bootstrap manifests and upgrade settings
        ├── flux-entry.yaml    # Top-level Kustomization reconciling the cluster state
        ├── core/, system/     # Platform services (SUC, cert-manager, storage, monitoring, etc.)
        ├── network/, apps/    # Workloads and ingress/controllers
        └── repositories/      # Secondary Git/Helm/OCI sources consumed by Flux
```

## Quick start

New to this template or bootstrapping your first 1-2 node cluster? Start with
**[`docs/bootstrapping.md`](docs/bootstrapping.md)** — it walks through every
step below in more depth, including how to size `talconfig.yaml` for a small
cluster. Run `./scripts/quickstart.sh` at any point to check what's still left
to customize (placeholders, missing keys, build errors).

0. Install pinned local tools:
   ```bash
   mise install
   mise run validate
   ./scripts/quickstart.sh
   ```
1. Prepare Talos config and secrets: edit `clusters/main/talos/talconfig.yaml` and `clusterenv.yaml` (with `sops`) to set addresses, domains and versions. Keep all secrets encrypted—only encrypted files are committed.
2. Generate Flux secrets: create Age keys (`.sopsrc`), `sops-age`, and the deploy key secrets under `clusters/main/kubernetes/flux-system/flux`, encrypt them with `sops`.
3. Bootstrap GitOps:
   - With clustertool: `clustertool talos bootstrap` (applies Talos, installs Flux, reconciles sources/releases).
   - Or Flux directly:
     ```bash
     flux bootstrap git \
       --url=ssh://git@github.com/your-username/your-homelab-repo.git \
       --branch=main \
       --path=clusters/main/kubernetes/flux-system/flux \
       --private-key-file=./deploy-key
     ```
4. Reconcile: `flux reconcile source git cluster && flux reconcile kustomization flux-entry` after changes.

## Routine updates

- Talos/Kubernetes: bump versions in `talconfig.yaml` and `flux-system/flux/upgradesettings.yaml`, regenerate machine configs and commit; System Upgrade Controller plans orchestrate rollouts.
- Flux: update `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` to move controller versions.
- Charts/apps: adjust `spec.chart.spec.version` in the relevant HelmRelease and reconcile.
- Secrets: keep all sensitive data encrypted with `sops` (see `.sops.yaml` rules).

## Documentation

- `docs/bootstrapping.md` — **start here if you're new**: step-by-step guide to standing up a 1-2 node cluster from this template.
- `docs/architecture.md` — core architecture and components.
- `docs/operations.md` — bootstrap and day-2 workflows.
- `docs/releases.md` — version pinning and upgrade guidance.
- `docs/secrets.md` — SOPS/age usage and secret handling.
- `docs/prompt-guide.md` — prompts and entrypoint for AI-assisted changes.

## License

[MIT](LICENSE) — use this template freely for your own homelab.
