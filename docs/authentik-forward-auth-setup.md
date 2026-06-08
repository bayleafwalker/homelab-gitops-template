# Authentik Outpost with Gateway API

## Overview
This cluster uses Gateway API (Cilium/Envoy) for HTTP routing. For Authentik outpost integrations, route `/outpost.goauthentik.io` with `HTTPRoute` instead of creating Kubernetes `Ingress`.

## Authentik UI setup

1. Open `https://auth.example.com`.
2. Create a Proxy Provider per app:
   - Type: `Forward auth (single application)`
   - External host: `https://<app>.${DOMAIN_0}`
3. Create an Application for each provider.
4. Create an Outpost for each application and copy its token.

## Deploy outpost in app namespace

```yaml
# clusters/main/kubernetes/apps/<app>/app/authentik-outpost.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: authentik-outpost
  namespace: <app-namespace>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: authentik-outpost
  namespace: <app-namespace>
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: authentik-proxy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: authentik-proxy
    spec:
      serviceAccountName: authentik-outpost
      containers:
        - name: proxy
          image: ghcr.io/goauthentik/proxy:2024.12.3
          ports:
            - containerPort: 9000
              name: http
              protocol: TCP
          env:
            - name: AUTHENTIK_HOST
              value: https://auth.example.com
            - name: AUTHENTIK_TOKEN
              valueFrom:
                secretKeyRef:
                  name: authentik-outpost-token
                  key: token
            - name: AUTHENTIK_INSECURE
              value: "false"
---
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost
  namespace: <app-namespace>
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: authentik-proxy
  ports:
    - name: http
      port: 9000
      targetPort: http
```

Create token secret:

```bash
kubectl create secret generic authentik-outpost-token \
  -n <app-namespace> \
  --from-literal=token='<AUTHENTIK_TOKEN_FROM_UI>'
```

## Route outpost path with Gateway API

```yaml
# clusters/main/kubernetes/apps/<app>/app/authentik-outpost-route.yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: authentik-outpost
  namespace: <app-namespace>
spec:
  hostnames:
    - <app>.${DOMAIN_0}
  parentRefs:
    - name: internal
      namespace: gateway
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /outpost.goauthentik.io
      backendRefs:
        - name: authentik-outpost
          port: 9000
```

If `HTTPRoute` and backend service are in different namespaces, add a `ReferenceGrant` in the backend namespace.

## Recommended app integration pattern

- Prefer app-native OIDC/OAuth against Authentik when available.
- Use outpost path routing only where the app requires Authentik proxy mode.
- Avoid introducing new ingress-controller-specific annotations.

## Validation

- `kubectl get httproute -n <app-namespace>`
- `kubectl get pods -n <app-namespace> -l app.kubernetes.io/name=authentik-proxy`
- Access `https://<app>.${DOMAIN_0}` and verify login redirect + callback.

## Troubleshooting

- Check outpost logs: `kubectl logs -n <app-namespace> -l app.kubernetes.io/name=authentik-proxy`
- Verify `HTTPRoute` has `Accepted=True` and `ResolvedRefs=True`
- Verify `ReferenceGrant` exists if using cross-namespace backend refs
