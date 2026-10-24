# The package is named correio and stored identifiers keep their original names

<a id="adr-0003"></a>

## Decision

- The package name is `correio`.
- Public module names, optional adapter packages, repository paths, development configuration, and documentation use Correio.
- The PostgreSQL table `ecarta_challenges`, its retention index, and the verifier domain `ecarta-passwordless-v1` retain their original identifiers.

## Rationale

- The package began under the name `ecarta`, and the repository owner requested the rename to Correio.
- Package branding does not require a storage migration.
- Changing the verifier domain would invalidate outstanding challenge answers.
- Oracle and benchmark reports retained from earlier runs record their original source identity. New runs report Correio.

## Provenance

- On 9 October 2026 UTC, the repository owner requested the new package, ecosystem development setup, implementation of the proposed composition diagram, oracle comparisons, benchmarks, and end-to-end tests.
