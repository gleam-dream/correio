# CI uses sibling checkouts pinned by exact revision

<a id="adr-0006"></a>

## Decision

- The Postmark adapter and the browser demo depend on sibling checkouts of HTTP Gun, Sinal, and Warden.
- A pin file records one clean revision per sibling. The composite checkout action validates every pin and disables persisted checkout credentials.
- CI restores no shared compiled dependency cache. Lock files and oracle source checks stay authoritative.

## Rationale

- The siblings are unpublished, so a version range cannot name them. An exact revision makes composition evidence reproducible.
- A shared compiled cache could hide a stale dependency behind a passing build.
- Persisted checkout credentials in artifacts or caches would leak access, so checkouts keep none.

## Consequences

- A change to a sibling's public contract requires updating its pin before Correio's composition evidence can pass.
- Native and oracle artifacts expire after fourteen days and benchmark observations after thirty. No credential, database data, or authentication answer enters an artifact.
