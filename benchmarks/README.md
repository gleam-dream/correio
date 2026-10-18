# Benchmark harness

- The harness runs a separate Gleam consumer over public APIs against a disposable PostgreSQL and summarizes the samples with `report.py`.
- Run `nix develop -c scripts/benchmark` from the package root. `CORREIO_BENCHMARK_RESULTS` selects the output directory, which defaults to `benchmarks/results`.
- The workloads, method, retained results, and limits are in [docs/BENCHMARKS.md](../docs/BENCHMARKS.md). Correctness comparisons are in [docs/ORACLE.md](../docs/ORACLE.md).
