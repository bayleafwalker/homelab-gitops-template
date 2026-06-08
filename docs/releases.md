# Releases and version pinning

## Where versions live
- Talos/Kubernetes: `clusters/main/talos/talconfig.yaml` (used for machine config generation) and `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml` (consumed by System Upgrade Controller plans).
- Flux controllers: `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` (OCI tag).
- Helm charts: `spec.chart.spec.version` in each HelmRelease under `clusters/main/kubernetes/**/app/helm-release.yaml`.

## Upgrade workflow
- Talos/Kubernetes: align `talconfig.yaml` and `upgradesettings.yaml`, regenerate machine configs, commit, then enable upgrades by labeling the target nodes (`${UPGRADE_NODE_LABEL}=true`, for example `upgrade.example.com/enabled=true`) and reconcile plans with `flux reconcile kustomization system-upgrade-controller-plans`.
- Flux: bump the OCI tag in `flux-manifests.yaml`, commit, and reconcile `flux` + `flux-entry`.
- Charts/apps: update chart versions, commit, and reconcile the affected Kustomization; watch `flux logs` for drift warnings.
- Only commit encrypted secrets; rotate Age keys and deploy keys when rotating Git credentials.

## Current pinned versions (canonical)

Avoid duplicating hard-coded version strings in docs (they drift).

Source of truth:
- Talos/Kubernetes: `clusters/main/talos/talconfig.yaml`
- SUC substitutions: `clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml`
- Flux controllers: `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml`

Quick checks:
```bash
rg -n "^(talosVersion|kubernetesVersion):\\s*v" clusters/main/talos/talconfig.yaml
rg -n "^(\\s*TALOS_VERSION|\\s*KUBERNETES_VERSION):\\s*v" clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml
```

Component/chart versions (Cilium, Traefik, Nextcloud, etc.) change frequently; avoid maintaining a static list in docs. Use the HelmRelease files as the source of truth:

- Find HelmReleases: `rg -n "^kind: HelmRelease$" clusters/main/kubernetes -S`
- Find chart pins: `rg -n "^\\s*version:\\s*\\S+" clusters/main/kubernetes/**/app/helm-release.yaml -S`
