# Service Deployment Guide

## Overview

This cluster uses a GitOps approach with Flux CD to manage all service deployments. Services are organized by function into categorical areas, each with its own directory structure and reconciliation pattern.

Operational note: use `direnv exec . <cmd>` for `kubectl`/`flux` commands so you don’t accidentally target a global kubeconfig.

## Deployment Architecture

### Directory Structure

```
clusters/main/kubernetes/
├── apps/              # User-facing applications (Authentik, Dashboard, etc.)
├── core/              # Core platform services (Blocky, MetalLB config, cert issuers, etc.)
├── system/            # System-level infrastructure (storage, monitoring, controllers)
├── network/           # Network services (Gateway API, Omada, tailscale)
├── kube-system/       # Kubernetes system components (Cilium, metrics-server, etc.)
├── flux-system/       # Flux bootstrap and configuration
└── repositories/      # Helm/Git/OCI source definitions
```

### Service Deployment Pattern

Every service follows a consistent three-tier structure:

```
<category>/<service-name>/
├── ks.yaml                    # Kustomization pointing to app/
└── app/
    ├── kustomization.yaml     # Lists all resources for the service
    ├── helm-release.yaml      # HelmRelease manifest with chart version
    ├── namespace.yaml         # (optional) Namespace definition
    └── *.yaml                 # Additional resources (secrets, configs, etc.)
```

**Example: Authentik**
```
apps/authentik/
├── ks.yaml                    # Points Flux to apps/authentik/app
└── app/
    ├── kustomization.yaml
    ├── helm-release.yaml      # HelmRelease with pinned chart version
    ├── namespace.yaml
    └── ldap-outpost-token.yaml
```

## How Services Are Deployed

### 1. Source Repositories

All Helm charts are sourced from repositories defined in `clusters/main/kubernetes/repositories/`:

- **TrueCharts** (primary): `clusters/main/kubernetes/repositories/helm/truecharts.yaml` (OCI) and `clusters/main/kubernetes/repositories/git/truecharts.yaml`
- **Upstream charts**: Individual repositories in `clusters/main/kubernetes/repositories/helm/` (cilium, metallb, prometheus-community, etc.)

For a template repository, treat TrueCharts as an external dependency rather
than part of this repo. Prefer upstream project charts or locally-owned
manifests for services where long-term supportability is more important than
matching TrueCharts common values. When a service stays on TrueCharts, pin the
chart version, keep values close to documented chart behavior, and test
backup/restore before changing chart sources.

### 2. Kustomization Hierarchy

```
flux-entry.yaml (root)
    ↓
kustomization.yaml (aggregates all categories)
    ↓
<category>/kustomization.yaml (lists all services in that category)
    ↓
<service>/ks.yaml (points to service's app/ directory)
    ↓
<service>/app/kustomization.yaml (includes all service resources)
```

**Example flow:**
1. `flux-entry.yaml` reconciles `clusters/main/kubernetes/`
2. Main `kustomization.yaml` includes `- apps`
3. `apps/kustomization.yaml` includes `- authentik/ks.yaml`
4. `authentik/ks.yaml` points to `apps/authentik/app`
5. `authentik/app/kustomization.yaml` includes all manifests

### 3. HelmRelease Structure

Standard HelmRelease format used across all services:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  interval: 15m
  chart:
    spec:
      chart: <chart-name>
      version: <pinned-version>        # Always explicitly pinned
      sourceRef:
        kind: HelmRepository
        name: <repository-name>        # Usually "truecharts"
        namespace: flux-system
      interval: 15m
  timeout: 20m
  maxHistory: 3
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  values:
    # Service-specific values
    ingress:
      main:
        enabled: false
```

For HTTP exposure, use Gateway API resources in the service app directory (for example `gateway-api-routes.yaml`) and include them in `app/kustomization.yaml`.

### 4. Variable Substitution

Flux performs variable substitution from two ConfigMaps:

- **cluster-config**: Domain names, IP addresses, network ranges
- **upgrade-settings**: Talos and Kubernetes versions

Variables use `${VARIABLE_NAME}` syntax:
- `${DOMAIN_0}` - Primary domain
- `${GATEWAY_INTERNAL_IP}` - Internal Gateway API load balancer IP
- `${HOMELAB_METALLB_RANGE}` - main MetalLB/Cilium LoadBalancer address pool
- `${METALLB_RANGE}` - legacy compatibility alias for older MetalLB examples
- `${TALOS_VERSION}` - Current Talos version
- `${KUBERNETES_VERSION}` - Current Kubernetes version

### 5. Secrets Management

All secrets are encrypted with SOPS/age:

- Age key stored in `age.agekey` (local, not committed)
- `.sopsrc` points to the Age key
- Encrypted secrets have `.secret.yaml` suffix
- Flux decrypts automatically using the `sops-age` secret

**Example encrypted secret:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: authentik-credentials
  namespace: authentik
stringData:
  token: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
sops:
  kms: []
  age:
    - recipient: age1...
```

