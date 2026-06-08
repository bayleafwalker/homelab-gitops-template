#!/usr/bin/env bash
# Common SOPS file operations for this template.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

usage() {
  cat <<'EOF'
Usage: ./scripts/sops-files.sh <command> [file...]

Commands:
  list       Print files that should be encrypted before real values are committed.
  check      Fail if any target file is not SOPS-encrypted.
  encrypt    Encrypt target files in place with sops -e -i.
  decrypt    Decrypt target files to .decrypted~<name> beside each source file.

If no files are passed, the default target set is:
  clusters/main/clusterenv.yaml
  clusters/main/kubernetes/**/*.secret.yaml

The default set excludes flux-system/flux/sopssecret.secret.yaml because it is
a documentation-only example for the out-of-band sops-age bootstrap Secret.
EOF
}

default_files() {
  {
    [[ -f clusters/main/clusterenv.yaml ]] && printf '%s\n' clusters/main/clusterenv.yaml
    find clusters/main/kubernetes -name '*.secret.yaml' -type f ! -name 'sopssecret.secret.yaml'
  } | sort -u
}

command="${1:-}"
if [[ -z "${command}" || "${command}" == "-h" || "${command}" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

if [[ "$#" -gt 0 ]]; then
  mapfile -t files < <(printf '%s\n' "$@")
else
  mapfile -t files < <(default_files)
fi

case "${command}" in
  list)
    printf '%s\n' "${files[@]}"
    ;;
  check)
    missing=0
    for file in "${files[@]}"; do
      if [[ ! -f "${file}" ]]; then
        echo "missing: ${file}" >&2
        missing=$((missing + 1))
      elif ! rg -q '^sops:|ENC\[' "${file}"; then
        echo "not encrypted: ${file}" >&2
        missing=$((missing + 1))
      fi
    done
    if [[ "${missing}" -gt 0 ]]; then
      echo "${missing} file(s) need attention" >&2
      exit 1
    fi
    echo "All target files look SOPS-encrypted"
    ;;
  encrypt)
    if ! command -v sops >/dev/null 2>&1; then
      echo "sops is not installed. Run 'mise install' first." >&2
      exit 1
    fi
    for file in "${files[@]}"; do
      if rg -q '^sops:|ENC\[' "${file}"; then
        echo "already encrypted: ${file}"
      else
        echo "encrypting: ${file}"
        sops -e -i "${file}"
      fi
    done
    ;;
  decrypt)
    if ! command -v sops >/dev/null 2>&1; then
      echo "sops is not installed. Run 'mise install' first." >&2
      exit 1
    fi
    for file in "${files[@]}"; do
      out="$(dirname "${file}")/.decrypted~$(basename "${file}")"
      echo "decrypting: ${file} -> ${out}"
      sops -d "${file}" >"${out}"
      chmod 600 "${out}"
    done
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
