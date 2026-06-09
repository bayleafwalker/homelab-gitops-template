#!/usr/bin/env bash
# Apply common first-run placeholder replacements across the template. This is
# a convenience pass, not a complete cluster modeler; review the diff after use.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

usage() {
  cat <<'EOF'
Usage: ./scripts/configure-starter.sh [options]

Common options:
  --cluster-name NAME          Local cluster name for .envrc generation
  --domain DOMAIN             App domain, e.g. apps.example.net
  --base-domain DOMAIN        Base/local infra domain, e.g. example.net
  --email EMAIL               ACME/contact email
  --repo OWNER/REPO           GitHub-style repository path
  --repo-ssh URL              Full Flux SSH URL, e.g. ssh://git@github.com/OWNER/REPO.git
  --lan-cidr CIDR             LAN CIDR replacing 192.168.1.0/24
  --gateway-ip IP             LAN gateway replacing 192.168.1.1
  --api-vip IP                Kubernetes API VIP replacing 192.168.1.10
  --pod-cidr CIDR             Kubernetes pod CIDR replacing 172.16.0.0/16
  --service-cidr CIDR         Kubernetes service CIDR replacing 172.17.0.0/16
  --service-host-ip IP        kubernetes.default service IP replacing 172.17.0.1
  --lb-range START-END        LoadBalancer range replacing 192.168.1.200-192.168.1.220
  --gateway-lb-ip IP          Gateway API LoadBalancer IP
  --registry-ip IP            Registry LoadBalancer IP
  --registry-host HOST        Registry HTTP host
  --trusted-vpn-cidr CIDR     Optional trusted VPN CIDR replacing 10.0.0.0/24
  --truenas-ip IP             TrueNAS/NFS IP
  --directory-cidr CIDR       Optional Authentik directory backend CIDR
  --ntp-server HOST           Talos NTP server
  --upgrade-label KEY         System Upgrade Controller node label key
  --s3-bucket NAME            S3 backup bucket
  --s3-endpoint HOST          S3 endpoint hostname

After running, inspect git diff, then run:
  ./scripts/quickstart.sh
  ./scripts/check-repo.sh
EOF
}

cluster_name=""
domain=""
base_domain=""
email=""
repo_path=""
repo_ssh=""
lan_cidr=""
gateway_ip=""
api_vip=""
pod_cidr=""
service_cidr=""
service_host_ip=""
lb_range=""
gateway_lb_ip=""
registry_ip=""
registry_host=""
trusted_vpn_cidr=""
truenas_ip=""
directory_cidr=""
ntp_server=""
upgrade_label=""
s3_bucket=""
s3_endpoint=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --domain) domain="${2:?}"; shift 2 ;;
    --base-domain) base_domain="${2:?}"; shift 2 ;;
    --email) email="${2:?}"; shift 2 ;;
    --repo) repo_path="${2:?}"; shift 2 ;;
    --repo-ssh) repo_ssh="${2:?}"; shift 2 ;;
    --lan-cidr) lan_cidr="${2:?}"; shift 2 ;;
    --gateway-ip) gateway_ip="${2:?}"; shift 2 ;;
    --api-vip) api_vip="${2:?}"; shift 2 ;;
    --pod-cidr) pod_cidr="${2:?}"; shift 2 ;;
    --service-cidr) service_cidr="${2:?}"; shift 2 ;;
    --service-host-ip) service_host_ip="${2:?}"; shift 2 ;;
    --lb-range) lb_range="${2:?}"; shift 2 ;;
    --gateway-lb-ip) gateway_lb_ip="${2:?}"; shift 2 ;;
    --registry-ip) registry_ip="${2:?}"; shift 2 ;;
    --registry-host) registry_host="${2:?}"; shift 2 ;;
    --trusted-vpn-cidr) trusted_vpn_cidr="${2:?}"; shift 2 ;;
    --truenas-ip) truenas_ip="${2:?}"; shift 2 ;;
    --directory-cidr) directory_cidr="${2:?}"; shift 2 ;;
    --ntp-server) ntp_server="${2:?}"; shift 2 ;;
    --upgrade-label) upgrade_label="${2:?}"; shift 2 ;;
    --s3-bucket) s3_bucket="${2:?}"; shift 2 ;;
    --s3-endpoint) s3_endpoint="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$#" -eq 0 && -z "${cluster_name}${domain}${base_domain}${email}${repo_path}${repo_ssh}${lan_cidr}${gateway_ip}${api_vip}${pod_cidr}${service_cidr}${service_host_ip}${lb_range}${gateway_lb_ip}${registry_ip}${registry_host}${trusted_vpn_cidr}${truenas_ip}${directory_cidr}${ntp_server}${upgrade_label}${s3_bucket}${s3_endpoint}" ]]; then
  usage
  exit 0
