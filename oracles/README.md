# Oracle harness

- The harness executes pinned Swoosh, Phoenix, and AshAuthentication sources and Correio, then compares normalized results.
- Run `nix develop -c scripts/oracles` from the package root. `CORREIO_ORACLE_RESULTS` selects the output directory.
- Pins and template hashes are in `manifest.json` and `mix.lock`. Fetched inputs live in the git-ignored `.cache/` and `deps/` directories.
- The sources, normalization, exclusions, retained receipt, and limits are in [docs/ORACLE.md](../docs/ORACLE.md). Measurements are in [docs/BENCHMARKS.md](../docs/BENCHMARKS.md).
