# Gateway API (Cilium / Envoy) in this cluster

This document describes the **cluster-scoped Gateway API primitives** and the **per-service resources** used to expose apps through the internal (LAN) Gateway.

For post-cutover operational validation, use the Gateway API steady-state checklist in `docs/operations.md`.

## Network assumptions

The Gateway is designed as an internal LAN/VLAN entrypoint, not a public edge.
`${GATEWAY_INTERNAL_IP}` should be a reserved LoadBalancer address on the
cluster node subnet and outside DHCP. If possible, place cluster nodes and the
LoadBalancer pool on a dedicated subnet/VLAN so Gateway traffic, storage
traffic, and administrative access can be firewalled separately from client
devices.

This template uses Cilium Gateway API as the opinionated HTTP routing layer.
Legacy nginx/Traefik ingress-controller paths are intentionally not the default
for new services.

## Cluster primitives (shared)

### Internal Gateway (LAN)

The internal Gateway is defined in:

- `clusters/main/kubernetes/network/gateway-api/app/internal-gateway.yaml`

Key points:

- `gatewayClassName: cilium` (Cilium Gateway API implementation, Envoy dataplane).
- Address is pinned to `${GATEWAY_INTERNAL_IP}`.
- Two listeners:
  - `http` on `:80` (used only for redirect routes)
  - `https` on `:443` (terminates TLS)
- `allowedRoutes.namespaces.from: All` so app namespaces can attach routes.

### LoadBalancer IP + L2 advertisement (MetalLB replacement for the Gateway)

The Gateway’s service IP assignment and L2 advertisement are handled by Cilium resources:

- `clusters/main/kubernetes/network/gateway-api/app/cilium-lbippool.yaml`
- `clusters/main/kubernetes/network/gateway-api/app/cilium-l2announcementpolicy.yaml`

They select the Gateway service via labels and pin it to `${GATEWAY_INTERNAL_IP}`.

### TLS certificate for the Gateway listener

The Gateway listener uses the wildcard secret stored in the `clusterissuer` namespace:

- Gateway references: `certificate-issuer-domain-0-wildcard` in `clusterissuer`
- Cross-namespace reference is allowed by:
  - `clusters/main/kubernetes/core/clusterissuer/app/gateway-api-referencegrant.yaml`

## DNS behavior (Blocky `k8s_gateway`)

Blocky is configured to synthesize DNS records from:

- `Service`, `Gateway`, `HTTPRoute`

See:

- `clusters/main/kubernetes/core/blocky/app/helm-release.yaml:90`

Operational implication:
- DNS appears when a route is admitted/programmed and attached to the Gateway address.
- Negative DNS caching can delay visibility after a change (`cacheTimeNegative: 5m` in Blocky).

## Per-service resources (pattern)

### 1) `HTTPRoute` for HTTPS

Attach the app route to the `https` listener:

- `parentRefs.name: internal`
- `parentRefs.namespace: gateway`
- `parentRefs.sectionName: https`

### 2) Optional HTTP → HTTPS redirect

Create a second `HTTPRoute` attached to the `http` listener using `RequestRedirect`.

### 3) Optional `/outpost.goauthentik.io` path

Some services route `PathPrefix /outpost.goauthentik.io` to `authentik-http:10230` for Authentik outpost endpoints.

Important:

- This path routing **does not** by itself enforce authentication.
- Forward-auth (nginx annotations) is controller-specific; if you need edge auth on Gateway API routes, prefer app-native OIDC or implement an Envoy/Cilium-specific auth layer.

### 4) Cross-namespace backendRefs require `ReferenceGrant`

If an `HTTPRoute` in namespace `X` references a `Service` in namespace `Y`, the **target namespace** must allow it via a `ReferenceGrant`.

Example (Authentik service referenced by Paperless and Headlamp routes):

- `clusters/main/kubernetes/apps/authentik/app/gateway-api-referencegrant.yaml`

## New service setup (Gateway API-first)

For a new HTTP service `foo` in namespace `apps`:

1. Add route manifests in `clusters/main/kubernetes/apps/foo/app/gateway-api-routes.yaml`:
   - `HTTPRoute` attached to `gateway/internal` + `sectionName: https`
   - optional HTTP redirect route on `sectionName: http`
2. Add the route file to `clusters/main/kubernetes/apps/foo/app/kustomization.yaml`.
3. If the backend service is in another namespace, add `ReferenceGrant` in the backend namespace.
4. Reconcile and verify:
   - `kubectl get httproute -n apps`
   - `kubectl -n gateway get gateway internal -o wide`
   - `dig @${BLOCKY_IP} foo.${DOMAIN_0}`
5. Confirm endpoint health and TLS via Gatus/blackbox checks.

## Pilot examples

### Paperless

- Routes: `clusters/main/kubernetes/apps/paperless/app/gateway-api-routes.yaml`
- Notes:
  - Uses a dedicated `HTTPRoute` for HTTP→HTTPS redirect.
  - References `authentik-http` (cross-namespace) for the outpost path, enabled via `ReferenceGrant`.

### Headlamp

- Routes: `clusters/main/kubernetes/apps/headlamp/app/gateway-api-routes.yaml`
- Notes:
  - Publishes `kube.${DOMAIN_0}` on the internal Gateway.
  - Includes the outpost path route for consistency with other UIs.

### Omada Controller

- Routes: `clusters/main/kubernetes/network/omada-controller/app/gateway-api-routes.yaml`
- Upstream proxy: `clusters/main/kubernetes/network/omada-controller/app/omada-gateway-proxy.yaml`
- Notes:
  - Omada’s upstream UI listens on `:8043` with a self-signed certificate. The internal proxy bridges **HTTP (from Envoy)** → **HTTPS (to Omada)** with TLS verification disabled.
  - AP communication ports remain on the existing `LoadBalancer` services in `omada-controller` (not routed via Gateway API), since this cluster currently only has Gateway API CRDs for `HTTPRoute`/`GRPCRoute`.

## Onboarding checklist (Ingress → Gateway API)

1. Add `gateway-api-routes.yaml` with:
   - `HTTPRoute` for `https`
   - (optional) `HTTPRoute` redirect for `http`
2. If routing to a cross-namespace service, add a `ReferenceGrant` in the target namespace.
3. Decide DNS cutover strategy:
   - pilot hostname (`*-gw.${DOMAIN_0}`) first, or
   - direct cutover with a single owner of the production hostname
4. Verify network policies:
   - For default-deny namespaces, ensure ingress is allowed from the Cilium Gateway dataplane (Envoy).
   - Prefer `CiliumNetworkPolicy` with `fromEntities: [ingress, host, remote-node]` for Gateway→backend traffic; the Envoy dataplane runs as `hostNetwork` and is not reliably matchable via namespace/pod selectors in a standard `NetworkPolicy`.
5. Keep chart ingress disabled unless a chart hard-requires it at render time:
   - preferred: `ingress.*.enabled: false`
   - if chart requires ingress: keep values enabled but remove rendered Ingress via post-render patch
