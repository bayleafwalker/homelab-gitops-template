# Project instructions for AI agents

> Adapt this file to your own setup: rename `homelab` to your cluster's name throughout, and add any environment-specific notes (devbox vs. workstation, tool install persistence, mid-session cluster switching) that apply to how you work.

## Tech Stack

Primary: YAML/Kustomize (Kubernetes GitOps). Flux v2.8.8 for GitOps reconciliation. Talos v1.13.3 OS, Kubernetes v1.36.1. SOPS + age for secret encryption. Validation via `mise run validate`, `kustomize build`, and `./scripts/check-repo.sh`.

## Environment setup

### Required environment variables

| Variable | Path | Purpose |
|---|---|---|
| `KUBECONFIG` | `<repo-root>/clusters/.kube/config` | Cluster-scoped kubeconfig |
| `TALOSCONFIG` | `<repo-root>/clusters/.talos/config` | Cluster-scoped Talos config |
| `CLUSTER_NAME` | `homelab` | Cluster identifier (rename to match your own cluster) |

**Load:** `source .envrc` or `direnv allow` from repo root before running `kubectl`, `flux`, or `talosctl`.

Tool versions are pinned in `mise.toml`. Run `mise install` after entering the repo when setting up a new machine or shell.

**Validate before use:**
```bash
echo $KUBECONFIG    # must contain the repo path, not ~/.kube/config
echo $CLUSTER_NAME  # must be "homelab"
```

> Using the home-directory default kubeconfig silently targets the wrong cluster. Always verify `KUBECONFIG` points to the project path.

### Cluster context

Once bootstrapped, this cluster reconciles continuously via Flux — changes to `clusters/main/**` apply automatically after push. Target cluster: `homelab` (placeholder name; rename throughout to match your own). Use `direnv exec . <cmd>` in non-interactive shells.

## Development workflow

- Validate changes with `mise run validate` and `./scripts/check-repo.sh` before committing.
- Never commit invalid YAML — validate first.
- After committing, reconcile: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.
- Check status: `flux get ks -A`, `flux get hr -A`.
- Use `sops` for all secret edits — never commit plaintext secrets.
- Keep scope to `clusters/main/**` and `docs/**` unless explicitly requested otherwise.

### Self-healing test loop

If reconciliation fails after a change, diagnose the root cause (check `flux logs`, `kubectl describe`), fix, and re-push — up to **5 cycles** — before escalating. Only escalate if still failing after 5 attempts or if a design decision is required.

## Entrypoint
1. **Start here**: Read `README.md` and `docs/onboarding.md` first — they cover the human first-run path, required inputs, helper scripts, and pinned versions.
2. **Architecture**: Read `docs/architecture.md` before changing cluster structure.
3. **Service deployment**: Review `docs/service-deployment-guide.md` for comprehensive deployment patterns and operational workflows.
4. **Scope**: Keep changes to `clusters/main/**`, `docs/**`, and onboarding helper scripts unless explicitly requested otherwise.

## Mission
- GitOps repository for a Talos (v1.13.3) / Kubernetes (v1.36.1) cluster managed by Flux (v2.8.8) with TrueCharts and upstream Helm sources.
- `clusters/main/kubernetes/flux-entry.yaml` is the root Kustomization that reconciles cluster state with SOPS decryption and variable substitution from `cluster-config` and `upgrade-settings` ConfigMaps.
- All services follow a consistent pattern: `<category>/<service>/ks.yaml` → `<category>/<service>/app/` containing HelmRelease + supporting resources.

## Service Categories and Organization

Services are organized into functional categories:

