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
  unsafe_plaintext=()
  for file in "${secret_files[@]}"; do
    if ! rg -q '^sops:|ENC\[' "${file}"; then
      unencrypted+=("${file}")
      if ! rg -q 'REPLACE_WITH|example\.com|your-|00:11:22:33|Sample only|placeholder|sample' "${file}"; then
        unsafe_plaintext+=("${file}")
      fi
    fi
  done

  if [[ "${#unsafe_plaintext[@]}" -gt 0 ]]; then
    fail "${#unsafe_plaintext[@]} plaintext secret file(s) do not look like placeholder templates"
    printf '%s\n' "${unsafe_plaintext[@]}" | sed 's/^/    /'
  fi

  if [[ "${#unencrypted[@]}" -gt 0 ]]; then
    warn "${#unencrypted[@]} secret/template file(s) are not SOPS-encrypted yet"
    printf '%s\n' "${unencrypted[@]}" | sed 's/^/    /'
  else
    ok "secret target files look SOPS-encrypted"
  fi
}

check_generated_sensitive_files() {
  local paths=(
    age.agekey
    deploy-key
    deploy-key.pub
    talsecret.yaml
    clusters/main/talos/talsecret.yaml
    clusters/main/talos/talconfig.json
  )
  local dirs=(
    clusterconfig
    clusters/main/talos/generated
    clusters/main/talos/clusterconfig
    clusters/.kube
    clusters/.talos
    clusters/.ssh
  )
  local tracked=()
  local path

  for path in "${paths[@]}"; do
    if [[ -e "${path}" ]] && git ls-files --error-unmatch "${path}" >/dev/null 2>&1; then
      tracked+=("${path}")
    fi
  done

  local dir
  for dir in "${dirs[@]}"; do
    if [[ -e "${dir}" ]]; then
      while IFS= read -r path; do
        [[ -n "${path}" ]] && tracked+=("${path}")
      done < <(git ls-files "${dir}" 2>/dev/null)
    fi
  done

  if [[ "${#tracked[@]}" -gt 0 ]]; then
    fail "generated or sensitive local files are tracked:"
    printf '%s\n' "${tracked[@]}" | sort -u | sed 's/^/    /'
  else
    ok "no generated Talos/key material is tracked in the working tree"
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

check_version_alignment() {
  local talconfig_talos upgrade_talos talconfig_k8s upgrade_k8s

  talconfig_talos="$(sed -nE 's/^talosVersion:[[:space:]]*(v[^[:space:]]+).*/\1/p' clusters/main/talos/talconfig.yaml | head -1)"
  upgrade_talos="$(sed -nE 's/^[[:space:]]*TALOS_VERSION:[[:space:]]*(v[^[:space:]]+).*/\1/p' clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml | head -1)"
  talconfig_k8s="$(sed -nE 's/^kubernetesVersion:[[:space:]]*(v[^[:space:]]+).*/\1/p' clusters/main/talos/talconfig.yaml | head -1)"
  upgrade_k8s="$(sed -nE 's/^[[:space:]]*KUBERNETES_VERSION:[[:space:]]*(v[^[:space:]]+).*/\1/p' clusters/main/kubernetes/flux-system/flux/upgradesettings.yaml | head -1)"

  if [[ -z "${talconfig_talos}" || -z "${upgrade_talos}" || "${talconfig_talos}" != "${upgrade_talos}" ]]; then
    fail "Talos version mismatch: talconfig=${talconfig_talos:-missing}, upgrade-settings=${upgrade_talos:-missing}"
  elif [[ -z "${talconfig_k8s}" || -z "${upgrade_k8s}" || "${talconfig_k8s}" != "${upgrade_k8s}" ]]; then
    fail "Kubernetes version mismatch: talconfig=${talconfig_k8s:-missing}, upgrade-settings=${upgrade_k8s:-missing}"
  else
    ok "Talos/Kubernetes versions are aligned"
  fi
}

check_doc_paths() {
  local refs=()
  local ref file path clean

  while IFS=: read -r file ref; do
    [[ -z "${ref}" ]] && continue
    [[ "${ref}" == *'<'* || "${ref}" == *'>'* || "${ref}" == *'*'* ]] && continue
    [[ "${ref}" == http* || "${ref}" == *' '* ]] && continue
    [[ "${ref}" == ".envrc" || "${ref}" == ".envrc.example" ]] && continue
    [[ "${ref}" == *'/foo/'* ]] && continue
    [[ "${ref}" == clusters/.kube/* || "${ref}" == clusters/.talos/* || "${ref}" == clusters/.ssh/* ]] && continue
    [[ "${ref}" == clusters/main/talos/generated/* || "${ref}" == "clusters/main/talos/generated/" ]] && continue
    case "${ref}" in
      clusters/*|docs/*|scripts/*|repositories/*|README.md|AGENTS.md|CLAUDE.md|LICENSE|.sops.yaml|.sopsrc)
        clean="${ref%%:*}"
        refs+=("${file}:${clean}")
        ;;
    esac
  done < <(perl -ne 'while (/`([^`]+)`/g) { print "$ARGV:$1\n" }' README.md docs/*.md AGENTS.md CLAUDE.md 2>/dev/null)

  local missing=()
  for ref in "${refs[@]}"; do
    file="${ref%%:*}"
    path="${ref#*:}"
    if [[ "${path}" == */ ]]; then
      [[ -d "${path%/}" ]] || missing+=("${file}: ${path}")
    else
      [[ -e "${path}" ]] || missing+=("${file}: ${path}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    warn "documentation references missing local paths:"
    printf '%s\n' "${missing[@]}" | sort -u | sed 's/^/    /'
  else
    ok "backticked documentation paths resolve"
  fi
}

check_default_enabled_services() {
  local active=()
  local file path

  while IFS=: read -r file path; do
    case "${file}:${path}" in
      *apps/kustomization.yaml:*) active+=("${file}: ${path}") ;;
      *core/kustomization.yaml:blocky/ks.yaml|*core/kustomization.yaml:clusterissuer/ks.yaml|*core/kustomization.yaml:system-upgrade-controller-plans/ks.yaml) active+=("${file}: ${path}") ;;
      *kube-system/kustomization.yaml:cilium/ks.yaml|*kube-system/kustomization.yaml:coredns/ks.yaml|*kube-system/kustomization.yaml:kubelet-csr-approver/ks.yaml|*kube-system/kustomization.yaml:metrics-server/ks.yaml) ;;
      *kube-system/kustomization.yaml:descheduler/ks.yaml|*kube-system/kustomization.yaml:generic-device-plugin/ks.yaml|*kube-system/kustomization.yaml:gpu-operator/ks.yaml|*kube-system/kustomization.yaml:node-feature-discovery/ks.yaml|*kube-system/kustomization.yaml:nvidia-device-plugin/ks.yaml|*kube-system/kustomization.yaml:nvidia-runtimeclass.yaml) active+=("${file}: ${path}") ;;
      *network/kustomization.yaml:tailscale/ks.yaml|*network/kustomization.yaml:omada-controller/ks.yaml|*network/kustomization.yaml:mosquitto/ks.yaml) active+=("${file}: ${path}") ;;
      *system/kustomization.yaml:cert-manager/ks.yaml|*system/kustomization.yaml:gateway-api-crds/ks.yaml|*system/kustomization.yaml:metallb/ks.yaml) ;;
      *system/kustomization.yaml:*) active+=("${file}: ${path}") ;;
    esac
  done < <(rg -n '^[[:space:]]*-[[:space:]]*[^#].*ks\.yaml|^[[:space:]]*-[[:space:]]*nvidia-runtimeclass\.yaml' clusters/main/kubernetes/{apps,core,kube-system,network,system}/kustomization.yaml |
    sed -E 's/^([^:]+):[0-9]+:[[:space:]]*-[[:space:]]*([^[:space:]#]+).*/\1:\2/')

  if [[ "${#active[@]}" -gt 0 ]]; then
    warn "optional services are enabled in the default tree:"
    printf '%s\n' "${active[@]}" | sort -u | sed 's/^/    /'
  else
    ok "default tree only enables lean starter services"
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
check_generated_sensitive_files
check_chart_versions
check_version_alignment
check_doc_paths
check_default_enabled_services
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
