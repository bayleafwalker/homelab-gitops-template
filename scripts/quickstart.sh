#!/usr/bin/env bash
# Guided readiness check for bootstrapping a 1-2 node Talos/Kubernetes cluster
# from this template. Safe to re-run — it never touches a live cluster; it only
# inspects local files and reports what still needs your attention.
#
# Usage: ./scripts/quickstart.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

ok()   { printf '  %s✓%s %s\n' "${GREEN}" "${NC}" "$1"; }
warn() { printf '  %s!%s %s\n' "${YELLOW}" "${NC}" "$1"; }
fail() { printf '  %s✗%s %s\n' "${RED}" "${NC}" "$1"; }
step() { printf '\n%s== %s ==%s\n' "${CYAN}" "$1" "${NC}"; }

problems=0

step "1. Pinned tooling (mise)"
if command -v mise >/dev/null 2>&1; then
  ok "mise is installed ($(mise --version))"
  if mise install >/dev/null 2>&1; then
    ok "tool versions from mise.toml are installed"
  else
    fail "mise install failed — run it manually and inspect the error"
    problems=$((problems + 1))
  fi
else
  fail "mise is not installed — see https://mise.jdx.dev/ to install it, then run 'mise install'"
  problems=$((problems + 1))
fi

step "2. direnv environment"
if [[ -f .envrc ]]; then
  ok ".envrc exists"
else
  warn ".envrc not found — copy .envrc.example to .envrc, rename the placeholder"
  warn "  cluster identifiers (homelab -> your cluster name), then run 'direnv allow'"
fi

step "3. Age key for SOPS"
if [[ -f age.agekey ]]; then
  ok "age.agekey present (kept out of git via .gitignore)"
else
  warn "age.agekey not found — generate one and update .sops.yaml + the sops-age secret:"
  warn "  age-keygen -o age.agekey"
  warn "  Put the PUBLIC key in .sops.yaml (replacing the REPLACE_WITH_* placeholder)"
  warn "  Put the PRIVATE key in clusters/main/kubernetes/flux-system/flux/sopssecret.secret.yaml"
fi

step "4. Placeholder values still to replace"
placeholder_patterns=(
  'REPLACE_WITH_'
  '192\.168\.1\.'
  'example\.com'
  'your-username'
  'your-homelab-repo'
  '00:11:22:33:44:5'
  'age1REPLACE_WITH_YOUR_OWN_AGE_PUBLIC_KEY'
)
hits=0
for pattern in "${placeholder_patterns[@]}"; do
  matches=$(grep -rIl --exclude-dir=.git --exclude-dir=docs --exclude='quickstart.sh' -E "${pattern}" . 2>/dev/null | sort -u || true)
  if [[ -n "${matches}" ]]; then
    count=$(echo "${matches}" | wc -l)
    warn "pattern '${pattern}' still found in ${count} file(s):"
    echo "${matches}" | sed 's/^/      /'
    hits=$((hits + count))
  fi
done
if [[ ${hits} -eq 0 ]]; then
  ok "no known placeholder patterns remain — looks customized"
else
  warn "replace the placeholders above with your own values before bootstrapping"
  warn "(IPs/CIDRs, domain, repo URL, MAC addresses, age public key, secret values)"
fi

step "5. clusterenv.yaml / talconfig.yaml node count"
node_count=$(grep -c '^\s*-\s*hostname:' clusters/main/talos/talconfig.yaml || true)
ok "talconfig.yaml currently defines ${node_count} node(s)"
if [[ "${node_count}" -gt 2 ]]; then
  warn "for a 1-2 node cluster, trim clusters/main/talos/talconfig.yaml down to:"
  warn "  - 1 node:  a single controlPlane node with allowSchedulingOnControlPlanes: true"
  warn "  - 2 nodes: one controlPlane + one worker (or two controlPlane nodes with"
  warn "             allowSchedulingOnControlPlanes: true and no dedicated workers)"
  warn "Remove the matching \${VARIABLE} entries for any nodes you delete from"
  warn "clusters/main/clusterenv.yaml, and drop unused per-node patches under"
  warn "clusters/main/talos/patches/."
fi

step "6. Kustomize build"
if command -v kustomize >/dev/null 2>&1; then
  if kustomize build clusters/main/kubernetes >/dev/null 2>/tmp/quickstart-kustomize-err.log; then
    ok "kustomize build clusters/main/kubernetes succeeds"
  else
    fail "kustomize build failed — see /tmp/quickstart-kustomize-err.log"
    problems=$((problems + 1))
  fi
else
  warn "kustomize not on PATH — run 'mise install' / 'direnv allow' first"
fi

step "Summary"
if [[ ${problems} -eq 0 && ${hits} -eq 0 ]]; then
  ok "Looks ready. Next steps (see docs/operations.md for the full runbook):"
  echo "    1. Generate Talos machine configs:  talhelper genconfig (or 'clustertool talos genconfig')"
  echo "    2. Apply machine configs to your node(s) and bootstrap Talos/etcd"
  echo "    3. Apply the out-of-band sops-age secret, deploy key, and cluster-config/cluster-secrets"
  echo "    4. Bootstrap Flux:  flux bootstrap git --url=ssh://git@github.com/<you>/<repo>.git ..."
  echo "    5. Reconcile:       flux reconcile source git cluster && flux reconcile kustomization flux-entry"
elif [[ ${problems} -gt 0 ]]; then
  fail "Found ${problems} blocking issue(s) above — resolve them before continuing."
  exit 1
else
  warn "Found ${hits} placeholder reference(s) left to customize — re-run this script after editing."
fi
