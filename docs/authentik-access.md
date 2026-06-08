# Authentik access model (homelab)

This repo manages “who can access what” for forward-auth protected admin surfaces using Authentik groups and application policy bindings.

## Groups (GitOps-managed)

Defined via Authentik blueprints in `clusters/main/kubernetes/apps/authentik/app/helm-release.yaml`:
- `homelab-admin` (Authenik superuser group)
- `homelab-readonly` (read-only access to selected apps)
- `homelab-media` (media app access, optional)
- `homelab-robots` (service accounts / automation tokens)
- `homelab-agents` (human-operated agents, CI, etc.)

## Current bindings (GitOps-managed)

Policy bindings are applied to these Authentik applications:
- `grafana-forward-auth`: `homelab-admin` + `homelab-readonly`
- `prometheus-forward-auth`: `homelab-admin` + `homelab-readonly`
- `alertmanager-forward-auth`: `homelab-admin`
- `goldilocks-forward-auth`: `homelab-admin`

## Recommended “single user” setup

1) Add your primary user to `homelab-admin`.
2) Keep `homelab-readonly` for future “view-only” users (Grafana/Prometheus).
3) Use `homelab-robots` for long-lived API tokens (separate from human accounts).

## Network access guardrails (recommended)

For admin UIs, prefer IP allowlists at the Gateway/route layer (in addition to Authentik auth):
- LAN: `192.168.1.0/24`
- WireGuard (OPNSense): `10.0.0.0/24`
- Tailscale node IPs: `100.64.0.1/32`, `100.64.0.2/32` (prefer explicit node IPs over the shared `100.64.0.0/10` CGNAT range)

If you add route-level allowlists, ensure probes/health checks (e.g. `gatus`) originate from an allowed source or use alternate in-cluster endpoints for probing.
