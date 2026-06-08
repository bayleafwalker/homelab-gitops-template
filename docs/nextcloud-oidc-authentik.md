# Nextcloud OIDC with Authentik

Nextcloud doesn’t have built-in OIDC login. The typical approach is:

1. Install the Nextcloud app **OpenID Connect Login** (`oidc_login`)
2. Create an Authentik **OAuth2/OpenID Provider** for Nextcloud
3. Configure the app in Nextcloud (via `occ` or admin settings)

## Prerequisites

- Nextcloud is deployed and reachable at `https://cloud.${DOMAIN_0}`
- Authentik is deployed and reachable at `https://auth.${DOMAIN_0}`

## 1) Install the Nextcloud OIDC login app

In Nextcloud (as an admin): **Apps →** search for **OpenID Connect Login** → install/enable.

If you prefer CLI (Kubernetes):

1. Find the pod/deployment name:
   - `direnv exec . kubectl -n nextcloud get deploy,pod`
2. Install + enable (adjust `deploy/nextcloud` + container name if yours differs):
   - `direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ app:install oidc_login`
   - `direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ app:enable oidc_login`

## 2) Create the Authentik OIDC provider + application

In Authentik:

1. **Applications → Providers → Create**
2. Choose **OAuth2/OpenID Provider**
3. Recommended settings:
   - **Client type**: `Confidential`
   - **Redirect URIs**:
     - `https://cloud.${DOMAIN_0}/apps/oidc_login/oidc`
     - `https://cloud.${DOMAIN_0}/index.php/apps/oidc_login/oidc`
4. Save and note **Client ID** + **Client Secret**
5. **Applications → Applications → Create**
   - Create an application named `Nextcloud`
   - Attach the provider you created

Optional (access control): bind the Nextcloud application to a group (e.g. `homelab-media` or `homelab-admin`) in Authentik.

## 3) Configure Nextcloud to use Authentik

The OIDC login app reads Nextcloud “system config” keys. You can set them via `occ`.

### Discovery endpoint not reachable (common pitfall)

If Nextcloud says the discovery endpoint is not reachable, check what `auth.${DOMAIN_0}` resolves to **from inside the Nextcloud pod**. If it resolves to a private/local IP (common with internal Gateway/LB IPs), Nextcloud may block the request due to SSRF protections unless `allow_local_remote_servers` is enabled.

The bundled Nextcloud HelmRelease supports enabling it via Helm
(`nextcloud.general.force_enable_allow_local_remote_servers: true` in
`clusters/main/kubernetes/apps/nextcloud/app/helm-release.yaml`).

Set these values (replace `<authentik-provider-slug>`, `<client-id>`, `<client-secret>`):

- `oidc_login_provider_url`: `https://auth.${DOMAIN_0}/application/o/<authentik-provider-slug>/`
- `oidc_login_client_id`: `<client-id>`
- `oidc_login_client_secret`: `<client-secret>`
- `oidc_login_scope`: `openid profile email`
- `oidc_login_disable_registration`: `false` (optional; allow auto user creation)

Example (Kubernetes):

```bash
direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ config:system:set oidc_login_provider_url --value="https://auth.${DOMAIN_0}/application/o/<authentik-provider-slug>/"
direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ config:system:set oidc_login_client_id --value="<client-id>"
direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ config:system:set oidc_login_client_secret --value="<client-secret>"
direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ config:system:set oidc_login_scope --value="openid profile email"
direnv exec . kubectl -n nextcloud exec deploy/nextcloud -c main -- occ config:system:set oidc_login_disable_registration --type=boolean --value=false
```

## Verification

- Open `https://cloud.${DOMAIN_0}/login` and confirm the OIDC login option appears.
- Login completes and a Nextcloud user is created/linked as expected.
