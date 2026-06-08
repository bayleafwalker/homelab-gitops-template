# Prompt guide (AI agent entrypoint)

This repo is a GitOps source of truth for a Talos/Kubernetes cluster managed by Flux. Use this as the starting point for agent work so changes stay safe, reviewable, and low-drift.

## Read first
- `README.md`
- `docs/architecture.md`
- `docs/service-deployment-guide.md`
- `docs/operations.md`
- `docs/secrets.md`
- `docs/releases.md`

## Scope and guardrails
- Prefer changes under `clusters/main/**` and `docs/**`.
- Never commit plaintext secrets. Use SOPS; encrypted files use `*.secret.yaml`.
- Keep Helm chart versions pinned (no wildcards/ranges).
- Prefer in-cluster Service URLs for app-to-app wiring (Gateway/API routes are primarily for user-facing access).

## Validation before you commit
- Build the affected kustomization(s):
  - `kustomize build clusters/main/kubernetes/<category>`
  - If you touched a single service: `kustomize build clusters/main/kubernetes/<category>/<service>/app`

## Day-2 commands (always target the repo kubeconfig)
- Use `direnv exec . <cmd>` to avoid a global kubeconfig:
  - `direnv exec . flux get ks -A`
  - `direnv exec . flux get hr -A`
  - `direnv exec . flux reconcile source git cluster`
  - `direnv exec . flux reconcile kustomization flux-entry`
- Avoid nested login-shell diagnostics such as `direnv exec . bash -lc 'kubectl ...'`.
  Login shell startup can reset `KUBECONFIG`/`TALOSCONFIG`; use direct
  `direnv exec . kubectl ...`, `direnv exec . flux ...`, and
  `direnv exec . talosctl ...` commands instead.
