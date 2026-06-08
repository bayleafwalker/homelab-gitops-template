# Gatus Monitoring Maintenance

## Long-Term Intent
- Keep `gatus` focused on in-cluster checks (`*.svc.cluster.local`) with explicit cross-namespace allows.
- Keep edge/public-path checks in `blackbox-exporter`.
- Treat all validation/debug actions as Git-managed maintenance workflows, not one-off runtime state.

## Validating Internal Checks

There's no bundled maintenance script in this template — the steps below are
the manual equivalent. If you find yourself running these often, consider
writing a small script (e.g. `bin/gatus-maintenance.sh`) that wraps them.

### Validate internal connectivity path
```bash
# Run a one-off probe pod inside the gatus namespace and curl each internal
# target's ClusterIP path directly (bypassing Gatus itself):
kubectl run -n gatus gatus-probe --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sv http://homepage.apps.svc.cluster.local:10352/

# Then confirm the relevant Cilium policies are admitted:
kubectl get cnp,netpol -n gatus -o wide
```

### Validate internal endpoint status in Gatus
```bash
# Confirm the endpoint is defined in config...
kubectl get configmap -n gatus gatus-config -o yaml | grep -A2 "name: <Endpoint Name>"

# ...then check its live status via the Gatus API/UI (port-forward or HTTPRoute):
kubectl port-forward -n gatus svc/gatus 8080:8080
curl -s http://localhost:8080/api/v1/endpoints/statuses | jq '.[] | {name, results: .results[-1]}'
```

### Run gateway hairpin diagnostics
When investigating Gateway-routed hosts that don't resolve/connect cleanly
from inside the cluster (the "hairpin" problem — a pod resolving its own
public hostname back to the internal Gateway IP), capture a deny/allow matrix
by testing each path (ClusterIP, internal Gateway IP, public hostname) from a
probe pod under the current NetworkPolicy set, and record the results in a
dated note before changing policy.

### Cleanup temporary maintenance resources
```bash
kubectl delete pod -n gatus -l app=gatus-probe --ignore-not-found
```

## Required Git-Managed Objects
- `clusters/main/kubernetes/apps/gatus/app/configmap.yaml`
- `clusters/main/kubernetes/apps/gatus/app/helm-release.yaml`
- `clusters/main/kubernetes/system/networkpolicies/app/gatus-default-deny.yaml`
- `clusters/main/kubernetes/system/networkpolicies/app/gatus-allow-dns.yaml`
- `clusters/main/kubernetes/system/networkpolicies/app/gatus-allow-ingress-cilium-gateway.cnp.yaml`
- `clusters/main/kubernetes/system/networkpolicies/app/gatus-internal-allow-egress-core-services.cnp.yaml`
- service-specific ingress allows in `clusters/main/kubernetes/system/networkpolicies/app/*allow-ingress-gatus-internal*.cnp.yaml`
  (for example `apps-homepage`, `authentik`, `nextcloud`, `paperless`, `custom-app`, `vaultwarden`, `vscode`, `kube-prometheus-stack`, `headlamp`, `registry`, `couchdb`, `omada-controller`)

## Operational Boundaries
- `gatus` steady state:
  - `default-deny` enabled in namespace `gatus`
  - internal endpoints only in `gatus` config
  - edge/public checks in `blackbox-exporter`
- Do not use ad-hoc runtime patches for steady-state behavior; update manifests in Git and reconcile.

## Maintenance Cadence

### Weekly
Spot-check that internal endpoint definitions in `configmap.yaml` still match
deployed services, and that Gatus shows them healthy.

### After any Gatus, policy, DNS, or route change
Run the connectivity + status validation steps above to confirm both the
direct path and the Gatus-reported status agree.

### Quarterly hygiene
- Review monitored internal endpoint list in `clusters/main/kubernetes/apps/gatus/app/configmap.yaml`.
- Remove stale checks for retired services.
- Add explicit cross-namespace policy allows for any newly added internal checks.
