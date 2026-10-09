# ADR 0001: Separate delivery and authentication

<a id="adr-0001"></a>

## Decision

- Correio exposes independent email delivery and passwordless verification modules. Applications compose them and own accounts, registration, permissions, browser routes, and sessions.
- The application maps Correio verification evidence and Warden OIDC identity into its own principal type. Correio never constructs Warden's OIDC-specific verified identity.
- Challenge stores implement atomic semantic operations that include expiry and attempt accounting. A generic compare-and-set alone does not establish those guarantees.

## Rationale and alternatives

- Email delivery is reusable outside authentication. Putting delivery inside Warden would couple provider configuration and message content to OIDC lifetimes.
- Phoenix supplies a useful sequential authentication reference. AshAuthentication supplies concurrent single-use evidence. Swoosh supplies normalized email semantics. Each oracle applies only to its stated comparison.
- Warden's existing verified identity requires an ID token. Its design also records an unresolved consumption-time expiry boundary. Reusing those contracts unchanged would misstate local email authentication evidence.

## Provenance

- On 9 October 2026 UTC, the repository owner requested the new package under its original name, `ecarta`, ecosystem development setup, implementation of the proposed composition diagram, oracle comparisons, benchmarks, and end-to-end tests.
- The preceding research inspected Swoosh 1.28.1, Phoenix 1.8.15, and AshAuthentication 4.15.0. Executable oracle manifests retain exact revisions and licenses.
