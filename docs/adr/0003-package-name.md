# ADR 0003: Correio package name

<a id="adr-0003"></a>

## Decision

- The package name is `correio`.
- Public module names, optional adapter packages, repository paths, development configuration, and documentation use Correio.
- The PostgreSQL table `ecarta_challenges`, its retention index, and verifier domain `ecarta-passwordless-v1` retain their original identifiers.

## Rationale

- The repository owner requested the rename from Ecarta to Correio.
- Package branding does not require a storage migration.
- Changing the verifier domain would invalidate outstanding challenge answers.
- Historical oracle and benchmark reports retain their recorded source identity. New runs report Correio.