fi

mapfile -t files < <(
  rg --files README.md docs clusters repositories AGENTS.md CLAUDE.md mise.toml .envrc.example 2>/dev/null |
    sort -u
)

replace_all() {
  local from="$1"
  local to="$2"
  [[ -z "${to}" ]] && return 0
  for file in "${files[@]}"; do
    FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "${file}"
  done
}

replace_file() {
  local file="$1"
  local from="$2"
  local to="$3"
  [[ -z "${to}" || ! -f "${file}" ]] && return 0
  FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "${file}"
}

if [[ -n "${repo_path}" && -z "${repo_ssh}" ]]; then
  repo_ssh="ssh://git@github.com/${repo_path}.git"
fi

replace_file .envrc.example 'homelab' "${cluster_name}"
replace_all 'registry.apps.example.com' "${registry_host}"
replace_all 'upgrade.example.com/enabled' "${upgrade_label}"
replace_all 'apps.example.com' "${domain}"
replace_all 'homeassistant.example.com' "${base_domain:+homeassistant.${base_domain}}"
replace_all 'example.com' "${base_domain}"
replace_all 'you@example.com' "${email}"
replace_all 'your-username/your-homelab-repo' "${repo_path}"
replace_all 'ssh://git@github.com/your-username/your-homelab-repo.git' "${repo_ssh}"
replace_all 'git@github.com:your-username/your-homelab-repo.git' "${repo_ssh#ssh://}"
replace_all '192.168.1.0/24' "${lan_cidr}"
replace_all '192.168.1.1' "${gateway_ip}"
replace_all '192.168.1.10' "${api_vip}"
replace_all '172.16.0.0/16' "${pod_cidr}"
replace_all '172.17.0.0/16' "${service_cidr}"
replace_all '172.17.0.1/32' "${service_host_ip:+${service_host_ip}/32}"
replace_all '172.17.0.1' "${service_host_ip}"
replace_all '10.0.0.0/24' "${trusted_vpn_cidr}"
replace_all '192.168.1.33' "${truenas_ip}"
replace_all '192.168.1.59/32' "${directory_cidr}"
replace_all '192.168.1.219' "${gateway_lb_ip}"
replace_all '192.168.1.221' "${registry_ip}"
replace_all 'time.cloudflare.com' "${ntp_server}"

if [[ -n "${lb_range}" ]]; then
  replace_all '192.168.1.200-192.168.1.220' "${lb_range}"
  lb_start="${lb_range%-*}"
  lb_stop="${lb_range#*-}"
  replace_all '192.168.1.200' "${lb_start}"
  replace_all '192.168.1.220' "${lb_stop}"
fi

replace_all 'your-bucket-name' "${s3_bucket}"
replace_all 'your-backup-bucket-name' "${s3_bucket}"
replace_all 'hel1.your-objectstorage.com' "${s3_endpoint}"
replace_all 's3.your-objectstorage.com' "${s3_endpoint}"

if [[ ! -f .envrc && -f .envrc.example ]]; then
  cp .envrc.example .envrc
  echo "Created .envrc from .envrc.example"
fi

cat <<'EOF'
Starter replacements complete. Review the diff before continuing:
  git diff -- README.md docs clusters repositories AGENTS.md CLAUDE.md mise.toml .envrc.example

Manual follow-up still required:
  - Trim clusters/main/talos/talconfig.yaml to your actual nodes.
  - Set real MAC addresses and node IPs.
  - Generate deploy keys and real secret values.
  - Encrypt all real secret files with ./scripts/sops-files.sh encrypt.
EOF
