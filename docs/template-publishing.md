# Template publishing and upstream dependency assessment

This repository is intended to be publishable as a **template/reference GitOps
repo**, not as a turnkey product. It contains original manifests and
documentation for one opinionated Talos + Flux homelab shape, with placeholders
where environment-specific values must be replaced.

## Recommended public positioning

Use language like:

- "Reference GitOps template for Talos, Flux, SOPS/age, Gateway API, and
  selected Helm charts."
- "Copy, rename, trim, and validate before bootstrapping."
- "Includes TrueCharts-based examples, but is not affiliated with TrueCharts or
  TrueForge."

Avoid language like:

- "Official TrueCharts template."
- "Supported TrueCharts distribution."
- "Drop-in replacement for ClusterTool-generated repositories."
- "Production-ready for every cluster."

## Bootstrap paths

There are two viable bootstrap approaches for this repo:

1. **ClusterTool-assisted path**: use ClusterTool for Talos config generation,
   SOPS helpers, and optionally guided bootstrap. This aligns with the
   TrueCharts/TrueForge workflow and the existing `clusterenv.yaml` +
   `talconfig.yaml` layout.
2. **Self-defined Talos/Flux path**: use `talhelper`/`talosctl`, `sops`, and
   `flux bootstrap` directly. This makes the repo less dependent on
   ClusterTool behavior and is easier to reason about when debugging the first
   cluster.

The docs should keep both paths explicit. Prefer the manual path as the
canonical explanation because it shows the boundary between Talos, Flux, SOPS,
and Git deploy keys. Mention ClusterTool as an accelerator and link to upstream
docs instead of copying their step-by-step guide.

Relevant upstream references:

- TrueCharts ClusterTool introduction:
  <https://truecharts.org/clustertool/>
- TrueCharts ClusterTool getting started:
  <https://truecharts.org/clustertool/getting-started/>
- Older guide URL sometimes seen in bookmarks:
  <https://truecharts.org/guides/clustertool/getting-started/>
- Talhelper configuration reference:
  <https://budimanjojo.github.io/talhelper/latest/>
- Flux documentation:
  <https://fluxcd.io/flux/>
- Talos documentation:
  <https://www.talos.dev/latest/>

## TrueCharts dependency posture

This repo is currently **TrueCharts-heavy**. Many HelmReleases use the
`truecharts` HelmRepository (`oci://oci.trueforge.org/truecharts`) and several
operational patterns assume TrueCharts chart values.

That is acceptable for a reference template if the dependency is presented
clearly:

- Chart sources are external dependencies. This repo does not vendor the charts.
- Chart versions must stay pinned in every HelmRelease.
- Users should expect upstream chart values, chart names, licensing, support
  scope, and repository locations to change over time.
- For long-lived personal clusters, consider replacing critical services with
  upstream project charts, `bjw-s/app-template`, or locally-owned manifests
  where supportability matters more than shared TrueCharts values.

Risk areas to call out:

- **Availability risk**: Flux depends on the external OCI/Git/Helm sources
  being reachable.
- **Compatibility risk**: TrueCharts chart values and common-library behavior
  can change across pinned upgrades.
- **Support risk**: TrueCharts support generally applies to their charts and
  tools, not arbitrary downstream template repos.
- **Migration risk**: Stateful apps should have backup/restore tested before
  chart-source changes.

## License and publishing assessment

The repository's own license is MIT. That is suitable for an original template
repo when the committed content is your own manifests, scripts, and docs.

Publishing caveats:

- Do not copy TrueCharts documentation into this repo. Link to upstream docs
  instead.
- Do not vendor TrueCharts chart source unless you intentionally comply with
  the applicable upstream license for that chart or tool.
- TrueCharts documents their project licensing as including AGPL v3 and BSL
  1.1, and the chart repository license can vary by chart. Treat chart content
  as third-party material with its own license.
- HelmRelease manifests that reference external charts are normally just
  configuration in this repo. They do not make the chart source part of this
  repository, but a downstream user still needs to comply with the chart and
  application licenses for what they deploy.
- Remove or encrypt all real secrets before publishing. Placeholder
  `*.secret.yaml` files are acceptable only while they contain non-sensitive
  template values.
- Keep a short attribution/disclaimer in the README so users understand this is
  an independent template that depends on external projects.

This is an engineering assessment, not legal advice. If the repo is published
for commercial use or redistributed with vendored third-party chart content,
get a proper license review.

## Template readiness checklist

Before publishing or marking the repo as a GitHub template:

- Run `./scripts/check-repo.sh` and `mise run validate`.
- Run `./scripts/sops-files.sh check` and confirm no real plaintext secrets
  remain.
- Search for private domains, IP ranges, hostnames, tokens, emails, bucket
  names, VPN CIDRs, deploy keys, and storage paths.
- Confirm `.envrc`, `age.agekey`, generated Talos `clusterconfig/`, deploy
  keys, kubeconfigs, and talosconfigs are gitignored.
- Keep examples small enough for a newcomer to trim. Large reference topologies
  should be labeled as examples, not defaults.
- Keep upstream references as links, not copied guide text.
