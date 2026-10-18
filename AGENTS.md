# Agent instructions

## Responsibility

- Correio owns transactional message construction, delivery evidence, and independent passwordless challenge verification. Applications own accounts, registration, permission decisions, browser routes, and sessions.
- Read `docs/design/design.typ`, the relevant `docs/design/<context>/design.typ` and `CONTEXT.typ`, `docs/COVERAGE.md`, and the relevant ADRs before changing a public contract.
- Keep the design layer timeless. Record decisions and history in ADRs, and preserve unresolved requirements in the native pending ledger.
- Exercise public APIs from the separate `apps/passwordless_demo` package with ordinary use, advanced configuration, application-native types, and recovery. Each usage topic is a runnable example there.
- Never automatically retry a possibly transmitted email.
- Never read or copy credential files. Use local scripted peers and a disposable PostgreSQL for tests.
- Pin oracle source revisions and preserve upstream licenses.

## References

- [docs/ORACLE.md](docs/ORACLE.md) pins the upstream implementations (Swoosh, Phoenix, AshAuthentication) that Correio is compared against, states what is compared and excluded, and records the last receipt.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) states the benchmark workloads and method and records dated, non-binding results. It cross-links the oracle reference.
- Usage lives as compiled, runnable examples in `apps/passwordless_demo/src/usage` (run by `apps/passwordless_demo/test/usage_test.gleam`) and `adapters/correio_postmark/test/usage_test.gleam`. Update an example in the same change as the API it shows.

## Tooling

- `nix develop` supplies Gleam, Erlang/OTP 29, rebar3, Elixir, Python, PostgreSQL, Node, and lefthook. Linux shells also supply Chromium for browser checks.
- `nix develop -c scripts/check` runs the fast gate: format, build, and test for the package, both adapters, and the consumer (including every usage example), then the shell and Python checks and `scripts/e2e`.
- `nix develop -c scripts/e2e` runs the native SMTP, HTTP-provider, PostgreSQL fault, and browser-consumer suites. `scripts/browser-e2e` runs the Chromium check alone.
- `nix develop -c scripts/oracles` runs the pinned oracle comparisons (see `docs/ORACLE.md`). `nix develop -c scripts/benchmark` runs the benchmarks, which impose no threshold and never gate a change (see `docs/BENCHMARKS.md`).
- `scripts/with-postgres.sh CMD...` runs a command against a disposable PostgreSQL.
- Adapter tests: `nix develop -c scripts/with-postgres.sh sh -c 'cd adapters/correio_postgres && gleam test && ./check-ownership.sh'`; in `adapters/correio_postmark` and `adapters/correio_mailbox`, run `nix develop ../.. -c gleam test`.
- Try the local login flow with `nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'`.
- `nix fmt -- PATH...` formats named files, `nix flake check` checks formatting, and the pre-commit hook formats and re-stages staged files.
- `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` renders the design, and `nix run .#design-gate-check -- docs/design .` checks render freshness and design integrity.
- After authoring the design, run context estimation and a selected section export. Run layer operations sequentially because they share `.render`.
- CI pins sibling checkouts in `sibling-revisions.txt`. Update a pin when a sibling's public contract changes, and never restore a shared compiled dependency cache.
- Use repository-scoped Git only. Preserve sibling repositories and unrelated work.
