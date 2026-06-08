# Nextcloud Office + Collabora Online

This cluster already runs Nextcloud (`clusters/main/kubernetes/apps/nextcloud`). To add browser-based office editing on the LAN, run a Collabora Online server in-cluster and point the Nextcloud Office app at it.

Alternative: install the Nextcloud app **Collabora Online - Built-in CODE Server** (`richdocumentscode`) instead of running a separate Collabora service. It’s simpler, but it’s harder to tune/scale independently and ties Office availability to the Nextcloud pod lifecycle.

## Architecture (recommended)

- Nextcloud is hosted at `https://cloud.${DOMAIN_0}` (Gateway API `HTTPRoute`).
- Collabora Online is hosted at `https://office.${DOMAIN_0}` (Gateway API `HTTPRoute`).
- Clients on the LAN access Nextcloud; when editing documents, their browser loads Collabora from `office.${DOMAIN_0}` inside the Nextcloud UI (iframe).

Key implication: `office.${DOMAIN_0}` must be reachable by the same clients that reach `nextcloud.${DOMAIN_0}` (LAN-only is fine; WAN users would also need WAN reachability).

## Deploy Collabora Online (in-cluster)

This repo can deploy Collabora Online at `office.${DOMAIN_0}` via:

- `clusters/main/kubernetes/repositories/helm/collabora-online.yaml` (HelmRepository)
- `clusters/main/kubernetes/apps/collabora` (Flux Kustomization + HelmRelease)

If you want `office.${DOMAIN_0}` LAN-only, keep DNS resolving to the internal Gateway API address.

## Enable Nextcloud Office and connect it to Collabora

1. Install/enable the Nextcloud app **Nextcloud Office** (`richdocuments`).
2. In Nextcloud: **Administration settings → Office**
   - Select **Use your own server**
   - Collabora server: `https://office.${DOMAIN_0}`

## Notes / common gotchas

- Collabora must allow the Nextcloud host for WOPI. The HelmRelease sets `aliasgroups` for `https://cloud.${DOMAIN_0}:443`.
- Collabora must allow embedding from Nextcloud. The HelmRelease sets `net.frame_ancestors=https://cloud.${DOMAIN_0}`.
- If you later change either route to external/public exposure, switch both (or at least ensure `office.${DOMAIN_0}` is reachable by the same clients).

## Troubleshooting

### "Slow Kit jail setup with copying, cannot bind-mount"

This warning means Collabora can’t use `mount(2)`/bind-mounts inside the container, so it falls back to copying the system template into each “jail”. Editing still works, but startup/opening documents is slower.

This repo sets a less-restrictive container security context for Collabora to allow bind-mounting (see `securityContext` in `clusters/main/kubernetes/apps/collabora/app/helm-release.yaml`).
