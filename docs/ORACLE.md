# Oracle comparisons

Correio is compared against pinned upstream implementations that run unmodified. Each comparison judges a named subset of observable behavior, and success never establishes a broader claim. The measurement companion is [BENCHMARKS.md](BENCHMARKS.md). The rules these comparisons implement are in the [evidence design](design/evidence/design.typ) and [ADR 0004](adr/0004-oracle-comparisons-judge-named-behavior.md). [AGENTS.md](../AGENTS.md) lists the commands.

## Reference sources

The pins live in [`oracles/manifest.json`](../oracles/manifest.json) and the Mix lock, which retains every transitive dependency version. `oracles/check_sources.py` verifies each pin before a run.

| Reference         | Version | Upstream                                                                              | Pinned revision                            | License | Executed behavior                                                              |
| ----------------- | ------- | ------------------------------------------------------------------------------------- | ------------------------------------------ | ------- | ------------------------------------------------------------------------------ |
| Swoosh            | 1.28.1  | [swoosh/swoosh](https://github.com/swoosh/swoosh)                                     | `13f10492615cbb9c29cc974f14e18e1c26a551b5` | MIT     | Email construction and its SMTP adapter, observed through a loopback SMTP peer |
| Phoenix           | 1.8.15  | [phoenixframework/phoenix](https://github.com/phoenixframework/phoenix)               | `bd1801833b4fd7ceb02497cc7ba2d05e9bd391c8` | MIT     | Upstream `phx.gen.auth` templates rendered and executed on PostgreSQL          |
| AshAuthentication | 4.15.0  | [team-alembic/ash_authentication](https://github.com/team-alembic/ash_authentication) | `d6b2be35cf8f0b8ab84e7a934cfb0d91de0a3c17` | MIT     | Magic-link token request and sign-in actions under concurrent redemption       |

- Swoosh and AshAuthentication are exact Git checkouts. `check_sources.py` fails when a checkout differs from its pinned revision or contains any modification.
- Phoenix templates are byte-for-byte copies under `oracles/vendor/phoenix`. Their SHA-256 hashes are checked against the manifest:
  - `context_functions.ex.eex`: `0a818348e1cb25666dcd6859e99a865f2e4b214008e71ddfac248933f223c5cc`
  - `schema.ex.eex`: `f3a79eee63c2b3ff6e373135129238f3f3dfceeb20b4029b28288f90ebd3b592`
  - `schema_token.ex.eex`: `218427ef8bdd761afdd8d08995aaa1911d427281f3fce72da873fdf05fcf99ec`
- Python's standard MIME parser independently normalizes both the upstream and the Correio message. The pinned SMTP library is shared by Swoosh and the loopback peer, not by Correio's renderer.
- Upstream licenses are preserved under `oracles/licenses`. These Elixir dependencies are absent from Correio's runtime dependency graph.

## What is compared

### Swoosh: message semantics

- Eight retained JSON email fixtures are built and submitted by Swoosh through its real SMTP adapter. A loopback peer records the actual `MAIL FROM`, `RCPT TO`, and `DATA` commands, so the harness never reimplements envelope selection.
- Recipient roles, custom headers, subject, charset, multipart topology, decoded body and attachment bytes, disposition, filename, and content identifiers are significant.
- Structured `List-Unsubscribe` fields keep their raw unfolded syntax, so RFC 2047 decoding cannot hide a malformed URL list. Other custom fields keep their parsed values.
- The SMTP capture removes dot stuffing and exactly one CRLF appended before the `DATA` terminator. It preserves authored trailing bytes. This framing rule does not claim that downstream storage preserves message bytes.

### Phoenix: sequential challenge behavior

- The generated schema, token schema, and context execute against PostgreSQL. Five sequential cases cover acceptance, reuse refusal, expiry, wrong purpose, and destination mismatch.
- Correio's configurable expiry is not required to equal Phoenix's fifteen-minute default.

### AshAuthentication: concurrent single use

- The magic-link strategy runs three rounds of twenty-four concurrent redemptions. Every worker holds a separate PostgreSQL connection before the barrier opens.
- Exactly one redemption succeeds, and at least one losing worker must report an actual revocation conflict. Backend identifiers are retained as connection evidence.
- Correio must independently pass the same observable single-use result. Upstream success does not establish Correio's correctness.

## Outcome classification

- A scenario either agrees or differs after normalization. Any semantic difference fails the run.
- Generated dates, message identifiers, boundaries, header folding, recipient ordering, and equivalent transfer encodings are ignored. CRLF and LF are equivalent in decoded text bodies. An absent body-part disposition equals inline when no attachment filename or content identifier exists.
- Authentication random values are never compared. Only outcomes and connection counts are.
- The run exits nonzero on a source-pin failure, a unit failure in the comparison code, an upstream or Correio execution failure, or a semantic difference.

## Exclusions and deliberate differences

- Phoenix account confirmation, password registration, browser policy, session publication, and account linking are application policy and outside the comparison.
- AshAuthentication registration and password strategies are outside the comparison.
- Correio and Swoosh use different MIME encoders. Transport fault tests remain separate evidence.
- The pinned AshAuthentication dependency (Ash 3.33.4) has published advisories affecting bulk private action arguments and unsafe atom filtering. This isolated oracle uses neither path.

## Run

```sh
nix develop -c scripts/oracles
```

- The command creates a disposable PostgreSQL cluster, verifies the pins, runs the comparison's own unit tests, executes the upstream implementations, executes Correio, and compares the normalized results.
- `CORREIO_ORACLE_RESULTS` selects the output directory. The default is `oracles/results`, which is git-ignored.
- The output directory receives `receipt.json`, the upstream and Correio raw results, and their normalized forms. Files named `ecarta*.json` are the Correio side under its earlier package name. Raw authentication answers are never serialized.
- The run needs network access only to fetch the pinned Git revisions and Hex packages.

## Retained receipt

The last recorded run passed on 2026-10-09 (Linux aarch64).

| Item                            | Value                                                                          |
| ------------------------------- | ------------------------------------------------------------------------------ |
| Status                          | passed                                                                         |
| Email fixtures                  | 8                                                                              |
| Sequential authentication cases | 5                                                                              |
| Contention rounds               | 3, each with 24 concurrent connections                                         |
| Correio source digest           | `dd6b5bc6927582f707136083eaf94650cea585ade7d40410c28a9d53ebb2d82a` (120 files) |

- The digest uses SHA-256 over path and bytes. It includes uncommitted files, records its exclusions, and claims no published release.

## Limits

- Email fixtures exercise message semantics. They do not establish SMTP reliability, inbox delivery, all provider options, internationalized envelope support, or all MIME media types.
- No real provider or existing user database is used. The comparison qualifies no remote service.