## Finding what’s deployed (avoid stale inventories)

Static “service inventory” tables drift quickly. Use the repo structure (and Flux status) as the source of truth:

- Filesystem inventory:
  - `ls clusters/main/kubernetes/<category>`
  - `rg -n \"^kind: HelmRelease$\" clusters/main/kubernetes -S`
- Cluster inventory (live):
  - `direnv exec . flux get ks -A`
  - `direnv exec . flux get hr -A`

## Synthetic Health Check Pattern

- Use `gatus` for internal service-health checks over cluster DNS/service names (`*.svc.cluster.local`).
- Use `blackbox-exporter` for edge/public-path probing (Gateway/LB/user path and certificate checks).
- For a new `gatus` internal check target, include policy wiring:
  - egress allow from `gatus` to target pods/ports
  - target namespace ingress allow from `gatus` workload selectors
- Prefer baseline source matching on `gatus` instance/name labels for the live checker.
- Optional strict profile:
  - use dedicated source identity label `policy.homelab.dev/gatus-internal=true`
  - scope restrictive egress policies to that identity (typically a dedicated checker pod/workload, not the live external checker)
- Avoid relying on Gateway hairpin paths for `gatus` policy-hardening validation; keep edge-path validation in blackbox probes.

## Adding a New Service

### Step 1: Choose the Category

Determine the appropriate category:
- **apps**: User-facing applications (web UIs, identity)
- **core**: Platform services needed early (routing, DNS, cert issuers)
- **system**: Infrastructure components (storage, monitoring, operators)
- **network**: Network services (controllers, VPNs, torrent clients)
- **media**: Media servers and related services
- **kube-system**: Kubernetes-native components

### Step 2: Create Directory Structure

```bash
mkdir -p clusters/main/kubernetes/<category>/<service-name>/app
```

### Step 3: Create ks.yaml

```yaml
# clusters/main/kubernetes/<category>/<service-name>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <service-name>
  namespace: flux-system
spec:
  interval: 10m
  path: clusters/main/kubernetes/<category>/<service-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: cluster
  # Recommended for most services so Flux waits for readiness.
  wait: true
  timeout: 5m
  # Optional: add a HelmRelease health check when the service is Helm-managed.
  # healthChecks:
  #   - apiVersion: helm.toolkit.fluxcd.io/v2
  #     kind: HelmRelease
  #     name: <service-name>
  #     namespace: <namespace>
```

### Step 4: Create app/kustomization.yaml

```yaml
# clusters/main/kubernetes/<category>/<service-name>/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helm-release.yaml
```

### Step 5: Create app/namespace.yaml (if needed)

```yaml
# clusters/main/kubernetes/<category>/<service-name>/app/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <service-name>
```

### Step 6: Create app/helm-release.yaml

Use the standard template from section "HelmRelease Structure" above. Key considerations:

- Pin a specific chart version (never use `*` or omit version)
- Set `createNamespace: true` if not creating namespace separately
- Use variable substitution for domains: `${DOMAIN_0}`
- Add Gateway API route resources for HTTP services (`HTTPRoute` and optional HTTP→HTTPS redirect route)

### Step 7: Add to Category Kustomization

Edit `clusters/main/kubernetes/<category>/kustomization.yaml`:

```yaml
resources:
  - existing-service/ks.yaml
  - <service-name>/ks.yaml  # Add this line
```

### Step 8: Validate and Deploy

```bash
# Check syntax
kustomize build clusters/main/kubernetes/<category> | less

# Commit changes
git add clusters/main/kubernetes/<category>/<service-name>
git commit -m "Add <service-name> to <category>"
git push

# Force reconciliation
direnv exec . flux reconcile source git cluster
direnv exec . flux reconcile kustomization flux-entry

# Monitor deployment
direnv exec . flux get helmreleases -A
direnv exec . kubectl get pods -n <service-name>
```

## Modifying Existing Services

### Updating Chart Versions

1. Edit the HelmRelease: `clusters/main/kubernetes/<category>/<service-name>/app/helm-release.yaml`
2. Change `spec.chart.spec.version` to the new version
3. Commit and push
4. Reconcile: `direnv exec . flux reconcile kustomization <service-name>`

### Changing Configuration Values

1. Edit the HelmRelease `spec.values` section
2. For secrets, use SOPS encryption:
   ```bash
   sops clusters/main/kubernetes/<category>/<service-name>/app/<name>.secret.yaml
   ```
