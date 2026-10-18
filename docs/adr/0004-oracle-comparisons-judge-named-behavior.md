# Oracle comparisons judge only explicitly named behavior

<a id="adr-0004"></a>

## Decision

- Each oracle is a pinned upstream implementation executed as-is: Swoosh for message semantics, Phoenix for sequential challenge behavior, and AshAuthentication for concurrent single-use consumption.
- A comparison names the behavior it judges, its normalization, and its limits. Success on an oracle never establishes a broader claim.
- Oracle dependencies stay in an isolated test project and never enter Correio's runtime dependency graph.
- The pins, scope, exclusions, run command, and last receipt are retained in [docs/ORACLE.md](../ORACLE.md). A change to a pin or to a compared behavior updates that document in the same change. It cross-links the benchmark reference.

## Rationale

- Swoosh supplies normalized email semantics. Phoenix supplies a sequential authentication reference. AshAuthentication supplies concurrent single-use evidence. None of them covers the whole contract.
- An imitation of an upstream algorithm is not independent evidence, so the harness executes the pinned source and a loopback peer records the actual SMTP commands.
- Upstream success does not establish Correio's correctness. Correio must independently pass the same observable result.
- Random authentication values are never compared, so a comparison cannot depend on secret generation.

## Evidence

- The research behind the comparisons inspected Swoosh 1.28.1, Phoenix 1.8.15, and AshAuthentication 4.15.0. The executable manifest retains exact revisions and licenses.
- The pinned Ash dependency (3.33.4) has published advisories affecting bulk private action arguments and unsafe atom filtering. The isolated oracle uses neither path, and the dependency is absent from Correio's runtime graph.
