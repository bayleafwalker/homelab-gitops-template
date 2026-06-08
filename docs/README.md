# Documentation index

## Core (agent entrypoints)
- `bootstrapping.md` — start-to-finish guide for standing up a 1-2 node cluster from this template (newcomer entrypoint).
- `prompt-guide.md` — AI agent entrypoint (scope, guardrails, and validation).
- `architecture.md` — high-level architecture and component map.
- `service-deployment-guide.md` — service layout/patterns and day-2 workflows.
- `operations.md` — bootstrap and operational runbooks (Flux, DNS/Gateway API, monitoring, backups).
- `secrets.md` — SOPS/age rules and safe secret-handling patterns.
- `releases.md` — version pinning and upgrade workflow.
- `talos-kubernetes-upgrade.md` — step-by-step Talos/Kubernetes upgrade runbook.

## App configuration guides
- `authentik-access.md` — access patterns and notes for Authentik.
- `authentik-forward-auth-setup.md` — Authentik outpost routing notes for Gateway API-exposed apps.
- `forgejo.md` — Forgejo onboarding, bootstrap, and initial repository publication steps.
- `nextcloud-oidc-authentik.md` — configure Nextcloud OIDC login with Authentik (via Nextcloud app).
- `nextcloud-office-collabora.md` — deploy Collabora Online and connect it to Nextcloud Office.
- `obsidian.md` — Obsidian + CouchDB (LiveSync) notes setup.

## Platform runbooks
- `backups-volsync.md` — VolSync backups (Restic → object storage).
- `backups-cnpg.md` — CloudNativePG backup/restore patterns.
- `etcd-snapshots.md` — Talos etcd snapshots and restore notes.
- `github-actions-runner.md` — ARC runner setup and workflow targeting.
- `gpu-setup.md` — NVIDIA runtime/GPU enablement notes.
- `gateway-api.md` — Gateway API cluster primitives and per-service patterns.
- `gatus-monitoring-maintenance.md` — long-term maintenance workflow for `gatus` internal checks and hairpin diagnostics.
- `networkpolicies.md` — cluster NetworkPolicy patterns.
- `registry.md` — registry/mirror notes.
- `storage-troubleshooting.md` — comprehensive storage troubleshooting guide (Longhorn, VolSync, PVC provisioning).
- `truenas-storage.md` / `truenas-setup-checklist.md` / `truenas-auth.md` — storage platform notes.
