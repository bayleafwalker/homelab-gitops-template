# Architecture

## Control plane
- Talos node definitions live in `clusters/main/talos/talconfig.yaml` (Talos/Kubernetes versions are pinned here; see `docs/releases.md`) with networking/domain values pulled from the encrypted `clusterenv.yaml`.
- Optional System Upgrade Controller plans in `clusters/main/kubernetes/core/system-upgrade-controller-plans` gate Talos rollouts and use `upgrade-settings` for version substitution.

## GitOps flow
- Flux controllers are sourced from `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` (OCI tag v2.8.8) and bootstrapped via manifests in `clusters/main/kubernetes/flux-system/flux`.
- `clusters/main/kubernetes/flux-entry.yaml` reconciles `clusters/main/kubernetes`, applies SOPS decryption with `sops-age`, and injects variables from `cluster-config` and `upgrade-settings`.
- Source definitions under `clusters/main/kubernetes/repositories/` include the TrueCharts catalog (`clusters/main/kubernetes/repositories/helm/truecharts.yaml` and `clusters/main/kubernetes/repositories/git/truecharts.yaml`) plus upstream feeds for networking, storage and monitoring charts.

## Networking and routing
- Cilium runs in kube-proxy replacement mode (`kube-system/cilium`) with `ipv4NativeRoutingCIDR` set from `${PODNET}`.
- MetalLB (`system/metallb` + `core/metallb-config`) advertises addresses from `${METALLB_RANGE}`.
- LAN HTTP routing is served by Cilium Envoy Gateway API (`network/gateway-api` + optional `HTTPRoute` resources); TLS is handled by cert-manager and the optional ClusterIssuer.
- Legacy ingress-controller runtimes are retired from top-level reconciliation.
- Optional supporting examples include Blocky DNS, Tailscale, Mosquitto, and Omada.

## Storage and data protection
- The lean default does not enable stateful storage. Optional examples include
  Longhorn, OpenEBS, snapshot-controller, TrueNAS RWX, VolSync, CNPG backups,
  and etcd snapshots.

## Security and certificates
- cert-manager is enabled by default. The optional TrueCharts `clusterissuer`
  chart provisions ACME issuers and defaults to Cloudflare DNS-01 via
  SOPS-encrypted tokens; other DNS providers require provider-specific
  ClusterIssuer changes.
- Optional Kubernetes reflector propagates TLS secrets across namespaces;
  SOPS/age enforces encrypted-at-rest secrets (`.sops.yaml` rules).

## Observability and operations
- metrics-server is enabled by default. Optional examples include
  kube-prometheus-stack, Prometheus Operator, node-feature-discovery,
  descheduler, Spegel, Loki, Promtail, Alloy, blackbox-exporter, Gatus, and
  backup-observability.
- Gatus is intended for internal service availability checks via in-cluster DNS
  (`*.svc.cluster.local`); blackbox-exporter is intended for edge/public paths.

## Operator access and MCP options
- Optional browser workstation: a TrueCharts code-server instance (`clusters/main/kubernetes/apps/vscode/app/helm-release.yaml`) installs the CLI toolchain into `/tools` for browser-based operations without local installs.
- Lightweight MCP option: run a minimal MCP process inside code-server (stdio or loopback HTTP) that exposes read-only health checks (kubectl get/describe, Flux status, Talos node health) using the kubeconfig/talosconfig already mounted in the workspace. Keep it internal and authenticated to the session, not exposed via public routes.
- Full-service option: if you add a dedicated MCP service later, follow the standard app pattern and keep access internal with NetworkPolicies. Start with read-only verbs plus explicitly-allowlisted reconcile/reboot actions.
- Guardrails: pin CLI versions, validate tool inputs, avoid logging secrets, and prefer ClusterIP + Tailscale/port-forwarding over public route exposure for MCP endpoints.

## Applications
- Optional identity examples: Authentik and LDAP outpost.
- Optional access/UI examples: Headlamp and Homepage.
- Optional productivity examples: Nextcloud, Vaultwarden, Paperless-ngx,
  Obsidian/CouchDB, and code-server.
- Custom examples: `apps/custom-app` and `apps/custom-app-postgres` show
  patterns for deploying your own services and a CNPG-backed Postgres database.
- Use `docs/service-catalog.md` for opt-in dependencies and validation.
