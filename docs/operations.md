# Operations

## Prep
- Install `talosctl`, `flux`, `sops`, and `clustertool` (via `mise install` — pinned in `mise.toml`).
- Use the repo’s `direnv` config to avoid accidentally targeting a global kubeconfig: `direnv allow` and then `direnv exec . <cmd>`.
- Prefer direct `direnv exec . kubectl ...`, `direnv exec . flux ...`, and
  `direnv exec . talosctl ...` commands. Avoid `direnv exec . bash -lc
  'kubectl ...'` for cluster diagnostics because login shell startup can reset
  the kubeconfig before the command runs.
- Generate an age key and point `.sopsrc` at it; keep the private key off the repo.
- Edit `clusters/main/talos/talconfig.yaml` and the SOPS-encrypted `clusterenv.yaml` with cluster name, IPs, CIDRs, and domains.
- Create/encrypt required secrets in `clusters/main/kubernetes/flux-system/flux` (`deploykey.secret.yaml`, `clustersettings.secret.yaml`, `sops-age`, etc.).

## Bootstrap
- With clustertool: `clustertool talos bootstrap` applies Talos configs, installs Flux, and reconciles sources/releases.
- Manual Flux: run `flux bootstrap git --url=ssh://git@github.com/your-username/your-homelab-repo.git --branch=main --path=clusters/main/kubernetes/flux-system/flux --private-key-file=./deploy-key`.
- After bootstrap, reconcile once: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.

## Day-2 workflows
- Apply Git changes; Flux will sync automatically (10–15m intervals). To force: `flux reconcile kustomization flux-entry`.
- Add a workload: create a HelmRelease under the appropriate folder (apps/network/system/core/media), reference an existing HelmRepository, and include it in the local `kustomization.yaml`.
- Update configuration values via SOPS-encrypted files; keep plaintext out of Git.
- Check status: `flux get ks -A`, `flux logs --kind=Kustomization --name=<name>`.

## Expected disabled services

Some services are intentionally not reconciled from top-level category kustomizations. This is expected:
- `core/traefik`
- `system/traefik-crds`
- `network/nginx-internal`
- `network/nginx-external`

Operational stance:
- Treat absence as "disabled by choice" unless a change request says otherwise.
- Keep each disabled service explicitly commented in its category `kustomization.yaml` with a reason.
- Flux health should remain green with these disabled.

## Disabled service drift governance

Disabled services require explicit lifecycle decisions so they do not become silent operational drift.
Track decisions wherever fits your workflow (an issue tracker, a dated runbook entry, or a
`docs/disabled-services-decision-log.md` you maintain) so "disabled by choice" stays distinguishable
from "broken and forgotten".

Review cadence:
- Monthly review (and before major migration waves): retain, retire, or remove each disabled service.
- Update both the category `kustomization.yaml` comment and the decision log entry in the same PR.

Quick review commands:
```bash
rg -n "Disabled:" clusters/main/kubernetes/*/kustomization.yaml
flux get ks -A
flux get hr -A
```

## Cluster health checks

Flux (GitOps convergence):
```bash
flux get ks -A
flux get hr -A
```

Kubernetes (workload readiness):
```bash
# Anything not Running/Succeeded needs attention
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Fast view of nodes and pressure
kubectl get nodes -o wide
kubectl top nodes || true
```

> ⚠️ The phase filter above **misses** `OOMKilled` / `CrashLoopBackOff` containers in
> pods whose phase is still `Running`. Always cross-check with a readiness-aware query,
> or a health check can report "all clean" while a worker (e.g. an Authentik worker or
> `system-upgrade-controller`) is silently crash-looping:

```bash
# Readiness-aware: catches non-Running phases AND Running pods with unready containers
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(
      (.status.phase != "Running" and .status.phase != "Succeeded")
      or (([.status.containerStatuses[]?.ready] | any(. == false)) and .status.phase != "Succeeded")
    )
  | [.metadata.namespace, .metadata.name, .status.phase] | @tsv'

# Confirm a suspected OOM from pod state (not just app logs)
kubectl -n <namespace> describe pod <pod> | grep -A2 "Last State"   # OOMKilled, exit 137
kubectl -n <namespace> logs <pod> --previous
```

Notes:
- `Completed` pods are typically CronJobs/Helm hooks and are usually OK.
- Some services may be intentionally disabled/suspended; treat those as expected if documented.
- A pod can stay `phase: Running` while a container is repeatedly `OOMKilled`. A recent
  OOM fix can also **regress** — if a memory bump doesn't hold, the ceiling is likely
  still too low; raise request/limit again rather than assuming the prior fix is intact.

