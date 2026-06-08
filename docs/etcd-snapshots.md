# Talos etcd snapshots (off-cluster)

The control plane’s etcd state is snapshotted daily and uploaded off-cluster to Hetzner Object Storage (S3-compatible).

## What runs

- `CronJob`: `etcd-backup/talos-etcd-snapshot`
- Upload path: `s3://${HETZNER_S3_BUCKET_NAME}/talos/etcd/${CLUSTERNAME}/`
- Retention: best-effort deletion of objects older than 30 days (via `rclone delete --min-age` in the CronJob).

## Manual snapshot

```bash
kubectl -n etcd-backup create job --from=cronjob/talos-etcd-snapshot talos-etcd-snapshot-manual-$(date +%Y%m%d)
kubectl -n etcd-backup get jobs,pods
kubectl -n etcd-backup logs job/talos-etcd-snapshot-manual-$(date +%Y%m%d)
```

## Optional: enable SSE-C for uploaded snapshots (Hetzner)

The `talos-etcd-snapshot` CronJob uses `rclone` for S3 uploads. To enable Hetzner SSE-C (customer-provided keys) for the uploaded objects, create a Secret named `hetzner-s3-sse-c` in the `etcd-backup` namespace with the environment variables rclone expects:

```bash
# 32-byte key, base64-encoded (store this in your password manager; losing it = losing access)
KEY_B64="$(openssl rand -base64 32)"

kubectl -n etcd-backup create secret generic hetzner-s3-sse-c \
  --from-literal=RCLONE_S3_SSE_CUSTOMER_ALGORITHM=AES256 \
  --from-literal=RCLONE_S3_SSE_CUSTOMER_KEY_BASE64="${KEY_B64}"
```

Reference: https://docs.hetzner.com/storage/object-storage/howto-protect-objects/encrypt-with-sse-c/

## Restore (control plane recovery)

This is disruptive and should be tested during a planned window.

High-level flow:
1) Download a snapshot from S3 to your workstation.
2) Pick a control-plane node to bootstrap recovery.
3) Run `talosctl bootstrap --recover-from=<snapshot>` against that node.
4) Verify control plane health and re-join remaining control plane members.

Example (workstation):
```bash
# Download snapshot locally (choose your preferred S3 client)
# Then recover etcd using Talos bootstrap recovery:
talosctl bootstrap --recover-from ./etcd-<timestamp>.snapshot --nodes ${VIP}
```

After recovery:
- Validate etcd and Kubernetes health (`talosctl etcd status`, `kubectl get nodes`, `flux get ks -A`).
- Reconcile Flux if needed: `flux reconcile source git cluster && flux reconcile kustomization flux-entry`.
