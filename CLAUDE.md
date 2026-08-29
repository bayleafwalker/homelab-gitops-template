# CLAUDE.md — homelab

See AGENTS.md for all project instructions, conventions, and operational workflows. This file adds Claude-specific context.

---

## Tech Stack

Primary language: YAML/Kustomize (Kubernetes GitOps). Flux v2.8.8 for reconciliation. Talos v1.13.3 OS, Kubernetes v1.36.1. SOPS + age for secrets. No application test framework — validation via `mise run validate`, `kustomize build`, or `./scripts/check-repo.sh`.

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

1. Validate changes with `mise run validate` and `./scripts/check-repo.sh` before committing.
2. **Never commit invalid YAML** — validate first.
3. After committing, reconcile: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.
4. Check status: `flux get ks -A`, `flux get hr -A`.
5. Use `sops` for all secret edits — never commit plaintext secrets.

### Self-healing test loop

If reconciliation fails after a change, diagnose the root cause (check `flux logs`, `kubectl describe`), fix, and re-push — up to **5 cycles** — before escalating to the user.

## Forge access, the sandbox, and landing work

Auto-loaded, so the things an agent must not miss live here rather than in
`AGENTS.md` (which is *not* auto-loaded unless imported).

**Network calls are sandboxed unless escalated.** `gh`, `fj`, `curl`, `kubectl`
and `git push/fetch/pull` return **exit 0 with empty output and no error** inside
the agent tool sandbox. An unreachable call and a genuinely empty result look
identical. Escalate the sandbox on every such call (Claude Code: the Bash
parameter `dangerouslyDisableSandbox: true`). That is an autonomous action, never
a request to the owner. **Never conclude absence from a sandboxed result** — if a
probe could not run, the finding is *could not check*, not *none found*.

**Standard workflow does not need permission.** Advancing `main` — commit, push,
PR create, PR merge, release cut, deploy — is routine, as are minting and
reviewing. This repo declares any exceptions in `.claude/gates.json`; **absence of
a declaration means routine**, never the reverse.

**Credentials already exist.** GitHub via `gh` (token in the system *keyring*, not
`~/.config/gh/hosts.yml`); Forgejo via `fj` (`fj auth list`) plus
`~/.config/forgejo/workstation-scope-token`. `git push` needs no token handling —
`~/.gitconfig` wires helpers for both forges. Check a credential’s audience before
using it.

**Land the work.** A stable diff is not done. Merge to `main` (or the main
development branch where `main` is protected) and let CI there catch what
targeted checks did not. Open a PR only for a named action: an operator handoff, a
dispatched review, or a CI check that runs nowhere else. `origin` is not reliably
canonical — check `git config claude.canonicalRemote`.
