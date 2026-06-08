#!/usr/bin/env bash
# Generate the local age key used by SOPS and update .sops.yaml with its public
# recipient. This script does not create the in-cluster sops-age Secret; that is
# an out-of-band bootstrap step documented in docs/bootstrapping.md.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

key_file="${1:-age.agekey}"

if ! command -v age-keygen >/dev/null 2>&1; then
  echo "age-keygen is not installed. Run 'mise install' first." >&2
  exit 1
fi

if [[ ! -f "${key_file}" ]]; then
  age-keygen -o "${key_file}"
  chmod 600 "${key_file}"
  echo "Created ${key_file}"
else
  echo "${key_file} already exists; leaving it unchanged"
fi

public_key="$(sed -n 's/^# public key: //p' "${key_file}" | head -1)"
if [[ -z "${public_key}" ]]; then
  echo "Could not find a public key comment in ${key_file}" >&2
  exit 1
fi

if [[ ! -f .sops.yaml ]]; then
  echo ".sops.yaml not found" >&2
  exit 1
fi

if rg -q 'age1REPLACE_WITH_YOUR_OWN_AGE_PUBLIC_KEY' .sops.yaml; then
  perl -0pi -e "s/age1REPLACE_WITH_YOUR_OWN_AGE_PUBLIC_KEY_FROM_age-keygen/${public_key}/g" .sops.yaml
  echo "Updated .sops.yaml with ${public_key}"
elif rg -Fq "${public_key}" .sops.yaml; then
  echo ".sops.yaml already uses ${public_key}"
else
  echo ".sops.yaml already has a non-placeholder recipient; review it before replacing keys." >&2
  exit 1
fi

cat <<EOF

Next steps:
  1. Replace placeholder secret values.
  2. Encrypt secret files:
       ./scripts/sops-files.sh encrypt
  3. During cluster bootstrap, create sops-age out-of-band:
       kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
       kubectl create secret generic sops-age -n flux-system --from-file=age.agekey=./${key_file}
EOF
