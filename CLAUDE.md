# CLAUDE.md — homelab

See AGENTS.md for all project instructions, conventions, and operational workflows. This file adds Claude-specific context.

---

## Tech Stack

Primary language: YAML/Kustomize (Kubernetes GitOps). Flux v2.8.5 for reconciliation. Talos v1.12.6 OS, Kubernetes v1.35.3. SOPS + age for secrets. No application test framework — validation via `mise run validate` or `kustomize build`.

---

## Environment Setup

### Required environment variables

| Variable | Value/Path | Purpose |
|---|---|---|
| `KUBECONFIG` | `<repo-root>/clusters/.kube/config` | Cluster-scoped kubeconfig |
| `TALOSCONFIG` | `<repo-root>/clusters/.talos/config` | Cluster-scoped talos config |
| `CLUSTER_NAME` | `homelab` | Cluster identifier (rename to match your own cluster) |

**Load with:** `source .envrc` or `direnv allow` from the repo root.

Tool versions are pinned in `mise.toml`. Run `mise install` after entering the repo when setting up a new machine or shell.

**Validation:**
```bash
echo $KUBECONFIG    # must contain the repo path, not ~/.kube/config
echo $CLUSTER_NAME  # must be "homelab"
# In non-interactive shells: direnv exec . kubectl get nodes
```

> Using the home-directory default kubeconfig silently targets the wrong cluster. Always verify `KUBECONFIG` points to `clusters/.kube/config` before running `kubectl`, `flux`, or `talosctl`.

### Cluster context

Once bootstrapped, this cluster reconciles continuously via Flux — all changes to `clusters/main/**` apply automatically after push. Target cluster: `homelab` (placeholder name; rename throughout to match your own).

- Use `direnv exec . <cmd>` in non-interactive shells to ensure project-scoped kubeconfig.
- Do not modify files outside `clusters/main/**` and `docs/**` unless explicitly requested.

---

## Development Workflow

1. Validate changes with `mise run validate` before committing.
2. **Never commit invalid YAML** — validate first.
3. After committing, reconcile: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.
4. Check status: `flux get ks -A`, `flux get hr -A`.
5. Use `sops` for all secret edits — never commit plaintext secrets.

### Self-healing test loop

If reconciliation fails after a change, diagnose the root cause (check `flux logs`, `kubectl describe`), fix, and re-push — up to **5 cycles** — before escalating to the user.
