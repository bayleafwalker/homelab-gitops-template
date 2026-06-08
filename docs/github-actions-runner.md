# GitHub Actions runners (self-hosted)

This template deploys a self-hosted GitHub Actions runner scale set onto the cluster using Actions Runner Controller (ARC).

Manifests:
- `clusters/main/kubernetes/system/github-actions-runner/`
- Controller namespace: `arc-system`
- Runner namespace: `arc-runners`
- Runner label used by workflows: `arc-runners`
- Ops workflow RBAC:
  - `clusters/main/kubernetes/system/github-actions-runner/app/runner-ops-rbac.yaml`
  - grants the runner service account scoped read + `gatus` validation pod actions for any
    in-cluster CI workflows you build on top of this runner (e.g. scheduled health checks).

## Setup (one-time)

1. Create a GitHub App for ARC and install it on the `your-username/your-homelab-repo` repo (GitHub Docs: `https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller`).
2. Collect the 3 values ARC needs:
   - **App ID**: GitHub App page → `App ID`
   - **Installation ID**: the installation page URL typically contains `/installations/<id>` (or via API: `gh api /repos/your-username/your-homelab-repo/installation --jq .id`)
   - **Private key**: generated in the GitHub App (PEM)
3. Put the GitHub App credentials into the SOPS secret (kept in `flux-system` and mirrored into `arc-runners` by kubernetes-reflector):
   - `sops clusters/main/kubernetes/flux-system/flux/arc-github-app.secret.yaml`
   - This template supports IDs via substitution (`${GITHUB_APP_ID}` / `${GITHUB_APP_INSTALLATION_ID}` from `cluster-secrets.secret.yaml`), but the recommended approach is to put the **private key PEM** directly in `github_app_private_key` here.
   - This is intentionally a dedicated secret (avoid mirroring the full `cluster-secrets` into the runner namespace).
4. Reconcile:
    - `direnv exec . flux reconcile kustomization github-actions-runner -n flux-system`

## Workflow migration

Workflows should target the runner scale set with:
```yaml
runs-on: [self-hosted, arc-runners]
```

Note: ARC’s `githubConfigUrl` is an HTTPS URL like `https://github.com/<owner>/<repo>`; it is not the SSH git remote format (`git@github.com:...`).

## Encryption workflow

- Prefer `clustertool decrypt` / `clustertool encrypt` when editing lots of secrets via your editor.
- Before committing, run `clustertool encrypt` (and optionally `clustertool checkcrypt`) to ensure no `*.secret.yaml` files are left in plaintext.
