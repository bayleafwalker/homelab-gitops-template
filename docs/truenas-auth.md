# TrueNAS auth integration options

TrueNAS isn’t managed by Flux in this repo, but you can still standardize access around Authentik.

## Option A: LDAP (directory services)

Best when you want TrueNAS users/groups to come from an IdP.

1) Ensure the Authentik LDAP outpost is enabled (it is in `clusters/main/kubernetes/apps/authentik/app/helm-release.yaml`).
2) Expose the LDAP outpost to TrueNAS (e.g. a dedicated internal `LoadBalancer` service on `TCP/389` and/or `TCP/636`).
   - This repo publishes it via `clusters/main/kubernetes/apps/authentik-ldap-outpost/app/service-lb.yaml`.
3) In TrueNAS UI: Directory Services → LDAP:
   - Server: `<ldap-outpost-address>`
   - Base DN: `${DN}` (same base configured for the outpost)
   - Bind DN/password: create a dedicated LDAP bind user in Authentik, store credentials in your password manager
4) Test login and group resolution before enabling “authoritative” mode.

## Option B: SSO in front of the UI (reverse proxy)

Best when you want SSO to the web UI but don’t want TrueNAS to consume directory users.

1) Publish TrueNAS behind your reverse proxy/Gateway API path with a dedicated hostname (example: `truenas-sso.${DOMAIN_0}`) that proxies to `https://truenas.${DOMAIN_0}`.
2) Protect that hostname with Authentik forward-auth (proxy provider).
3) Keep the native TrueNAS UI host (`truenas.${DOMAIN_0}`) limited to LAN only (firewall/IP allowlist) as a break-glass path.

## API automation (future)

If you want TrueNAS config to live “near GitOps” without fully GitOps-managing TrueNAS:
1) Create a TrueNAS API key (TrueNAS API docs: `https://truenas.${DOMAIN_0}/api/docs/current/`).
2) Store the key in your password manager.
3) Use a small set of scripts or Ansible tasks (not committed with plaintext secrets) to apply repeatable changes (users, shares, certificates, etc.).
