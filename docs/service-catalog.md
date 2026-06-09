# Optional service catalog

The default reconciliation set is intentionally lean. Richer examples remain in
the tree as opt-in paths: uncomment the relevant `ks.yaml`, replace required
variables/secrets, then validate before pushing.

Default foundation:
- `kube-system`: Cilium, CoreDNS, kubelet-csr-approver, metrics-server.
- `system`: cert-manager, Gateway API CRDs, MetalLB.
- `network`: Gateway API.
- `core`: MetalLB config.

## Enablement workflow

1. Read the service notes below and any linked runbook.
2. Replace the listed variables and secrets in `clusters/main/clusterenv.yaml`,
   `clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml`, and
   `cluster-secrets.secret.yaml`.
3. Uncomment the service `ks.yaml` in the category `kustomization.yaml`.
4. Build the service app and the root tree:
   ```bash
   kustomize build clusters/main/kubernetes/<category>/<service>/app
   mise run validate
   ./scripts/check-repo.sh
   ```

## Gateway API and Cilium Envoy

- Purpose: internal HTTPS entrypoint using Cilium Gateway API.
- Enabled by default: `network/gateway-api/ks.yaml`.
- Variables/secrets: `GATEWAY_INTERNAL_IP`, `DOMAIN_0`, `DOMAIN_HOST`.
- Storage: none.
- Route/DNS: reserve `GATEWAY_INTERNAL_IP` in the LoadBalancer pool and point
  internal DNS for `*.${DOMAIN_0}` at that IP, or enable Blocky/k8s_gateway.
- Common failures: Gateway IP outside the advertised pool, Cilium Gateway API
  support not ready, or DNS still pointing at an old ingress controller.

## ClusterIssuer and Blocky

- Purpose: certificates and internal DNS helper services.
- Enablement files: `core/clusterissuer/ks.yaml`, `core/blocky/ks.yaml`.
- Variables/secrets: `DOMAIN_0`, `DOMAIN_0_EMAIL`,
  `DOMAIN_0_CLOUDFLARE_TOKEN`, `BLOCKY_IP`, `LAN_CIDR`.
- Storage: none.
- Route/DNS: ClusterIssuer defaults to Cloudflare DNS-01. Other providers need
  manifest changes. Blocky needs a reserved LoadBalancer IP.
- Common failures: DNS token lacks zone permissions, cert requests still use
  placeholder domains, or clients are not pointed at Blocky.

## Storage, snapshots, and backups

- Purpose: stateful storage, snapshots, S3 backups, and RWX examples.
- Enablement files: `system/longhorn/ks.yaml`,
  `system/snapshot-controller/ks.yaml`, `system/volsync/ks.yaml`,
  `system/openebs/ks.yaml`, `system/truenas-rwx/ks.yaml`.
- Variables/secrets: `TRUENAS_IP`, `DOMAIN_HOST`, `HETZNER_S3_BUCKET_NAME`,
  `HETZNER_S3_BUCKET_ENDPOINT`, `HETZNER_ACCESS_KEY`, `HETZNER_SECRET_KEY`,
  `VOLSYNC_RESTIC_PASSWORD`.
- Storage: matching Talos disk selectors and/or existing NFS exports.
- Route/DNS: `truenas.${DOMAIN_HOST}` must resolve from cluster nodes if using
  the TrueNAS examples.
- Common failures: Talos disk selectors do not match real disks, missing iSCSI
  extensions, NFS paths are example-only, or S3 credentials are placeholders.

## Authentik

- Purpose: identity provider and forward-auth source for admin services.
- Enablement files: `system/cloudnative-pg/ks.yaml`, `apps/authentik/ks.yaml`;
  add `apps/authentik-ldap-outpost/ks.yaml` only if LDAP is needed.
- Variables/secrets: `AK_ADMIN_PASSWORD`, `DOMAIN_0`, `LDAP_OUTPOST_TOKEN`,
  `AUTHENTIK_CERT_SYNC_TOKEN`, S3/VolSync values if backups are enabled.
- Storage: CNPG database plus optional media/data PVC backups.
- Route/DNS: `auth.${DOMAIN_0}` via Gateway API and certificates.
- Common failures: CNPG not installed first, placeholder admin password/token,
  missing ClusterIssuer, or forward-auth routes enabled before Authentik is up.

## Forgejo and runners

- Purpose: self-hosted Git forge plus optional CI runners.
- Enablement files: `system/cloudnative-pg/ks.yaml`, `apps/forgejo/ks.yaml`,
  `system/forgejo-runner/ks.yaml`.
- Variables/secrets: `FORGEJO_SSH_IP`, `DOMAIN_0`,
  `apps/forgejo/app/forgejo-admin.secret.yaml`, runner token if enabling the
  Forgejo runner.
