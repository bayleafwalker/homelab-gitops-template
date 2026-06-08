
# homelab-gitops-template

A full-reference GitOps template for a Talos-based Kubernetes homelab managed by Flux, SOPS/age, and either TrueCharts/TrueForge ClusterTool or a direct Talos/Flux workflow. It is meant to be copied, renamed, and trimmed to your hardware and services. Flux continuously reconciles the desired state under `clusters/main`, while secrets stay encrypted with SOPS/age.

This is an independent template. It is not an official TrueCharts or TrueForge
distribution, although many included examples depend on TrueCharts charts and
ClusterTool-compatible configuration files.

## Stack at a glance

- Talos/Kubernetes: `clusters/main/talos/talconfig.yaml` defines the machine config (Talos v1.13.3, Kubernetes v1.36.1) with network values pulled from the encrypted `clusterenv.yaml`.
- GitOps: Flux controllers come from the OCI manifest repo `ghcr.io/fluxcd/flux-manifests` (`clusters/main/kubernetes/repositories/oci/flux-manifests.yaml`, tag v2.8.8). `clusters/main/kubernetes/flux-system/flux` holds bootstrap assets; `flux-entry.yaml` reconciles `clusters/main/kubernetes` with SOPS decryption and substitution from `cluster-config` and `upgrade-settings`.
- Sources: Helm, Git and OCI repositories live under `clusters/main/kubernetes/repositories/`; TrueCharts is the primary catalog (`clusters/main/kubernetes/repositories/helm/truecharts.yaml`, `clusters/main/kubernetes/repositories/git/truecharts.yaml`) alongside mirrors for networking, storage and monitoring charts.
- Networking/routing: Cilium CNI (kube-proxy replacement), MetalLB + `core/metallb-config` for L2 pools, Cilium Gateway API HTTP routing, plus supporting services like Blocky, Tailscale, Mosquitto, and Omada.
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

## First cluster path

Start with **[`docs/onboarding.md`](docs/onboarding.md)**. It lists the decisions
you must make before bootstrap: node inventory, LAN/VIP/LB ranges, domain/DNS,
S3 object storage, NFS shares, and which bundled services to keep.

Then use this short loop:

1. Install pinned tools and inspect required edits:
   ```bash
   mise install
   ./scripts/quickstart.sh
   ./scripts/check-repo.sh
   ```
2. Generate your local age key and update `.sops.yaml`:
   ```bash
   ./scripts/setup-encryption.sh
   ```
3. Replace placeholders in `clusters/main/clusterenv.yaml`,
   `clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml`,
   `cluster-secrets.secret.yaml`, `deploykey.secret.yaml`, and the services you
   plan to keep. The template ships with placeholder `*.secret.yaml` files so it
   can be public; do not commit your real values until they are SOPS-encrypted.
4. Size `clusters/main/talos/talconfig.yaml` to your actual node count, then
   generate/apply Talos machine configs with ClusterTool or the direct
   talhelper/talosctl path:
   ```bash
   clustertool genconfig
   # or: talhelper genconfig
   ```
5. Create the in-cluster `sops-age` secret out-of-band, bootstrap Flux, and
   reconcile. The exact commands and ordering are in
   **[`docs/bootstrapping.md`](docs/bootstrapping.md)**.

Useful local helpers:

- `./scripts/sops-files.sh list|check|encrypt|decrypt` — common SOPS file loops.
- `./scripts/configure-starter.sh --help` — apply common first-run parameters such as domain, repo, LAN, S3, and TrueNAS values.
- `./scripts/check-repo.sh` — deeper local consistency checks before bootstrap or commit.
- `mise run validate` — root Kustomize build.

## Routine updates

- Talos/Kubernetes: bump versions in `talconfig.yaml` and `flux-system/flux/upgradesettings.yaml`, regenerate machine configs and commit; System Upgrade Controller plans orchestrate rollouts.
- Flux: update `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` to move controller versions.
- Charts/apps: adjust `spec.chart.spec.version` in the relevant HelmRelease and reconcile.
- Secrets: keep all sensitive data encrypted with `sops` (see `.sops.yaml` rules and `./scripts/sops-files.sh`).

## Documentation

- `docs/onboarding.md` — **start here if you're new**: the values, dependencies, and services to decide before bootstrap.
- `docs/bootstrapping.md` — step-by-step guide to standing up a 1-2 node cluster from this template.
- `docs/architecture.md` — core architecture and components.
- `docs/template-publishing.md` — template-readiness, TrueCharts dependency, upstream-reference, and publishing/license assessment.
- `docs/operations.md` — bootstrap and day-2 workflows.
- `docs/releases.md` — version pinning and upgrade guidance.
- `docs/secrets.md` — SOPS/age usage and secret handling.
- `docs/prompt-guide.md` — prompts and entrypoint for AI-assisted changes.

## License

[MIT](LICENSE) — use this template freely for your own homelab. External charts,
tools, images, and linked documentation keep their own licenses; see
[`docs/template-publishing.md`](docs/template-publishing.md) before publishing a
derived public template.
