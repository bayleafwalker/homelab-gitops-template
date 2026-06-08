# CloudNativePG (CNPG) backups to S3

CNPG-backed databases should be backed up using CNPG-native backups (Barman object store) rather than PVC snapshotting.

## Configured clusters

- `authentik/authentik-cnpg-main`
- `vaultwarden/vaultwarden-cnpg-main`
- `vscode/actionq-cnpg-main` — agent-ops action queue and coordinator event log
- `vscode/sprintctl-cnpg-main` — agent-ops sprint/work-item state for all remote-mode repos

### Agent-ops databases

`actionq-cnpg-main` holds all actionq actions, lifecycle events, and coordinator emissions (session.*, coordinator_cycle). It is the source of truth for queue state and session history. Loss of this cluster without a backup means losing all dispatch history and in-flight action state.

`sprintctl-cnpg-main` holds sprint state for every repo operating in remote mode, keyed by `repo_id`. Loss without a backup means losing sprint, work-item, and takeup event history for all remote-mode repos. Per-repo local SQLite databases (on the workspace PVC) are a secondary source for local-mode repos only.

Both databases are backed up with 30-day retention and monthly restore drills. See the restore drill CronJobs in `clusters/main/kubernetes/apps/actionq-db/app/cnpg-restore-drill.yaml` and `clusters/main/kubernetes/apps/sprintctl-postgres/app/cnpg-restore-drill.yaml`.

Restore-drill CronJobs are monitored by `system/backup-observability`. A drill that has never succeeded or has not succeeded in more than 45 days raises a Prometheus alert.

## What is enabled

- Backup method: `barmanObjectStore` to Hetzner S3
- Encryption: disabled in CNPG (Hetzner S3 rejects the `AES256` SSE header used by `barman-cloud-wal-archive`)
- Retention policy: `30d`
- Scheduled backup: daily (staggered during the 02:00 hour)

TrueCharts apps configure this through common `cnpg.main.backups` values:
- `clusters/main/kubernetes/apps/authentik/app/helm-release.yaml`
- `clusters/main/kubernetes/apps/vaultwarden/app/helm-release.yaml`

Hand-written CNPG clusters configure `spec.backup.barmanObjectStore` and `ScheduledBackup` resources directly:
- `clusters/main/kubernetes/apps/actionq-db/app/actionq-cnpg.yaml`
- `clusters/main/kubernetes/apps/actionq-db/app/scheduled-backup.yaml`
- `clusters/main/kubernetes/apps/sprintctl-postgres/app/sprintctl-cnpg.yaml`
- `clusters/main/kubernetes/apps/sprintctl-postgres/app/scheduled-backup.yaml`

## Health checks

```bash
kubectl -n authentik get scheduledbackups.postgresql.cnpg.io,backups.postgresql.cnpg.io,clusters.postgresql.cnpg.io
kubectl -n vaultwarden get scheduledbackups.postgresql.cnpg.io,backups.postgresql.cnpg.io,clusters.postgresql.cnpg.io
kubectl -n vscode get scheduledbackups.postgresql.cnpg.io,backups.postgresql.cnpg.io,clusters.postgresql.cnpg.io
kubectl -n authentik describe scheduledbackups.postgresql.cnpg.io authentik-cnpg-main-sched-backup-daily
kubectl -n vaultwarden describe scheduledbackups.postgresql.cnpg.io vaultwarden-cnpg-main-sched-backup-daily
kubectl -n vscode describe scheduledbackups.postgresql.cnpg.io actionq-cnpg-main-daily
kubectl -n vscode describe scheduledbackups.postgresql.cnpg.io sprintctl-cnpg-main-daily
```

Note: `kubectl get backup …` is ambiguous in this cluster (Longhorn also has a `Backup` CRD). Always use `backups.postgresql.cnpg.io` for CNPG backups.

Prometheus freshness alerts are driven by `homelab_cnpg_cluster_backup_configured`, `homelab_cnpg_latest_completed_backup_timestamp`, and `homelab_restore_drill_last_success_timestamp` from `clusters/main/kubernetes/system/backup-observability/`.

## NetworkPolicy note

If a namespace is `default-deny`, CNPG requires ingress from the `cloudnative-pg` namespace to instance-manager (`TCP/8000`) for status checks and backup orchestration.

## Restore drill (automated)

This repo includes a monthly restore drill CronJob per CNPG-backed app:

- `clusters/main/kubernetes/apps/authentik/app/cnpg-restore-drill.yaml`
- `clusters/main/kubernetes/apps/vaultwarden/app/cnpg-restore-drill.yaml`
- `clusters/main/kubernetes/apps/actionq-db/app/cnpg-restore-drill.yaml`
- `clusters/main/kubernetes/apps/sprintctl-postgres/app/cnpg-restore-drill.yaml`

Each job:
1) Selects the newest `completed` CNPG `Backup` for the target cluster.
2) Creates a temporary 1-instance restore Cluster from that Backup.
3) Waits for `Ready`.
4) Deletes the restore Cluster (PVCs are owned by the Cluster and are deleted too).

Manual run:

```bash
kubectl -n authentik create job --from=cronjob/cnpg-restore-drill cnpg-restore-drill-manual
kubectl -n vaultwarden create job --from=cronjob/cnpg-restore-drill cnpg-restore-drill-manual
kubectl -n vscode create job --from=cronjob/actionq-cnpg-restore-drill actionq-cnpg-restore-drill-manual
kubectl -n vscode create job --from=cronjob/sprintctl-cnpg-restore-drill sprintctl-cnpg-restore-drill-manual
kubectl -n authentik logs -l job-name=cnpg-restore-drill-manual --all-containers --tail=200
kubectl -n vaultwarden logs -l job-name=cnpg-restore-drill-manual --all-containers --tail=200
kubectl -n vscode logs -l job-name=actionq-cnpg-restore-drill-manual --all-containers --tail=200
kubectl -n vscode logs -l job-name=sprintctl-cnpg-restore-drill-manual --all-containers --tail=200
```

## Restore runbook (manual)

CNPG supports restore/PITR from the object store. Typical workflow:
1) Identify the desired `Backup` (or PITR target).
2) Create a new CNPG `Cluster` using `spec.bootstrap.recovery.backup.name`.
3) Validate the restored DB (connect and run a sanity query).
4) Cut over apps to the restored DB (or replace the original during downtime).

The drill CronJobs are the “quick confidence check” that the latest object-store backup can be restored.

## S3 encryption note (Hetzner)

CNPG’s Barman integration can add S3 SSE headers (e.g. `AES256`) for encryption-at-rest. Hetzner’s S3 endpoint returns `InvalidArgument` for these headers in this cluster, which breaks WAL archiving and backups.

Recommended approach:
- For Hetzner Object Storage, prefer *SSE-C* (customer-provided keys) where supported by the client tooling: https://docs.hetzner.com/storage/object-storage/howto-protect-objects/encrypt-with-sse-c/
- Keep CNPG encryption disabled (Barman uses SSE-S3 style headers, not SSE-C), and enable encryption either:
  - In the storage layer/client (e.g. VolSync/restic already encrypts before upload), or
  - By switching CNPG backups to an S3-compatible provider that supports the SSE headers CNPG/Barman uses.
