# Agent instructions

## Responsibility

- Correio owns transactional message construction, delivery evidence, and independent passwordless challenge verification. Applications own accounts, registration, permission decisions, browser routes, and sessions.
- Read `docs/design/design.typ`, `docs/design/CONTEXT.typ`, `docs/COVERAGE.md`, and relevant ADRs before changing a public contract.
- Keep current design timeless. Record decisions and attributable history in ADRs. Preserve unresolved requirements in the native pending ledger.
- Exercise public APIs from the separate `apps/passwordless_demo` package with ordinary use, advanced configuration, application-native types, and recovery.
- Preserve the difference between local validation, provider acceptance, inbox delivery, confirmed storage, and uncertain effects. Never automatically retry a possibly transmitted email.
- Keep oracle comparisons, compiler evidence, real transport tests, PostgreSQL fault tests, and benchmarks distinct. Pin oracle source revisions and preserve licenses.
- Never read or copy credential files. Use local scripted peers and disposable PostgreSQL for tests.

## Tooling

- `nix develop` supplies Gleam, Erlang/OTP 28, rebar3, Elixir, Python, PostgreSQL, Node, and lefthook. Linux shells also supply Chromium for browser checks.
- `nix develop -c scripts/check` runs the package's fast executable gate.
- `nix fmt -- PATH...` formats named files. `nix flake check` checks formatting.
- The pre-commit hook formats and re-stages staged files.
- `scripts/with-postgres.sh` owns disposable local database experiments.
- `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` renders the design.
- `nix run .#design-gate-check -- docs/design .` checks render freshness and design integrity.
- Run design context estimation and a selected section export after authoring. Run layer operations sequentially because they share `.render`.
- Repository-scoped Git only. Preserve sibling repositories and unrelated work.
