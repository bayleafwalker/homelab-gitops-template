# Forgejo onboarding

The template can expose Forgejo internally at `https://git.${DOMAIN_0}` via
Gateway API after you keep and deploy the bundled Forgejo manifests.

SSH is exposed separately at `forgejo-ssh.${DOMAIN_0}:2222` through the
chart-managed `LoadBalancer` service when that service is enabled.

## Initial bootstrap

1. Wait for Flux to report the service healthy.
   - `direnv exec . flux get ks -n flux-system forgejo`
   - `direnv exec . flux get hr -n forgejo forgejo`
   - `direnv exec . kubectl -n forgejo get cluster.postgresql.cnpg.io forgejo-db`
2. Open `https://git.${DOMAIN_0}`.
3. Sign in with the bootstrap user `forgejo-admin`.
4. Change the admin password on first login.
5. Create your normal user account and an empty repository named `knowledge-base` there, or create an organization first and create the repository there.

Example: `your-username/knowledge-base`.

## Publish `knowledge-base`

Create a personal access token in Forgejo after first login, then from `/projects/dev/knowledge-base`:

```bash
git remote add forgejo https://your-username@git.${DOMAIN_0}/your-username/knowledge-base.git
git push --mirror forgejo
```

Git will prompt for the personal access token as the password.

If the repository should live under an organization, replace `your-username` in the remote URL with the organization name.

## SSH clone and push

Once your user account has an SSH key in Forgejo, you can use SSH instead of HTTPS:

```bash
ssh -T -p 2222 git@forgejo-ssh.${DOMAIN_0}
git remote add forgejo-ssh ssh://git@forgejo-ssh.${DOMAIN_0}:2222/your-username/knowledge-base.git
git push --mirror forgejo-ssh
```

In the Forgejo web UI: **Profile picture → Settings → SSH / GPG Keys** and add your public key before testing the SSH remote.

## Authentik OIDC

Forgejo has native OpenID Connect support. Use that instead of Gateway forward-auth.

### 1) Create an Authentik provider and application

In Authentik:

1. Go to **Applications → Providers → Create**.
2. Choose **OAuth2/OpenID Provider**.
3. Set:
   - **Name**: `Forgejo`
   - **Authorization flow**: your normal browser flow
   - **Client type**: `Confidential`
   - **Redirect URIs**: `https://git.${DOMAIN_0}/user/oauth2/Authentik/callback`
4. Save and note the **Client ID** and **Client Secret**.
5. Go to **Applications → Applications → Create**.
6. Create an application named `Forgejo` and attach the provider.

Optional: bind the application to a group such as `homelab-admin` or a dedicated Forgejo users group.

### 2) Add Authentik as a login source in Forgejo

In Forgejo as an admin:

1. Open **Site Administration → Authentication Sources**.
2. Add a new source of type **OpenID Connect**.
3. Set:
   - **Name**: `Authentik`
   - **Discovery URL**: `https://auth.${DOMAIN_0}/application/o/forgejo/.well-known/openid-configuration`
   - **Client ID**: from Authentik
   - **Client Secret**: from Authentik
   - **Scopes**: `openid profile email`
4. Save, then test login from a private browser window.

### 3) Account policy choices

- Leave the bootstrap `forgejo-admin` local account in place for break-glass admin access.
- Disable open self-registration unless you want Authentik users to auto-create accounts.
- If you want Authentik to gate access, bind the Forgejo Authentik application to a specific group instead of relying only on Forgejo org membership.

## Forgejo Actions runner

The template includes a dedicated Forgejo runner service under
`clusters/main/kubernetes/system/forgejo-runner/`.

Current design:

- The runner is separate from the Forgejo application namespace.
- Jobs run through Forgejo Runner with a privileged Docker-in-Docker sidecar.
- The runner namespace is labeled for privileged Pod Security admission because the DinD sidecar is intentionally privileged.
- The runner namespace is marked `runner.homelab.dev/trust=trusted`; keep untrusted or third-party workflows on a separate runner class if added later.
- The runner is registered as a global Forgejo runner and connects to Forgejo over the in-cluster HTTP service.
- Default labels are:
   - `ubuntu-22.04`
   - `ubuntu-latest`
- The runner container waits for the local Docker daemon to accept connections before starting, which avoids the sidecar startup race seen during initial rollout.

Use Forgejo Actions workflows from `.forgejo/workflows/*.yml` and target the runner with:

```yaml
jobs:
   smoke:
      runs-on: ubuntu-latest
      steps:
         - uses: actions/checkout@v4
         - run: echo hello from forgejo runner
```

Notes:

- Actions are configured to resolve relative `uses:` references against `https://data.forgejo.org`.
- The runner has no Kubernetes API permissions by default.
- Docker image cache lives in the runner namespace on a Longhorn-backed PVC. A `docker-pruner` sidecar removes images and builder cache older than 7 days every 6 hours.
- The Docker-in-Docker sidecar is a deliberate trust tradeoff: workflows can reach a privileged Docker daemon.
- Runner egress is restricted to DNS, Forgejo in-cluster HTTP (`3000`), HTTP/HTTPS, and Forgejo SSH (`2222`) by namespace NetworkPolicy. Expand this deliberately if a workflow needs non-web protocols.

### Smoke verification

After deployment, verify the runner with a small workflow such as
`.forgejo/workflows/runner-smoke.yaml`.

Example values to record for your own verification:

- Repository: `your-username/knowledge-base`
- Workflow file: `runner-smoke.yaml`
- Run id: `<run-id>`
- Event: `push`
- Head SHA: `<commit-sha>`
- Status: `success`
- Started: `<timestamp>`
- Finished: `<timestamp>`

## Notes

- The web hostname and SSH hostname are intentionally separate to avoid mixing Gateway HTTP traffic with raw SSH traffic on the same DNS record.
- The SSH hostname is pinned to `forgejo-ssh.${DOMAIN_0}` and resolves through `${FORGEJO_SSH_IP}`.
- The Forgejo admin password is stored in the encrypted manifest at `clusters/main/kubernetes/apps/forgejo/app/forgejo-admin.secret.yaml`.