- Storage: CNPG database and persistent app storage.
- Route/DNS: HTTPRoute for web UI and LoadBalancer IP for SSH.
- Common failures: SSH IP outside pool, admin secret still placeholder, CNPG not
  ready, or Gateway certificate not issued.

## GitHub Actions Runner Controller

- Purpose: self-hosted GitHub runners.
- Enablement files: `system/github-actions-runner/ks.yaml`; enable
  `system/kubernetes-reflector/ks.yaml` if sharing the GitHub App secret across
  namespaces.
- Variables/secrets: `arc-github-app.secret.yaml` with real GitHub App ID,
  installation ID, and private key.
- Storage: none by default.
- Route/DNS: none.
- Common failures: GitHub App lacks repository permissions, private key is not
  SOPS-encrypted, or reflector is disabled while the runner namespace expects
  reflected credentials.

## Private registry

- Purpose: internal registry/mirror for cluster images and custom app examples.
- Enablement file: `system/registry/ks.yaml`.
- Variables/secrets: `REGISTRY_IP`, `REGISTRY_HOST`,
  `REGISTRY_SERVICE_ENDPOINT`, S3/VolSync values if backups are enabled.
- Storage: persistent registry PVC.
- Route/DNS: registry hostname and optional Talos registry patch.
- Common failures: Talos nodes cannot trust/reach the mirror, registry IP is
  outside the pool, or certificate hostname does not match.

## Nextcloud and Collabora

- Purpose: file sync/groupware and browser office editing.
- Enablement files: `system/cloudnative-pg/ks.yaml`, storage services,
  `apps/nextcloud/ks.yaml`, and optionally `apps/collabora/ks.yaml`.
- Variables/secrets: `NEXTCLOUD_USERNAME`, `NEXTCLOUD_PASSWORD`,
  `NEXTCLOUD_CNPG_PASSWORD`, `DOMAIN_0`, S3/VolSync values.
- Storage: RWX or large persistent data PVC plus CNPG.
- Route/DNS: `nextcloud.${DOMAIN_0}` and optional Collabora route.
- Common failures: missing RWX claim, SSRF protection when OIDC points at an
  internal Gateway IP, or CNPG backup credentials still placeholders.

## Vaultwarden

- Purpose: password manager example.
- Enablement files: `apps/vaultwarden/ks.yaml`; enable storage/VolSync and CNPG
  dependencies as needed by the chart values.
- Variables/secrets: `VAULTWARDEN_ADMIN_TOKEN`, `DOMAIN_0`, S3/VolSync values.
- Storage: app data PVC and database backup path.
- Route/DNS: `vaultwarden.${DOMAIN_0}` via Gateway API.
- Common failures: admin token still placeholder, missing certificate, or backup
  repository points at an uncreated bucket.

## Paperless-ngx

- Purpose: document management example.
- Enablement files: `system/cloudnative-pg/ks.yaml`, relevant storage service,
  `apps/paperless/ks.yaml`.
- Variables/secrets: `PAPERLESS_CNPG_PASSWORD`, `DOMAIN_0`, S3/VolSync values.
- Storage: document/media PVC and CNPG database.
- Route/DNS: `paperless.${DOMAIN_0}` via Gateway API.
- Common failures: missing NFS path/PVC, CNPG not ready, or placeholder database
  password.

## Gatus and blackbox-exporter

- Purpose: internal service checks with Gatus and edge/public probes with
  blackbox-exporter.
- Enablement files: `apps/gatus/ks.yaml`, `system/blackbox-exporter/ks.yaml`,
  and `system/networkpolicies/ks.yaml` if using the policy examples.
- Variables/secrets: `DOMAIN_0`; monitored endpoints must match enabled
  services.
- Storage: none.
- Route/DNS: Gatus UI route optional; checks should use ClusterIP DNS.
- Common failures: checks for disabled services, missing cross-namespace policy
  allows, or using Gateway hairpin paths for internal health.

## GPU, NVIDIA, and Coral examples

- Purpose: hardware acceleration examples for workloads that request GPUs or
  Coral devices.
- Enablement files: `kube-system/node-feature-discovery/ks.yaml`,
  `kube-system/nvidia-device-plugin/ks.yaml` or `kube-system/gpu-operator/ks.yaml`,
  and `kube-system/generic-device-plugin/ks.yaml` for Coral examples.
- Variables/secrets: matching node IP/MAC variables and Talos GPU/Coral patches.
- Storage: none for device plugins.
- Route/DNS: none.
- Common failures: Talos schematic lacks extensions, node labels do not match,
  NVML libraries are absent, or a workload requests GPU before the runtime class
  and device plugin are ready.
