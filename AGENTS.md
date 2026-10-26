# Agent instructions

## Responsibility

- Correio owns transactional message construction, delivery outcomes, and independent passwordless challenge verification. Applications own accounts, registration, permission decisions, browser routes, and sessions.
- Read `docs/design/design.typ`, the relevant `docs/design/<context>/design.typ` and `CONTEXT.typ`, `docs/COVERAGE.md`, and the relevant ADRs before changing a public contract.
- Keep the design layer timeless. Record decisions and history in ADRs, and preserve unresolved requirements in the native pending ledger.
- Exercise public APIs from the separate `apps/passwordless_demo` package with ordinary use, advanced configuration, application-native types, and recovery. Each usage topic is a runnable example there.
- Never automatically retry a possibly transmitted email.
- Never read or copy credential files. Use local scripted peers and a disposable PostgreSQL for tests.
- Pin oracle source revisions. Oracle inputs are fetched into the git-ignored `oracles/.cache` and `oracles/deps` at run time and are never committed.

## References

- [docs/ORACLE.md](docs/ORACLE.md) pins the upstream implementations (Swoosh, Phoenix, AshAuthentication) that Correio is compared against, states what is compared and excluded, and records the last receipt.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) states the benchmark workloads and method and records dated, non-binding results. It cross-links the oracle reference.
- Usage lives as compiled, runnable examples in `apps/passwordless_demo/src/usage` (run by `apps/passwordless_demo/test/usage_test.gleam`) and `adapters/correio_postmark/test/usage_test.gleam`. Update an example in the same change as the API it shows.

## Tooling

- When updating dependency pins, reconcile affected `manifest.toml` files in examples, consumers and nested packages through Gleam, then run the full repository gate; updating the root lock alone is insufficient.

- `nix develop` supplies Gleam, Erlang/OTP 29, rebar3, Elixir, Python, PostgreSQL, Node, and lefthook. Linux shells also supply Chromium for browser checks.
- `nix develop -c scripts/check` runs application compilation and tests for the package, both adapters, and the consumer (including every usage example), then comparison tests and `scripts/e2e`.
- `nix develop -c scripts/e2e` runs the native SMTP, HTTP-provider, PostgreSQL fault, and browser-consumer suites. `scripts/browser-e2e` runs the Chromium check alone.
- `nix develop -c scripts/oracles` runs the pinned oracle comparisons (see `docs/ORACLE.md`). `nix develop -c scripts/benchmark` runs the benchmarks, which impose no threshold and never gate a change (see `docs/BENCHMARKS.md`).
- `scripts/with-postgres.sh CMD...` runs a command against a disposable PostgreSQL.
- Adapter tests: `nix develop -c scripts/with-postgres.sh sh -c 'cd adapters/correio_postgres && gleam test && ./check-ownership.sh'`; in `adapters/correio_postmark` and `adapters/correio_mailbox`, run `nix develop ../.. -c gleam test`.
- Try the local login flow with `nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'`.
- `nix fmt -- PATH...` formats named files, `nix flake check` checks formatting, and the pre-commit hook formats and re-stages staged files.
- `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` renders the design.
- Adapters use Hex versions of Correio and HTTP Gun. The demo still uses a pinned Git Hellhound dependency and its qualified closure; each `manifest.toml` is the lock. Update dependencies with `gleam deps update <package>` when their public contracts change. CI never restores a shared compiled dependency cache.
- Use repository-scoped Git only. Preserve sibling repositories and unrelated work.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents:
the root design is `docs/design/design.typ`, each context has its own
`design.typ` and `CONTEXT.typ` under `docs/design/<context>/`, and
`docs/adr/` records decision rationale. The layer renders to one
`docs/design/design-layer.pdf`. `docs/COVERAGE.md` maps repository parts to
their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design tools** — `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
renders the design. `nix run .#design-gate-context -- docs/design --estimate`
estimates context. CI calls the shared validator directly with
`nix run .#design-gate-check -- docs/design .`. Run `nix flake check` separately
for repository formatting. Local test scripts own application compilation and behavior.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md adapters/correio_mailbox/README.md adapters/correio_postmark/README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md adapters/correio_mailbox/README.md adapters/correio_postmark/README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
