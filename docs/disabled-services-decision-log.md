# Disabled service decision log

Starter template for tracking the lifecycle of services that ship in this repo
but are intentionally left disabled (commented out in the category
`kustomization.yaml` files). See `docs/operations.md` → "Disabled service drift
governance" for the review cadence.

Keeping a log here makes "disabled by choice" distinguishable from "broken and
forgotten". This file is optional — track decisions wherever fits your workflow
(issue tracker, dated runbook entries, etc.). Delete it if you track decisions
elsewhere.

| Service (`ks.yaml`) | Decision | Reason | Reviewer | Date | Revisit by |
|---|---|---|---|---|---|
| _example_ `apps/nextcloud/ks.yaml` | retain-disabled | No RWX storage provisioned yet | you | 2026-01-01 | 2026-04-01 |

Decisions:

- **retain-disabled** — keep in the tree, expect to enable later.
- **retire** — keep the manifests for reference but do not intend to deploy.
- **remove** — delete the service directory and its catalog entry.
