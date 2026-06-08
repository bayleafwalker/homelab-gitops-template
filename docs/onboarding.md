# Onboarding checklist

This is the shortest path from "I copied the template" to "I know what to
change before bootstrap." Use `docs/bootstrapping.md` for command-by-command
execution once these inputs are decided.

This repo supports two bootstrap styles:

- **Direct Talos/Flux path**: use `talhelper`, `talosctl`, `sops`, and
  `flux bootstrap` directly. This is the clearest path for understanding what
  each layer does.
- **ClusterTool-assisted path**: use TrueCharts/TrueForge ClusterTool for
  generation and bootstrap helpers. The repo keeps `clusterenv.yaml` and
  `talconfig.yaml` compatible with that workflow, but it is not an official
  ClusterTool-generated template.

For public template readiness, upstream dependency tradeoffs, and license
notes, review `docs/template-publishing.md`.

## 1. Local tools and keys

Run:

```bash
mise install
./scripts/setup-encryption.sh
./scripts/configure-starter.sh --help
./scripts/quickstart.sh
```

Local files created during setup are intentionally gitignored:

- `.envrc` for project-scoped `KUBECONFIG`, `TALOSCONFIG`, and `CLUSTER_NAME`.
- `age.agekey` for local SOPS editing.
- `deploy-key` / `deploy-key.pub` for Flux bootstrap.

`scripts/configure-starter.sh` can apply the common text substitutions for
domain, Git repository, LAN, LoadBalancer range, S3, and TrueNAS values. It
does not replace the need to review node inventory, service choices, or real
secret values.

The `sops-age` Kubernetes Secret is created manually during bootstrap. Do not
commit the private age key.

## 2. Network and domain inputs

Define these before editing manifests:

| Input | Used by |
|---|---|
| LAN CIDR and gateway | Talos node config, Cilium policies, DNS forwarding |
| Kubernetes API VIP | `talconfig.yaml`, Talos endpoint, API certificate SANs |
| Pod and service CIDRs | Talos cluster networking, Cilium, NetworkPolicies |
| Kubernetes service host IP | hostNetwork helpers and API egress policies |
| LoadBalancer range | MetalLB/Cilium L2 pools and fixed service IPs |
| Internal Gateway IP | Gateway API HTTP routing |
| Optional registry IP/host | private image mirror and node runtime registry patch |
| Optional trusted VPN CIDR | LDAP/outpost and selected internal access policies |
| Primary app domain | `${DOMAIN_0}` hostnames, certificates, Blocky/k8s_gateway |
| Base/local domain | `${DOMAIN_HOST}` local infra names such as TrueNAS/OPNSense |
| ACME email and DNS provider token | cert-manager ClusterIssuer |

Recommended network shape:

- Put cluster nodes on a dedicated subnet or VLAN when your router/switch can
  support it. This makes firewalling, DHCP reservations, LoadBalancer address
  ownership, and storage access easier to reason about.
- Reserve node IPs, the Kubernetes API VIP, and all LoadBalancer IPs outside
  DHCP. The API VIP must be different from every node IP.
- Keep Kubernetes pod/service CIDRs (`${PODNET}` / `${SVCNET}`) separate from
  LAN, VPN, Docker, and site-to-site networks.
- Keep `${KUBERNETES_SERVICE_HOST_IP}` and
  `${KUBERNETES_SERVICE_HOST_CIDR}` aligned with the first address in
  `${SVCNET}` unless you intentionally choose a different Kubernetes service
  network layout.
- A flat LAN is fine for a small starter lab; use `LAN_CIDR`,
  `VLAN20_GATEWAY`, and `VLAN20_CIDR` as "cluster node subnet" values even if
  you are not literally using VLAN 20.
- The template makes an opinionated certificate choice: Cloudflare DNS-01 via
  `${DOMAIN_0_CLOUDFLARE_TOKEN}`. Other DNS providers are possible, but require
  changing the ClusterIssuer values/manifests, not just replacing the token.

Primary files:

- `clusters/main/clusterenv.yaml`
- `clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml`
- `clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml`
- `clusters/main/kubernetes/core/metallb-config/app/*`
- `clusters/main/kubernetes/network/gateway-api/app/*`

## 3. Node inventory

The template ships with a larger reference topology. Trim it to your actual
machines before generating machine configs.

For each node, decide:

- Hostname and static IP.
- NIC MAC address used by Talos `deviceSelector`.
- Control-plane or worker role.
- Install disk selector.
- Whether it needs GPU, Coral, or storage mounts.
- Whether a small cluster should set `allowSchedulingOnControlPlanes: true`.

The sample `talconfig.yaml` starts with `k8s-control-2`, while
`MASTER1IP` is retained for clustertool compatibility. You can either keep that
sample numbering, add a real `k8s-control-1` node with matching variables, or
rename the sample nodes to a clearer sequence. When adding future nodes, add
both the variables in `clusterenv.yaml` and the matching node entry or patch in
`clusters/main/talos/talconfig.yaml`.

Primary file:

- `clusters/main/talos/talconfig.yaml`

Generate configs with:

```bash
clustertool genconfig
# or: talhelper genconfig
```

Apply/bootstrap commands are in `docs/bootstrapping.md`.

## 4. Storage dependencies

Decide which storage integrations you will actually use on day one.

| Dependency | Template areas |
|---|---|
| Longhorn/OpenEBS local storage | `system/longhorn`, `system/openebs`, Talos storage mounts |
| NFS/RWX shares | `system/truenas-rwx`, PVCs with `truenas.${DOMAIN_HOST}` |
| S3/object storage | VolSync, CNPG backups, app-specific backup credentials |
| Etcd snapshots | `system/etcd-backup` |

If NFS shares, S3 buckets, DNS zones, or firewall rules are created with
Terraform in your environment, apply that infrastructure before Flux expects
the services to mount or back up to it. This repository does not require
Terraform, but it assumes those external resources exist when the corresponding
services are enabled.

## 5. Service ramp-up

Do not enable everything blindly on tiny hardware. Start with the platform
layers, then add user workloads.

Suggested order:

1. `kube-system`: Cilium, CoreDNS, metrics-server.
2. `system`: cert-manager, Gateway API CRDs, storage, Flux dependencies.
3. `core`: ClusterIssuer, MetalLB config, Blocky.
4. `network`: Gateway API, Tailscale, Omada/Mosquitto if needed.
5. `apps`: Headlamp/Homepage first, then stateful apps like Nextcloud,
   Vaultwarden, Paperless, Forgejo, and custom apps.

For a service you do not want yet, remove or comment its `ks.yaml` from the
category `kustomization.yaml`. Re-run:

```bash
./scripts/check-repo.sh
mise run validate
```

## 6. AI assistant use

AI assistants are optional. The canonical onboarding path is this document,
`docs/bootstrapping.md`, and the helper scripts. If you do use an assistant,
`AGENTS.md` and `CLAUDE.md` tell it how to avoid unsafe cluster context,
plaintext secrets, stale service patterns, and invalid YAML.
