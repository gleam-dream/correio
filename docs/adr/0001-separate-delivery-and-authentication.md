# Correio separates email delivery from passwordless verification

<a id="adr-0001"></a>

## Decision

- Correio exposes independent email delivery and passwordless verification modules. Applications compose them and own accounts, registration, permissions, browser routes, and sessions.
- The application maps Correio verification evidence and Warden OIDC identity into its own principal type. Correio never constructs Warden's OIDC-specific verified identity.
- Challenge stores implement atomic semantic operations that include expiry and attempt accounting. A generic compare-and-set alone does not establish those guarantees.

## Rationale and alternatives

- Email delivery is reusable outside authentication. Putting delivery inside Warden would couple provider configuration and message content to OIDC lifetimes.
- Warden's existing verified identity requires an ID token. Its design also records an unresolved consumption-time expiry boundary. Reusing those contracts unchanged would misstate local email authentication evidence.
- A generic compare-and-set store would leave expiry sampling and attempt accounting to each caller. The semantic store port makes the serialization boundary part of the contract.

## Consequences

- Neither context imports the other, and no transaction spans them. A failure between issuing a challenge and delivering its message is an application concern.
- The consumption-time expiry boundary stays open as a ruling in the design's pending ledger.
