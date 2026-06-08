# Secrets and encryption

- SOPS rules (`.sops.yaml`) enforce age encryption for Talos/Kubernetes values files, `*.secret.yaml`, and `clusterenv.yaml`. `.sopsrc` points SOPS to the age key (`age.agekey`); keep the private key out of Git.
- Core secrets to maintain (encrypt before committing):
  - `clusters/main/clusterenv.yaml` for VIPs, IP pools, domains and sensitive cluster settings.
  - Flux secrets in `clusters/main/kubernetes/flux-system/flux` (`deploykey.secret.yaml`, `clustersettings.secret.yaml`, `sops-age`, etc.).
  - Any application values or `*.secret.yaml` files under `clusters/main/kubernetes/**`.
- Edit with `sops <file>` and commit only the encrypted output. Never commit plaintext or generated machine secrets.
- Use `clustertool genconfig` to regenerate machine configs from `talconfig.yaml` and `clusterenv.yaml`
- Flux decrypts manifests using the `sops-age` secret referenced by `flux-entry.yaml`; keep that secret synchronized with your age public key.

## Flux variable substitution sources

This repo uses Flux `postBuild.substituteFrom` to inject cluster-wide variables into manifests.

- Non-sensitive values live in `ConfigMap/cluster-config` (file: `clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml`).
- Sensitive values live in `Secret/cluster-secrets` (file: `clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml`).
- Flux roots reference both sources:
  - `clusters/main/kubernetes/flux-entry.yaml`
  - `clusters/main/kubernetes/repositories/flux-entry.yaml`

Operational note: the `cluster-config`/`cluster-secrets` objects are bootstrap prerequisites (Flux can’t substitute until they exist). Apply updates with SOPS decryption, e.g.:

`source .sopsrc` (or `export SOPS_AGE_KEY_FILE=./age.agekey`), then:
- `sops -d clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml | kubectl apply -f -`
- `sops -d clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml | kubectl apply -f -`

If you change the root Flux Kustomizations themselves, apply those too (they’re part of the bootstrap manifests):
- `kubectl apply -f clusters/main/kubernetes/flux-entry.yaml`
- `kubectl apply -f clusters/main/kubernetes/repositories/flux-entry.yaml`

## Standard procedure: updating secrets (GitOps-first)

In normal operations, prefer GitOps over manual `kubectl apply`:

1. Edit the encrypted secret file using SOPS, then commit and push.
   - Example: `sops clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml`
2. Ensure Flux fetches the new commit (GitRepository refresh).
   - Force a fetch:
     - `kubectl -n flux-system annotate gitrepository cluster reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite`
   - Verify it advanced:
     - `kubectl -n flux-system get gitrepository cluster -o jsonpath='{.status.artifact.revision}{"\n"}'`
3. Reconcile the dependent Kustomization(s) so the updated Secret/ConfigMap is applied.
   - Example:
     - `kubectl -n flux-system annotate kustomization flux-entry reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite`
     - `kubectl -n flux-system annotate kustomization tailscale reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite`
   - Verify:
     - `kubectl -n flux-system get kustomization flux-entry -o jsonpath='{.status.lastAppliedRevision}{"\n"}'`
4. If the secret is mounted/consumed at startup, restart the workload to pick up changes.
   - Example:
     - `kubectl -n tailscale rollout restart daemonset/tailscale`

Notes:
- The preferred “force reconcile” annotation key is `reconcile.fluxcd.io/requestedAt` (works across Flux sources and kustomizations). Other keys may be present but are not reliably acted upon.
- Only use `sops -d ... | kubectl apply -f -` for bootstrap/one-off recovery when Flux cannot run yet or when you explicitly want to bypass GitOps.

## Safety: when (not) to touch `sops-age`

The `Secret/sops-age` in `flux-system` is the decryption key Flux uses at build time.

- Do not rotate/overwrite `sops-age` as part of routine secret updates.
- If you suspect decryption issues:
  - First check Flux is actually on the expected Git revision.
  - Then confirm that the in-cluster `sops-age` matches the key you’re using locally.
    - Suggested non-leaky check: compare hashes of the decoded `age.agekey` content.

## Incident note: “secret updated in Git but cluster still used old value”

When rotating `TAILSCALE_AUTHKEY`, we hit a case where:

- Local git and `origin/main` had the updated encrypted secret, but `GitRepository/cluster` in Flux was still serving an older artifact revision.
- Because the GitRepository revision didn’t advance, downstream Kustomizations kept applying the old `Secret/cluster-secrets` and the generated `tailscale-auth` secret stayed on the old key.
- We also observed a mismatch between the local `age.agekey` and the in-cluster `sops-age` secret; we re-applied `sops-age` from the intended local key and then re-triggered Flux reconcile.

Resolution checklist:
- Ensure `GitRepository/cluster` `status.artifact.revision` matches the commit you pushed.
- Reconcile the kustomizations that own/consume the secret (`flux-entry`, then service kustomizations).
- Restart workloads that only read secrets at startup.

## Avoid leaking secrets via HelmRelease specs

Flux variable substitution happens before manifests are applied. If you put `${...PASSWORD}`/`${...TOKEN}` directly in a `HelmRelease.spec.values`, the live `HelmRelease` object in the cluster will contain the *resolved* secret value, and `kubectl describe hr ...` will print it.

Preferred patterns:
- Put secrets in a `Secret` resource (SOPS-encrypted `*.secret.yaml`, or a `Secret` populated via substitution), then reference it from the `HelmRelease` using `spec.valuesFrom` (best when a chart expects a plain string).
- When supported by the chart/operator, reference a Secret directly (e.g., `env.valueFrom.secretKeyRef`, `existingSecret`, or mounted secret files like Alertmanager’s `bearer_token_file`) instead of embedding secret strings in values.

TrueCharts note: when using `secretKeyRef` in `env` maps, set `expandObjectName: false` in the ref object if you want to reference an existing Kubernetes Secret by name (instead of a chart-managed secret in `.Values.secret`).
