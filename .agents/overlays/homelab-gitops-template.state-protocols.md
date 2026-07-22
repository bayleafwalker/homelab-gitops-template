# Homelab GitOps template state-protocol overlay

## Owned subject

- Subject: the template's Git-owned Flux desired-state tree.
- Source of truth: committed example manifests under `clusters/main/kubernetes/`.
- Semantic contract: `docs/protocols/flux-desired-live-convergence.md`.
- Context packet: `verification/contexts/flux-desired-live-convergence.json`.

## Verification boundary

- Template CI proves renderability and internal contract consistency only.
- It does not prove a copied repository has reconciled, that workloads are healthy, or that backup and restore paths work.
- A repository created from this template must rename the manifest, owner ids, contract revision, source anchors, and cluster-specific boundaries.
- Production credentials and secret values never enter context or result packets.
- Repair and live cluster mutation require separate authorization.

## Escalation

Stop when a claim depends on a real cluster, provider, credential, or recovery
environment that the template CI cannot observe.
