# Continuous integration

- `scripts/check` checks formatting, compiles, and tests the package, PostgreSQL adapter, Postmark adapter, and passwordless consumer. It runs native protocol and database checks through `scripts/e2e` without requiring Elixir oracle dependencies.
- `scripts/e2e` runs the actual local SMTP, HTTP-provider, PostgreSQL fault, and browser-consumer suites. Every database suite receives a new disposable cluster. Tests do not use existing databases or live mail providers.
- CI requires native checks, repository formatting and design integrity, and pinned upstream oracle comparisons. The benchmark workflow runs only when explicitly dispatched and imposes no machine-dependent throughput threshold.
- The consumer uses sibling checkouts of Warden, Sinal, and HTTP Gun. `sibling-revisions.txt` pins the clean revisions used for the composition evidence. The composite checkout action validates every pin and disables persisted checkout credentials.
- Cold builds access GitHub, Nix binary caches, and Hex to download the locked toolchain and dependencies. The oracle suite fetches pinned Git revisions and checks source cleanliness and vendored template hashes before execution. Tests then communicate only with local peers.
- CI deliberately restores no shared compiled dependency cache. Local `build/`, Mix `_build/` and dependency directories can be reused within a checkout; lock files and oracle source checks remain authoritative. No credentials, database data, or authentication answers belong in artifacts.
- Failed jobs retain their logs and available machine-readable receipts. Native and oracle artifacts expire after fourteen days; benchmark observations expire after thirty days.
