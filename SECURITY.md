# Security policy

This repository is a **template**. It is meant to be copied and adapted, and it
is published with **placeholder secrets only**. Read this before you commit
anything to your own copy.

## Secret handling

- Every shipped `*.secret.yaml`, `clusterenv.yaml`, and credential file contains
  `REPLACE_WITH_*` / `${VARIABLE}` placeholders — never real values.
- All real secrets must be encrypted with SOPS/age before they are committed.
  See [`docs/secrets.md`](docs/secrets.md) and run `./scripts/sops-files.sh check`.
- `.gitignore` excludes key material (`age.agekey`, deploy keys, generated Talos
  configs, kubeconfigs, talosconfigs). Keep it that way.
- The `sops-age` private key is applied to the cluster out-of-band and is never
  committed (see `flux-system/flux/sopssecret.secret.yaml`).
- `./scripts/check-repo.sh` flags plaintext secret files that do not look like
  placeholders; it runs in CI and should be run locally before every commit.

## If you accidentally commit a real secret

A secret committed in plaintext must be treated as compromised, even if you
delete it in a later commit — it remains in Git history (and on any remote/fork
or CI cache it reached).

1. **Rotate the credential immediately** at its source (API token, password,
   key, etc.). Rotation is the real fix; history rewriting is cleanup.
2. Remove it from history (e.g. `git filter-repo`) and force-push, then have
   collaborators re-clone.
3. Re-add the value only as a SOPS-encrypted secret.

## Reporting an issue in this template

If you find a security problem in the template itself (e.g. a manifest that
leaks data, an unsafe default, or a placeholder that looks like a real secret),
please open an issue or contact the maintainer privately via GitHub rather than
posting exploit details publicly.

This template depends on external charts, tools, and images that carry their own
security policies and support boundaries — see
[`docs/template-publishing.md`](docs/template-publishing.md).
