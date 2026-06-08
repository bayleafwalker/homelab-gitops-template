# Architecture

## Control plane
- Talos node definitions live in `clusters/main/talos/talconfig.yaml` (Talos/Kubernetes versions are pinned here; see `docs/releases.md`) with networking/domain values pulled from the encrypted `clusterenv.yaml`.
- System Upgrade Controller plans in `clusters/main/kubernetes/core/system-upgrade-controller-plans` gate Talos rollouts and use `upgrade-settings` for version substitution.

## GitOps flow
- Flux controllers are sourced from `clusters/main/kubernetes/repositories/oci/flux-manifests.yaml` (OCI tag v2.8.8) and bootstrapped via manifests in `clusters/main/kubernetes/flux-system/flux`.
- `clusters/main/kubernetes/flux-entry.yaml` reconciles `clusters/main/kubernetes`, applies SOPS decryption with `sops-age`, and injects variables from `cluster-config` and `upgrade-settings`.
- Source definitions under `clusters/main/kubernetes/repositories/` include the TrueCharts catalog (`clusters/main/kubernetes/repositories/helm/truecharts.yaml` and `clusters/main/kubernetes/repositories/git/truecharts.yaml`) plus upstream feeds for networking, storage and monitoring charts.

## Networking and routing
- Cilium runs in kube-proxy replacement mode (`kube-system/cilium`) with `ipv4NativeRoutingCIDR` set from `${PODNET}`.
- MetalLB (`system/metallb` + `core/metallb-config`) advertises addresses from `${METALLB_RANGE}`.
- LAN HTTP routing is served by Cilium Envoy Gateway API (`network/gateway-api` + `HTTPRoute` resources); TLS is handled by cert-manager/clusterissuer.
- Legacy ingress-controller runtimes are retired from top-level reconciliation.
- Omada TCP/UDP is exposed via dedicated `LoadBalancer` services.
- Supporting services: Blocky DNS sinkhole and Omada controller.

## Storage and data protection
- Longhorn and OpenEBS provide CSI-backed storage; snapshot-controller is installed for volume snapshots.
- VolSync enables backup/replication of PVC data.

## Security and certificates
- cert-manager plus the TrueCharts `clusterissuer` chart provision ACME issuers. This template defaults to Cloudflare DNS-01 via SOPS-encrypted tokens; other DNS providers are possible with provider-specific ClusterIssuer changes.
- Kubernetes reflector propagates TLS secrets across namespaces; SOPS/age enforces encrypted-at-rest secrets (.sops.yaml rules).

## Observability and operations
- kube-prometheus-stack with Prometheus Operator delivers monitoring/alerting; metrics-server, node-feature-discovery and descheduler support scheduling health.
- Loki + Promtail provide cluster log aggregation (queryable via Grafana Explore). Alloy is present only as a narrow canary, not as the primary all-node log shipper.
- blackbox-exporter performs synthetic HTTPS probing for edge/public paths (Gateway-routed hosts + key external endpoints) with alerts on probe failures and certificate expiry.
- gatus performs internal service availability checks via in-cluster DNS (`*.svc.cluster.local`) and explicit cross-namespace policy allows.
- backup-observability exports VolSync, CNPG, Longhorn, and restore-drill freshness metrics for Prometheus alerts.
- Spegel caches container images within the cluster to reduce external pulls.

## Operator access and MCP options
- Primary workstation: a TrueCharts code-server instance (`clusters/main/kubernetes/apps/vscode/app/helm-release.yaml`) installs the CLI toolchain into `/tools` for browser-based operations without local installs.
- Lightweight MCP option: run a minimal MCP process inside code-server (stdio or loopback HTTP) that exposes read-only health checks (kubectl get/describe, Flux status, Talos node health) using the kubeconfig/talosconfig already mounted in the workspace. Keep it internal and authenticated to the session, not exposed via public routes.
- Full-service option: if you add a dedicated MCP service later, follow the standard app pattern and keep access internal with NetworkPolicies. Start with read-only verbs plus explicitly-allowlisted reconcile/reboot actions.
- Guardrails: pin CLI versions, validate tool inputs, avoid logging secrets, and prefer ClusterIP + Tailscale/port-forwarding over public route exposure for MCP endpoints.

## Applications
- Identity: Authentik and the LDAP outpost for directory access.
- Access/UI: Headlamp and Homepage with Gateway API exposure.
- Productivity: Nextcloud, Vaultwarden, Paperless-ngx, Obsidian (CouchDB sync), code-server.
- Custom: `apps/custom-app` and `apps/custom-app-postgres` show the patterns for deploying
  your own services and a CNPG-backed Postgres database — replace these with your own apps.