## GitOps desired-state drift vs runtime health

A `HelmRelease`/`Kustomization` can report `Ready=False` while the workload is perfectly
healthy — and vice versa. The common case: a chart/image version was rolled back **live**
(or on the local branch) to recover from a bad upgrade, but `origin/main` still desires the
broken version, so Flux keeps re-applying it and reports the release as failed.

Distinguish the two before acting:
```bash
# Is the workload actually serving, or is this only a desired-state failure?
kubectl -n <namespace> get pods,hr
flux get hr -A --status-selector ready=false

# Compare what Git desires vs what is live
git status
git show origin/main:clusters/main/kubernetes/<path>/helm-release.yaml | grep -A2 -i version
```

- If the workload is healthy on a rolled-back revision, the fix is to **commit and push
  the rollback** so Git matches reality — do not touch the running cluster.
- If the workload is genuinely down, treat it as an outage: remediate the runtime first,
  then reconcile Git.

## Alert hygiene and signal policy

### Alert hygiene (known-benign warnings)

`flux logs` and chart dry-runs surface a steady trickle of non-actionable warnings (PodSecurity
advisories, expected reconcile retries, etc). Rather than paging on every warning, build an
allowlist of known-benign patterns over time — a simple regex file plus a small script that greps
recent `flux logs` output and highlights anything *not* on the list works well, and can be run
on a schedule (cron, a CI workflow, etc) once you've got a stable pattern set.

Operational rules:
- Add entries to the allowlist only after validating the warning is expected and low-risk.
- Keep patterns specific; do not use broad wildcards that could hide real incidents.
- Any unknown warning/error is actionable and must be investigated or explicitly classified.

### Signal policy (what pages vs what does not)

Page-worthy (actionable drift):
- Any `Kustomization`/`HelmRelease` not `Ready=True` beyond normal reconcile windows.
- Unknown warning/error patterns outside your allowlist.
- Availability regressions on blackbox edge probes or internal Gatus checks.

Non-paging (route to backlog/maintenance):
- Known-benign allowlisted warnings (for example recurring PodSecurity advisory lines on chart dry-run output).
- Expected/disabled services that are tracked and documented as intentional.

Routing guidance:
- Page: active service impact or unresolved reconcile/drift conditions.
- Ticket/backlog: hygiene improvements, allowlist tuning, and documented/accepted technical debt.

## Gateway API steady-state checklist

Use this as the post-migration operational baseline.

Reconciliation and health:
- `direnv exec . flux reconcile source git cluster`
- `direnv exec . flux reconcile kustomization flux-entry`
- `direnv exec . flux get ks -A`
- `direnv exec . flux get hr -A`

Route ownership and drift:
- Keep a single routing owner per hostname (this cluster standard is `HTTPRoute`).
- Compare host ownership:
  - `direnv exec . kubectl get ingress -A -o json | jq -r '.items[] | .spec.rules[]?.host' | sort -u`
  - `direnv exec . kubectl get httproute -A -o json | jq -r '.items[] | .spec.hostnames[]?' | sort -u`

DNS and Gateway readiness:
- `direnv exec . kubectl get httproute -A`
- `direnv exec . kubectl -n gateway get gateway internal -o wide`
- Verify in-cluster DNS from a test pod in `gatus` (or equivalent namespace).

Policy, TLS, and auth:
- Confirm default-deny namespaces explicitly allow Gateway dataplane ingress.
- Confirm cross-namespace route targets have matching `ReferenceGrant`.
- Validate certificate issuance/expiry and Authentik-backed auth flows for critical services.

Backup and rollback posture:
- Run at least one periodic restore drill for critical PVCs.
- Keep rollback-ready commit SHAs/manifests for high-blast-radius services (auth, monitoring, DNS path).

## DNS + route discovery delays (Blocky / k8s_gateway)

This cluster uses Blocky (`clusters/main/kubernetes/core/blocky/app/helm-release.yaml`) with the `k8s_gateway` CoreDNS plugin enabled for `${DOMAIN_0}`. `k8s_gateway` synthesizes DNS records from Gateway API routes (`HTTPRoute`) and Gateway addresses.

