# Bootstrapping a 1-2 node cluster from this template

This is the newcomer path: it walks through everything from "I forked the
template" to "Flux is reconciling my cluster," sized for a small (1-2 node)
homelab deployment. It complements — rather than replaces — `docs/operations.md`
(the day-2 runbook) and `docs/secrets.md` (the encryption rules); both are
linked at the relevant steps below.

Run `./scripts/quickstart.sh` at any time — it's a safe, read-only checker that
reports which placeholders, keys, and config files still need your attention.

## 0. Plan your cluster

Decide how many physical or virtual machines you're starting with:

- **1 node**: a single machine acts as control plane *and* worker. You'll set
  `controlPlane: true` and `allowSchedulingOnControlPlanes: true`.
- **2 nodes**: either one control plane + one worker, or two control-plane
  nodes both scheduling workloads (again with `allowSchedulingOnControlPlanes:
  true`). Two nodes is the minimum for any kind of redundancy, but etcd quorum
  still requires care — see the [Talos docs on cluster sizing](https://www.talos.dev/latest/introduction/prodnotes/)
  before committing to a 2-node control plane.

Either way, note down: the static IP(s) you'll assign, the MAC address(es) of
the NIC(s) Talos should configure, your LAN gateway/CIDR, and a free VIP for
the Kubernetes API endpoint (must differ from every node IP).

If your network supports it, put the cluster on its own subnet or VLAN and keep
node IPs, the API VIP, and LoadBalancer addresses outside DHCP. A flat LAN works
for a starter lab, but a dedicated cluster subnet makes firewalling, DNS, and
storage access cleaner later.

## 1. Install tooling and load the environment

```bash
mise install              # installs the pinned kubectl/kustomize/talosctl/flux/helm/sops/age/clustertool
cp .envrc.example .envrc  # then edit CLUSTER_NAME/CLUSTER_TYPE/PS1 to your own cluster name
direnv allow
```

`.envrc` is gitignored — it's local to your machine. Keep `CLUSTER_NAME`
consistent with what you use elsewhere (the placeholder is `homelab`).

## 2. Generate your age keypair

SOPS encryption protects every secret in this repo. Generate your own keypair
— never reuse the template's placeholder values:

```bash
age-keygen -o age.agekey
```

This prints a `# public key: age1...` comment and writes the private key to
`age.agekey` (already gitignored). You'll use both halves:

- **Public key** → replace every `age1REPLACE_WITH_YOUR_OWN_AGE_PUBLIC_KEY_FROM_age-keygen`
  placeholder in [`.sops.yaml`](../.sops.yaml) with it. This is what SOPS uses
  to *encrypt* files for you.
- **Private key** → goes into the `sops-age` Kubernetes secret (see step 5) —
  this is what Flux uses to *decrypt* everything in-cluster. It must be applied
  out-of-band; it can never be SOPS-encrypted itself (see the comments in
  `clusters/main/kubernetes/flux-system/flux/sopssecret.secret.yaml`).

`.sopsrc` already points SOPS at `./age.agekey` relative to the repo root, so
running `sops <file>` from the repo root "just works" once the key exists.

Full details: [`docs/secrets.md`](secrets.md).

## 3. Customize the placeholder values

Search-and-replace the established placeholders throughout the repo with your
own values (run `./scripts/quickstart.sh` to find what's left):

| Placeholder | Replace with |
|---|---|
| `homelab` (cluster name) | your cluster's name |
| `192.168.1.0/24` and `192.168.1.x` addresses | your LAN subnet and chosen static IPs |
| `00:11:22:33:44:5X` | the real MAC address(es) of your node NIC(s) |
| `example.com` / `apps.example.com` | your real domain(s) |
| `you@example.com` | your email (used for ACME/cert issuance) |
| `your-username/your-homelab-repo` | your Git hosting path |
| `REPLACE_WITH_*` | freshly generated random secrets/tokens (see inline comments per file for how to generate each one) |

The bundled certificate path is opinionated around Cloudflare DNS-01. If your
DNS zone is elsewhere, plan to replace the ClusterIssuer provider values before
first reconcile.

Key files to edit:

- **`clusters/main/clusterenv.yaml`** — node IPs/MACs, VIP, gateway/CIDR,
  domain, and the tokens that feed Talos machine-config generation. This file
  must be SOPS-encrypted before it's committed (`.sops.yaml` already has a rule
  for it).
- **`clusters/main/talos/talconfig.yaml`** — the node list. **For a 1-2 node
  cluster, delete the extra node entries** (the template ships with six —
  three control planes and three workers — as a larger reference example).
  Keep just the node(s) you're deploying, set `controlPlane: true` on each, and
  set `allowSchedulingOnControlPlanes: true` at the top level so a lone control
  plane (or small control-plane-only cluster) can still run workloads. Remove
  the matching `${VARIABLE}` entries from `clusterenv.yaml` for any nodes you
  delete, and delete unused per-node patches under `clusters/main/talos/patches/`
  (e.g. `worker3-nodeip.yaml`, `worker-gpu1-*.yaml` if you have no GPU node).
  `MASTER1IP` exists for clustertool compatibility even though the sample node
  list starts at `k8s-control-2`; either add a `k8s-control-1` entry or rename
  the sample nodes to your preferred sequence.
- **`clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml`**
  and **`cluster-secrets.secret.yaml`** — non-sensitive and sensitive
  cluster-wide values consumed by Flux's variable substitution. Both ship with
  `REPLACE_WITH_*` placeholders and header comments explaining each field.
- **`clusters/main/kubernetes/flux-system/flux/deploykey.secret.yaml`** —
  generate a fresh deploy keypair (`ssh-keygen -t ecdsa -b 384`), add the
  public half as a read-only deploy key on your Git host, and capture
  `known_hosts` with `ssh-keyscan github.com` (or your Git host's hostname).
- **`.sops.yaml`** — your age *public* key (see step 2).

Once edited, encrypt real secret files with `./scripts/sops-files.sh encrypt`
or `sops -e -i <file>` before committing. The helper intentionally excludes
the documentation-only `sopssecret.secret.yaml` example. **Never commit real
plaintext secrets**.

## 4. Generate and apply Talos machine configs

```bash
direnv exec . talhelper genconfig          # reads talconfig.yaml + clusterenv.yaml
direnv exec . talosctl apply-config --insecure -n <node-ip> -f clusterconfig/<node-hostname>.yaml
direnv exec . talosctl bootstrap -n <control-plane-ip> -e <control-plane-ip>
```

Wait for etcd and the API server to come up (`talosctl health`), then fetch
your kubeconfig:

```bash
direnv exec . talosctl kubeconfig clusters/.kube/config -n <control-plane-ip> -e <control-plane-ip>
```

If you have `clustertool` installed (it's pinned in `mise.toml`), `clustertool
talos bootstrap` wraps machine-config generation, application, bootstrap, and
the initial Flux install into one guided flow — see `docs/operations.md` for
when to prefer it over the manual steps above.

## 5. Break the chicken-and-egg: create the `sops-age` secret out-of-band

Flux can only decrypt SOPS-encrypted manifests once the `sops-age` secret
exists in-cluster — and nothing can create that secret for you, since it's
what makes decryption possible in the first place. Apply it directly, before
bootstrapping anything else:

```bash
kubectl create namespace flux-system
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=./age.agekey
```

(`sopssecret.secret.yaml` is a documentation-only example and is deliberately
commented out of `kustomization.yaml`. Do not apply it through Flux and do not
include it in bulk SOPS encryption loops, since Flux would have no way to
decrypt the key that makes decryption possible. See the "Safety: when (not) to
touch `sops-age`" section of [`docs/secrets.md`](secrets.md).)

You'll also need your **deploy** private key as a local plaintext file for the
`flux bootstrap` command below — generate the keypair now if you haven't yet
(step 3 covers populating `deploykey.secret.yaml` for commit; reuse the same
keypair here so both stay in sync):

```bash
ssh-keygen -t ecdsa -b 384 -f ./deploy-key -C "flux-system deploy key" -N ""
# Add ./deploy-key.pub as a read-only deploy key on your Git host
```

## 6. Bootstrap Flux

```bash
flux bootstrap git \
  --url=ssh://git@github.com/your-username/your-homelab-repo.git \
  --branch=main \
  --path=clusters/main/kubernetes/flux-system/flux \
  --private-key-file=./deploy-key
```

This installs the Flux controllers and creates the `GitRepository`/
`Kustomization` that sync from your repo. SOPS decryption for everything
beyond the bootstrap secret is already configured *in the committed manifests*
(`flux-entry.yaml` references `sops-age` directly — see
[`docs/secrets.md`](secrets.md)), so no extra bootstrap flags are needed.

Once it settles, you can delete the local `./deploy-key`/`./deploy-key.pub`
plaintext files — Flux now holds what it needs in-cluster, and the encrypted
`deploykey.secret.yaml` carries the same keypair for anything else that
consumes it via GitOps.

## 7. Apply the remaining bootstrap prerequisites

`cluster-config`/`cluster-secrets` (the `ConfigMap`/`Secret` that
`postBuild.substituteFrom` pulls from) are themselves bootstrap prerequisites
— Flux can't run variable substitution on `flux-entry.yaml` until they exist
as real in-cluster objects. Apply them once, directly, with SOPS decryption:

```bash
source .sopsrc   # or: export SOPS_AGE_KEY_FILE=./age.agekey
sops -d clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml | kubectl apply -f -
sops -d clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml | kubectl apply -f -
```

If the root Kustomizations weren't already created by the bootstrap step,
apply those too:

```bash
kubectl apply -f clusters/main/kubernetes/flux-entry.yaml
kubectl apply -f clusters/main/kubernetes/repositories/flux-entry.yaml
```

Then trigger the first full reconcile:

```bash
flux reconcile source git cluster && flux reconcile kustomization flux-entry
```

From here on, prefer the GitOps path for secret changes — edit with `sops`,
commit, push, reconcile (see "Standard procedure: updating secrets" in
[`docs/secrets.md`](secrets.md)). Manual `sops -d ... | kubectl apply -f -` is
for bootstrap and one-off recovery only.

## 8. Verify

```bash
flux get ks -A      # Kustomizations should turn Ready
flux get hr -A      # HelmReleases should turn Ready
kubectl get nodes -o wide
./scripts/quickstart.sh   # re-run to confirm the build still passes end to end
```

From here, `docs/operations.md` covers day-2 workflows (adding services,
upgrades, routine reconciliation), and `docs/architecture.md` maps out what's
deployed and why.

## Troubleshooting

- **Flux Kustomizations stuck on "secret/configmap not found" or failing
  variable substitution**: confirm `sops-age` (step 5) and `cluster-config`/
  `cluster-secrets` (step 7) landed in the `flux-system` namespace before the
  first reconcile — none of them can be created by Flux itself (chicken-and-egg).
- **`kustomize build clusters/main/kubernetes` fails**: run `mise run kustomize`
  locally before pushing; this is exactly what CI/Flux will choke on too.
- **Wrong kubeconfig/talosconfig targeted**: always run cluster commands
  through `direnv exec . <cmd>` — see the warning in `AGENTS.md` about the
  home-directory default kubeconfig silently targeting the wrong cluster.
- More platform-specific runbooks live under `docs/` — check the index in
  `docs/README.md`.