3. Commit and reconcile

### Adding Resources

1. Create new YAML file in `app/` directory
2. Add filename to `app/kustomization.yaml` resources list
3. Commit and reconcile

## Troubleshooting

### Check Flux Status

```bash
# All kustomizations
direnv exec . flux get ks -A

# Specific service
direnv exec . flux get hr <service-name> -n <namespace>

# View logs
direnv exec . flux logs --kind=Kustomization --name=<service-name>
direnv exec . flux logs --kind=HelmRelease --name=<service-name> --namespace=<namespace>
```

### Common Issues

**HelmRelease stuck in "reconciling":**
- Check repository sync: `direnv exec . flux get sources helm -A`
- Verify chart version exists in repository
- Check dependencies are ready

**Secrets not decrypting:**
- Verify `sops-age` secret exists in flux-system namespace
- Check SOPS metadata in encrypted files
- Ensure Kustomization has decryption provider configured

**Variable substitution not working:**
- Verify variable exists in cluster-config or upgrade-settings ConfigMaps
- Check Kustomization has postBuild.substituteFrom configured
- Use exact syntax: `${VAR_NAME}` (not `$VAR_NAME`)

**Service not accessible:**
- Check `HTTPRoute` admission (`Accepted=True`, `ResolvedRefs=True`)
- Verify DNS points to the Gateway IP
- Check certificate issuer is ready: `direnv exec . kubectl get clusterissuer`

**DNS not resolving for a new service (Blocky / k8s_gateway + Gateway API):**
- This cluster uses Blocky with the `k8s_gateway` plugin for `${DOMAIN_0}` (`clusters/main/kubernetes/core/blocky/app/helm-release.yaml`).
- `k8s_gateway` answers from `Gateway` + `HTTPRoute` resources; routes must be admitted before DNS appears.
- If you queried before route admission, Blocky/client resolvers may negative-cache NXDOMAIN for a while (this cluster uses `caching.cacheTimeNegative: 5m`); waiting can resolve it without config changes.
- Quick triage: `direnv exec . kubectl get httproute -A`, `direnv exec . kubectl -n gateway get gateway internal -o wide`, `dig @${BLOCKY_IP} <svc>.${DOMAIN_0}`.

## Best Practices

### Version Pinning
- Always pin exact chart versions (e.g., `version: 1.2.3`)
- Never use version ranges or wildcards
- Document version changes in commit messages

### Secrets Management
- Never commit plaintext secrets
- Use `.secret.yaml` suffix for encrypted files
- Test decryption with: `sops -d file.secret.yaml`
- Rotate secrets regularly using `sops` edit mode

### Gateway API Configuration
- Use `HTTPRoute` resources attached to `gateway/internal` (`sectionName: https`)
- Add an HTTP redirect route on `sectionName: http` when needed
- Use variable substitution for hostnames (`${DOMAIN_0}`)
- For cross-namespace backends, add a `ReferenceGrant` in the target namespace

### Resource Organization
- Keep related resources in the same app/ directory
- Use descriptive filenames (e.g., `database-secret.yaml`, `backup-cronjob.yaml`)
- Document complex configurations with comments
- Group similar services in the same category

### Git Workflow
- Make atomic commits (one service or change per commit)
- Write descriptive commit messages
- Test locally with `kustomize build` before committing
- Reconcile immediately after pushing critical changes

## Version Alignment

### Talos and Kubernetes

Versions must be synchronized in two places:

1. **Machine config generation**: `clusters/main/talos/talconfig.yaml`
   ```yaml
   talosVersion: v1.13.3
   kubernetesVersion: v1.36.1
   ```

2. **Upgrade orchestration**: `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml`
   ```yaml
   data:
     TALOS_VERSION: v1.13.3
     KUBERNETES_VERSION: v1.36.1
   ```

System Upgrade Controller plans in `core/system-upgrade-controller-plans/` consume these variables to orchestrate rolling upgrades.

### Flux Controllers

Flux version is controlled by the OCI manifest tag in `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml`:

```yaml
spec:
  url: oci://ghcr.io/fluxcd/flux-manifests
  ref:
    tag: v2.8.8
```

## References

- Main documentation: `README.md`, `docs/architecture.md`
- Operations guide: `docs/operations.md`
- Version tracking: `docs/releases.md`
- Secrets guide: `docs/secrets.md`
- Template publishing assessment: `docs/template-publishing.md`
- Flux documentation: https://fluxcd.io/docs/
- TrueCharts catalog/docs: https://truecharts.org/
- TrueCharts ClusterTool getting started: https://truecharts.org/clustertool/getting-started/