When a new service is deployed and its `HTTPRoute` exists but DNS does not resolve yet, the usual causes are:
- The route is not yet admitted/programmed (`Accepted/ResolvedRefs` false), so `k8s_gateway` has nothing stable to return.
- You queried too early and Blocky (and/or upstream DNS like OPNSense/AdGuard, and/or the client OS) negative-cached NXDOMAIN. In this cluster, Blocky is configured with `caching.cacheTimeNegative: 5m`, so “it starts working later” without any config changes.
- Even after it resolves, Blocky caches positive answers for at least `15m` (`caching.minTime: 15m`), so DNS changes can look “sticky” unless caches are cleared.
- The “up to ~2h” cases are typically *multiple caches compounding* (client OS/browser + AdGuard/OPNSense + Blocky) plus the time it takes Flux → Helm → Gateway/HTTPRoute reconciliation.

Fast checks:
- Confirm route admission: `kubectl get httproute -A`.
- Confirm Gateway address: `kubectl -n gateway get gateway internal -o wide`.
- Confirm you’re querying Blocky directly: `dig @${BLOCKY_IP} <svc>.${DOMAIN_0}`.
- If routes are admitted but you still get NXDOMAIN, flush caches (client + upstream resolver + Blocky) or restart Blocky to clear negative cache: `kubectl -n blocky rollout restart deploy/blocky`.

Notes:
- This cluster standard is Gateway API (`Gateway` + `HTTPRoute`) for HTTP routing.
- Legacy ingress-controller resources are decommissioned and should not be used for new services.

## ACME DNS01 failures: “Found no Zones for domain …”

If cert-manager is using a Cloudflare DNS01 issuer and you see an error like:
- `Found no Zones for domain _acme-challenge.domain.com ...`

It usually means *something is requesting a certificate for the wrong domain* (often a placeholder like `*.domain.com`).

Fast checks:
- Identify the requesting hostnames:
  - `kubectl -n <ns> get ingress -o wide`
  - `kubectl -n <ns> get certificate,order,challenge -o wide`
- Confirm the host matches the zone you actually manage (for this repo: `${DOMAIN_0}`).

Fix:
- Remove/replace the incorrect Ingress host(s) in Git (preferred), then reconcile the HelmRelease/Kustomization.
- If you must hotfix live, use the *concrete* hostname (e.g. `auth.example.com`). Flux variable substitution (`${DOMAIN_0}`) only happens during Kustomize reconciliation, not when patching resources directly with `kubectl`.
- After correcting the Ingress host(s), cert-manager will usually garbage-collect the old `Certificate`/`Order`/`Challenge`. If it doesn’t, delete the stuck resources in the namespace and let them re-create.

## CloudNativePG webhook TLS errors: “x509: certificate signed by unknown authority”

Symptom:
- Helm releases that manage CNPG `Cluster` resources (e.g. Authentik/Vaultwarden) fail with errors like:
  - `failed calling webhook "mcluster.cnpg.io" ... tls: failed to verify certificate: x509: certificate signed by unknown authority`

Cause (common in recommissioned clusters):
- A stale/duplicate CNPG installation (often in a legacy `cnpg-system` namespace) fights with the current one, or the CNPG webhook `caBundle` drifted to the wrong certificate.

Remediation checklist:
- Ensure there is only one CNPG controller running (this repo manages it via `clusters/main/kubernetes/system/cloudnative-pg/`).
- Verify the webhook `caBundle` matches the CA in `cloudnative-pg/cnpg-ca-secret` (not the serving cert).
- Reconcile the affected HelmRelease(s) after the webhook is healthy.

## Monitoring (Grafana / Prometheus / Alertmanager)

Gateway API endpoints:
- Grafana: `https://grafana.${DOMAIN_0}`
- Prometheus: `https://prometheus.${DOMAIN_0}`
- Alertmanager: `https://alertmanager.${DOMAIN_0}`

Grafana admin credentials are stored in a Secret created by the chart:
```bash
kubectl -n kube-prometheus-stack get secrets | rg -i grafana
kubectl -n kube-prometheus-stack get secret <grafana-secret> -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Uptime/TLS checks:
- `system/blackbox-exporter` probes every routed host (and a few external endpoints like OPNSense/TrueNAS) and raises alerts like `BlackboxProbeFailed` and `BlackboxProbeSslCertExpiringSoon`.

Internal service-health checks:
- `apps/gatus` probes in-cluster service paths (`*.svc.cluster.local`) and should run with:
  - `dnsPolicy: ClusterFirst`
  - matching cross-namespace Cilium policies for allowed targets
- Optional strict profile:
  - use a dedicated label (e.g. `policy.example.com/gatus-internal=true`) on a checker workload
  - scope restrictive egress Cilium policies to that identity
- Quick summary check:
  - `direnv exec . kubectl -n gatus port-forward svc/gatus 18080:8080`
  - `curl -ksS 'http://127.0.0.1:18080/api/v1/endpoints/statuses?page=1&pageSize=500' | jq -r '[.[] | (.results[-1].success // false)] | "total=\(length) healthy=\(map(select(.==true))|length) failing=\(map(select(.!=true))|length)"'`
- Maintenance workflow and validation steps: `docs/gatus-monitoring-maintenance.md`

Home Assistant notifications:
- Alertmanager posts the raw Alertmanager webhook payload as a Home Assistant event to `https://${HOMEASSISTANT_URL}/api/events/alertmanager` (auth via `${HOMEASSISTANT_TOKEN}`).
- Create an HA automation with an Event trigger (`event_type: alertmanager`) and forward it to your preferred notify target (mobile app, Discord, etc).

