# Obsidian Notes Setup

The template includes an Obsidian + CouchDB/Self-hosted LiveSync pattern for
device sync. Use local Obsidian apps for the full editor. The old
`obsidian-remote` desktop container example is parked at zero replicas.

## Services

- CouchDB: `https://couchdb.${DOMAIN_0}`
- LiveSync database: stored in the `obsidian-livesync-credentials` Secret in the `couchdb` namespace after deployment
- Server vault path: `/vaults`, backed by the NFS `Creative` subdirectory if you keep that storage example

## Local Obsidian Apps

1. Install Obsidian locally.
2. Create or open a local vault.
3. Install the community plugin `Self-hosted LiveSync`.
4. Configure it with:
   - Remote database URI: `https://couchdb.${DOMAIN_0}`
   - Database name: value of `database` from `obsidian-livesync-credentials`
   - Username: value of `username` from `obsidian-livesync-credentials`
   - Password: value of `password` from `obsidian-livesync-credentials`
   - End-to-end encryption passphrase: value of `passphrase` from `obsidian-livesync-credentials`

Retrieve the values with:

```bash
for key in username password database passphrase; do
  printf "%s=" "$key"
  direnv exec . kubectl -n couchdb get secret obsidian-livesync-credentials \
    -o "jsonpath={.data.${key}}" | base64 -d
  printf "\n"
done
```

Do not enable official Obsidian Sync, iCloud sync, or another file sync tool on the same local vault while LiveSync is active.

## LiveSync Administration

The normal `livesync` user is a database admin and member for only the configured LiveSync database. This lets the plugin manage database-local LiveSync metadata while avoiding permanent CouchDB server-admin access on client devices.

For destructive maintenance flows that require deleting or recreating the whole database, temporarily promote the existing `livesync` user to CouchDB server admin, run the maintenance from one desktop Obsidian client, then demote it immediately afterward.

Before promotion:

- Close Obsidian or disable LiveSync on phones/tablets and any other clients.
- Keep only the desktop maintenance client open.
- Confirm recent backups exist before destructive rebuilds.

Promote `livesync` to server admin:

```bash
LS_PASS="$(direnv exec . kubectl -n couchdb get secret obsidian-livesync-credentials \
  -o jsonpath='{.data.password}' | base64 -d)"

direnv exec . kubectl -n couchdb exec couchdb-couchdb-0 -- sh -ec "
curl -fsS -X PUT -u \"\$COUCHDB_USER:\$COUCHDB_PASSWORD\" \
  http://127.0.0.1:5984/_node/_local/_config/admins/livesync \
  -H 'Content-Type: application/json' \
  --data-binary '\"$LS_PASS\"'
"
unset LS_PASS
```

Run the Self-hosted LiveSync repair/rebuild flow in desktop Obsidian using the normal `livesync` credentials.

Demote `livesync` from server admin:

```bash
direnv exec . kubectl -n couchdb exec couchdb-couchdb-0 -- sh -ec '
curl -fsS -X DELETE -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
  http://127.0.0.1:5984/_node/_local/_config/admins/livesync
'
```

After demotion, rerun the GitOps init Job so database-local security is restored:

```bash
direnv exec . kubectl -n couchdb delete job obsidian-livesync-init --ignore-not-found
direnv exec . flux reconcile kustomization couchdb -n flux-system
direnv exec . kubectl -n couchdb wait --for=condition=complete job/obsidian-livesync-init --timeout=180s
```

Verify that `livesync` is no longer a server admin and remains a database-local admin/member:

```bash
direnv exec . kubectl -n couchdb exec couchdb-couchdb-0 -- sh -ec '
curl -fsS -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
  http://127.0.0.1:5984/_node/_local/_config/admins/livesync || true
printf "\n"
curl -fsS -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
  http://127.0.0.1:5984/obsidianlivesync/_security
'
```

## Browser Editing

Do not deploy a browser-based filesystem editor against the same vault by default. A filesystem editor and LiveSync would create two write paths without a shared lock, which makes clobbered edits and silent conflicts too likely.

For browser-only access from a machine where Obsidian cannot be installed, prefer one of these explicit future designs:

- A partitioned quick-capture directory that is not treated as a full LiveSync peer.
- A reviewed headless LiveSync CLI bridge with stall detection, locking, and clear deletion semantics.

Until then, serious edits and quick capture should happen in local Obsidian clients connected through LiveSync.

Sources:

- Self-hosted LiveSync: https://github.com/vrtmrz/obsidian-livesync