- **apps/**: User applications (authentik, headlamp, homepage, vaultwarden, nextcloud, paperless, forgejo, custom examples)
- **core/**: Essential platform services (blocky, clusterissuer, metallb-config)
- **system/**: Infrastructure components (cert-manager, longhorn, openebs, kube-prometheus-stack, volsync)
- **network/**: Network services (gateway-api, tailscale, mosquitto, omada-controller)
- **kube-system/**: Kubernetes core (cilium, metrics-server, node-feature-discovery)

Each service follows the structure:
```
<category>/<service-name>/
├── ks.yaml                    # Flux Kustomization pointing to app/
└── app/
    ├── kustomization.yaml     # Lists all resources
    ├── helm-release.yaml      # HelmRelease with pinned version
    ├── namespace.yaml         # (optional)
    └── *.yaml                 # Additional resources
```

## Rules and Conventions

### Secrets Management
- **Always** use `sops` to edit secrets; commit only encrypted outputs.
- Never decrypt or commit plaintext secrets; Age key is in `.sopsrc`/`age.agekey`.
- Encrypted files use `.secret.yaml` suffix.
- Flux automatically decrypts using the `sops-age` secret in flux-system namespace.
- Template placeholder `*.secret.yaml` files may start unencrypted for onboarding; after inserting real values, encrypt them with `./scripts/sops-files.sh encrypt` before committing.

### Service Deployment
- Add new services under the appropriate category (`apps`, `core`, `system`, `network`, `media`).
- Create HelmRelease with **pinned** chart version (never wildcards or version ranges).
- Include the service's `ks.yaml` in the category's `kustomization.yaml`.
- Use existing Helm/Git/OCI sources from `clusters/main/kubernetes/repositories/**` — primarily TrueCharts.
- Enable cert-manager integration for services with ingress.
- Use `internal` ingressClassName for cluster-only services, `external` for public ones.

### Variable Substitution
- Use `${VARIABLE_NAME}` syntax for substitution (e.g., `${DOMAIN_0}`, `${TRAEFIK_IP}`).
- Variables come from the Flux substitution sources:
  - `cluster-config`: Domains, IPs, network ranges
  - `cluster-secrets`: Sensitive values
  - `upgrade-settings`: Talos and Kubernetes versions

### Version Management
- Chart versions: Pinned in `spec.chart.spec.version` of each HelmRelease.
- Talos/Kubernetes: Must be aligned in:
  - `clusters/main/talos/talconfig.yaml` (for machine config generation)
  - `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml` (for System Upgrade Controller)
- Flux version: Set in `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` (OCI tag).

### Development Workflow
- Prefer `rg` (ripgrep) for searches over `grep` or `find`.
- Use `mise run validate` to validate before committing.
- After commits, reconcile: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.
- Check status: `flux get ks -A`, `flux get hr -A`.
- View logs: `flux logs --kind=Kustomization --name=<name>` or `flux logs --kind=HelmRelease --name=<name> -n <namespace>`.
- Use the repo’s `direnv` config (`.envrc`) to ensure you’re targeting the right cluster before running `kubectl`/`talosctl`/`flux` (sets `KUBECONFIG=clusters/.kube/config` and `TALOSCONFIG=clusters/.talos/config`). In non-interactive shells, prefer `direnv exec . <cmd>` to avoid accidentally using a global/default kubeconfig.
- Avoid destructive Git commands; don't modify files outside this repository.

## Common Operations

### Adding a New Service
1. Choose category: apps, core, system, network, media, or kube-system
2. Create directory: `clusters/main/kubernetes/<category>/<service-name>/app/`
3. Create `ks.yaml` pointing to app directory
4. Create `app/kustomization.yaml`, `app/namespace.yaml`, `app/helm-release.yaml`
5. Add `<service-name>/ks.yaml` to category's `kustomization.yaml`
6. Commit, push, and reconcile

### Updating a Service
1. Edit HelmRelease: Change `spec.chart.spec.version` or `spec.values`
2. For secrets, use: `sops <file>.secret.yaml`
3. Commit and reconcile specific Kustomization

### Troubleshooting
- Check Flux status: `flux get ks -A` and `flux get hr -A`
- View logs: `flux logs --kind=<Kind> --name=<name> [-n <namespace>]`
- Verify secrets decrypt: `sops -d <file>.secret.yaml`
- Check variable substitution in cluster-config/upgrade-settings ConfigMaps
- Validate with: `kustomize build clusters/main/kubernetes/<category>`

### Cluster Health Check Procedure

**Recommended Regular Checks:**
```bash
# 1. Node and overall cluster status
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 2. Flux CD reconciliation status
flux get ks -A | grep -v True | grep -v False
flux get hr -A | grep -v True | grep -v False

# 3. Storage health (PVCs and Longhorn volumes)
kubectl get pvc -A | grep -v Bound
kubectl get volumes.longhorn.io -n longhorn-system | grep -v healthy

# 4. Gateway API status (replaces legacy ingress)
kubectl get gateways -A

# 5. Critical namespace health
kubectl get pods -n kube-system,cert-manager,longhorn-system,volsync
```

**Common Issues and Patterns:**

| Issue | Symptoms | Investigation | Remediation |
|-------|----------|---------------|-------------|
| **VolSync Mount Timeouts** | volsync-src-* pods in Error/ContainerCreating state | `kubectl describe pod <pod-name>` shows MountVolume.MountDevice errors | Restart pod, check Longhorn performance, increase timeouts |
| **Pending PVCs** | PVCs stuck in Pending state | Check StorageClass for WaitForFirstConsumer binding mode | Verify if PVC is needed, create test pod if required |
| **Flux Reconciliation Failures** | Kustomization/HelmRelease not Ready | `flux logs --kind=<Kind> --name=<name>` | Check YAML syntax, variable substitution, secret decryption |
| **Longhorn Volume Issues** | Volumes in detached/unknown state | `kubectl get volumes.longhorn.io -n longhorn-system` | Check Longhorn UI, worker node status, storage capacity |

## Key Files Reference

- `README.md` — Quick start and stack overview
- `docs/architecture.md` — Architecture details and component breakdown
- `docs/service-deployment-guide.md` — Service deployment patterns and operational workflows
- `docs/operations.md` — Bootstrap and day-2 workflows
- `docs/releases.md` — Version tracking and upgrade procedures
- `docs/secrets.md` — SOPS/age secrets management
- `.envrc` — Direnv-based cluster context (exports `KUBECONFIG`/`TALOSCONFIG`)
- `clusters/main/kubernetes/flux-entry.yaml` — Root Flux Kustomization
- `clusters/main/talos/talconfig.yaml` — Talos machine configuration
- `.sopsrc` — SOPS configuration (points to Age key)
