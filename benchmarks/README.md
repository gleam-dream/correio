# Benchmark harness

[![CI](https://github.com/gleam-dream/correio/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/correio/actions/workflows/ci.yml)
[![correio on Hex](https://img.shields.io/hexpm/v/correio?label=Hex%3A%20correio)](https://hex.pm/packages/correio)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

- The harness runs a separate Gleam consumer over public APIs against a disposable PostgreSQL and summarizes the samples with `report.py`.
- Run `nix develop -c scripts/benchmark` from the package root. `CORREIO_BENCHMARK_RESULTS` selects the output directory, which defaults to `benchmarks/results`.
- The workloads, method, retained results, and limits are in [docs/BENCHMARKS.md](../docs/BENCHMARKS.md). Correctness comparisons are in [docs/ORACLE.md](../docs/ORACLE.md).