## Backups (Longhorn + Hetzner S3)

This cluster’s *offsite* backups are primarily handled by Longhorn, backed by Hetzner Object Storage:
- Backup target: `longhorn-system/backuptarget.default` → `s3://${HETZNER_S3_BUCKET_NAME}@hel1/longhorn`
- Credentials: `longhorn-system/secret/longhorn-hetzner-s3` (values substituted from `flux-system/cluster-config`)
- Recurring jobs: `longhorn-system/recurringjob.daily-backup` (retain 14) and `longhorn-system/recurringjob.weekly-full-backup` (retain 4)

What is (and isn’t) covered:
- Covered: PVCs using the `longhorn` StorageClass (most “app config” PVCs such as Omada/custom-app configs).
- Not covered: static RWX PVs like `truenas-rwx` and other NFS-backed mounts. Those must be backed up from the storage side (TrueNAS snapshots/replication) or via file-level jobs that read the mount and push to S3.
- VolSync: used for a small set of critical PVCs (Restic → Hetzner S3). See `docs/backups-volsync.md`.
- Talos etcd: daily etcd snapshots are uploaded to S3. See `docs/etcd-snapshots.md`.

Quick health checks:
```bash
kubectl -n longhorn-system get backuptarget default -o wide
kubectl -n longhorn-system get recurringjobs.longhorn.io
kubectl -n longhorn-system get backups.longhorn.io | tail
```

Check whether a service’s PVC is included:
```bash
kubectl -n <ns> get pvc -o wide
# If STORAGECLASS is longhorn, it should be included in Longhorn recurring backups.
```

Restore drill (recommended before bulk upgrades):
- Pick a small “config” PVC (e.g. `custom-app/custom-app-config`), restore its Longhorn backup into a *new* PVC/volume, mount it in a throwaway pod, and validate contents.
- Prefer doing the actual restore workflow via the Longhorn UI (fastest) unless you’re already automating restores via CRDs.

## Flux notifications (Discord)

Flux health notifications (Kustomization/HelmRelease/GitRepository errors) are sent to Discord via the resources in `clusters/main/kubernetes/flux-system/notifications/`.

Quick checks:
```bash
flux get alert-providers -n flux-system
flux get alerts -n flux-system
```

## Code-server maintenance workflow
- The TrueCharts code-server (`clusters/main/kubernetes/apps/vscode/app/helm-release.yaml`) bootstraps kubectl/talosctl/flux/helm into `/tools`; PATH already includes it for the main container.
- Keep kubeconfig/talosconfig and any decrypted files in your home/workspace only as needed; rely on SOPS for secrets. Avoid committing anything under `/workspace` unless intended.
- For LLM-assisted health checks without installing tooling locally, run the CLIs directly in the code-server terminal or start a small MCP process bound to localhost/stdio that wraps read-only commands (kubectl get/describe, `flux get`, Talos node health). Do not expose it via public routes; use the browser session or Tailscale/port-forwarding if you must connect externally.
- If you later decide to run MCP as a cluster service, follow `docs/service-deployment-guide.md` for the standard app pattern and begin with read-only RBAC plus narrowly allowlisted reconcile/reboot functions.

## Talos and cluster maintenance
- Generate machine configs from `talconfig.yaml` and apply with `talosctl apply --insecure` followed by `talosctl bootstrap` (initial) or `talosctl upgrade` (if needed).
- System Upgrade Controller plans in `core/system-upgrade-controller-plans` consume `upgrade-settings` to roll Talos/Kubernetes updates once versions are bumped; they only act on nodes labeled with `${UPGRADE_NODE_LABEL}=true`.
- Use `flux reconcile kustomization system-upgrade-controller-plans` to push plan changes promptly.
