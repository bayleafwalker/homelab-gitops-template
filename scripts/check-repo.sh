#!/usr/bin/env bash
# Local consistency checks that complement kustomize build. Safe to run before
# bootstrap; it does not contact a cluster.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

failures=0
warnings=0

ok() { printf '%s✓%s %s\n' "${GREEN}" "${NC}" "$1"; }
warn() { printf '%s!%s %s\n' "${YELLOW}" "${NC}" "$1"; warnings=$((warnings + 1)); }
fail() { printf '%s✗%s %s\n' "${RED}" "${NC}" "$1"; failures=$((failures + 1)); }

check_kustomize() {
  if command -v kustomize >/dev/null 2>&1; then
    if kustomize build clusters/main/kubernetes >/tmp/check-repo-kustomize.out 2>/tmp/check-repo-kustomize.err; then
      ok "kustomize build clusters/main/kubernetes"
    else
      fail "kustomize build failed; see /tmp/check-repo-kustomize.err"
    fi
  else
    warn "kustomize not found on PATH"
  fi
}

check_substitution_vars() {
  mapfile -t used < <(
    perl -ne 'while (/(?<!\$)\$\{([A-Z0-9_]+)\}/g) { print "$1\n" }' \
      $(rg --files clusters/main/kubernetes clusters/main/talos) | sort -u
  )
  mapfile -t defined < <(
    rg -n '^[[:space:]]*[A-Z0-9_]+:' \
      clusters/main/kubernetes/flux-system/flux/clustersettings.secret.yaml \
      clusters/main/kubernetes/flux-system/flux/cluster-secrets.secret.yaml \
      clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml \
      clusters/main/clusterenv.yaml |
      sed -E 's/^[^:]+:[0-9]+:[[:space:]]*([A-Z0-9_]+):.*/\1/' | sort -u
  )

  missing="$(comm -23 <(printf '%s\n' "${used[@]}") <(printf '%s\n' "${defined[@]}") || true)"
  if [[ -n "${missing}" ]]; then
    fail "undefined Flux/Talos substitution variables:"
    printf '%s\n' "${missing}" | sed 's/^/    /'
  else
    ok "all literal \${VAR} references have defaults in substitution sources"
  fi
}

check_secret_placeholders() {
  mapfile -t secret_files < <(
    {
      [[ -f clusters/main/clusterenv.yaml ]] && printf '%s\n' clusters/main/clusterenv.yaml
      find clusters/main/kubernetes -name '*.secret.yaml' -type f ! -name 'sopssecret.secret.yaml'
    } | sort -u
  )

  unencrypted=()
  for file in "${secret_files[@]}"; do
    if ! rg -q '^sops:|ENC\[' "${file}"; then
      unencrypted+=("${file}")
    fi
  done

  if [[ "${#unencrypted[@]}" -gt 0 ]]; then
    warn "${#unencrypted[@]} secret/template file(s) are not SOPS-encrypted yet"
    printf '%s\n' "${unencrypted[@]}" | sed 's/^/    /'
  else
    ok "secret target files look SOPS-encrypted"
  fi
}

check_chart_versions() {
  if rg -n 'version:[[:space:]]*("[*]"|[*]|latest|main|master|[<>=~^])' clusters/main/kubernetes -g 'helm-release*.yaml' >/tmp/check-repo-chart-versions.out; then
    fail "found unpinned-looking Helm chart versions:"
    sed 's/^/    /' /tmp/check-repo-chart-versions.out
  else
    ok "no wildcard/range Helm chart versions found"
  fi
}

check_service_inventory() {
  ks_count="$(find clusters/main/kubernetes -name ks.yaml | wc -l | tr -d ' ')"
  hr_count="$(find clusters/main/kubernetes -path '*/app/helm-release*.yaml' | wc -l | tr -d ' ')"
  ok "service inventory: ${ks_count} Flux Kustomizations, ${hr_count} HelmRelease files"
}

check_kustomize
check_substitution_vars
check_secret_placeholders
check_chart_versions
check_service_inventory

if [[ "${failures}" -gt 0 ]]; then
  echo
  fail "Repository checks found ${failures} blocking issue(s)"
  exit 1
fi

if [[ "${warnings}" -gt 0 ]]; then
  echo
  warn "Repository checks passed with ${warnings} warning(s)"
else
  echo
  ok "Repository checks passed"
fi
