# Flux desired/live convergence template contract

This template owns a renderable desired-state example. A repository copied from
it owns the resulting Git history and any live Flux projection.

## Template invariants

- The default reconciliation tree and every included service kustomization build successfully.
- Desired state changes through Git rather than undocumented live edits.
- Secret examples remain placeholders until encrypted by the adopting operator.
- Template CI claims renderability and consistency, not live cluster health.
- A copied repository replaces template identifiers and records its own observation and recovery boundaries.

## Adoption mapping

| Template claim | Oracle | Adopting repository extension |
|---|---|---|
| Desired tree is renderable | `kustomize build` | Observe Flux source and Kustomization revision. |
| Repository conventions are consistent | `scripts/check-repo.sh` | Add cluster-specific policy checks. |
| Protocol packet is structurally valid | Agentops repository gate | Add live read-only oracles and implementation anchors. |

The copied repository may raise verification depth only after it has real,
sanitized evidence. It must not inherit a production-readiness claim from this
template.
