# Benchmarks

- Run `nix develop -c scripts/benchmark` from the package root.
- The command starts disposable PostgreSQL and runs a separate Gleam consumer over public APIs.
- `CORREIO_BENCHMARK_RESULTS` selects the output directory. The default is `benchmarks/results`.
- `samples.json` retains every observed latency and outcome. `report.json` retains host, CPU, PostgreSQL, Gleam, OTP, schedulers, workload configuration, source digest, throughput, outcome counts, and nearest-rank latency percentiles. `report.md` presents the measurements.

## Workloads

- MIME preparation renders a text and HTML alternative with a 4096-byte attachment. Each of three repetitions measures 1000 messages after 100 warmup operations.
- Memory authentication measures 500 issue-and-verify operations per repetition after 100 warmup operations. The store has capacity for 100000 retained challenges.
- PostgreSQL authentication measures 120 issue-and-verify operations per repetition at concurrency 1, 8, and 24 after 24 warmup operations. The caller owns a pool of 24 connections.
- Same-challenge contention measures 24 simultaneous verification requests against one newly issued challenge per repetition. One acceptance and 23 refusals are required. Refusals do not count as successful authentications.
- All authentication services use a ten-minute validity interval, five failed attempts, and one-day retention. Every run starts from an empty database. Successful terminal records accumulate within the run.

## Interpretation

- Worker startup and pool initialization happen before measurement. Elapsed time includes dispatching prepared workers and collecting their results. Per-operation latency covers the complete public operation.
- Samples include all outcomes. Infrastructure failures are counted separately and cause a nonzero command exit after preserving the report.
- The command imposes no throughput or latency threshold. Host load, scheduler count, database settings, and warm caches affect results.
- The source digest includes uncommitted repository files and records its exclusions. It identifies the tested bytes without claiming a published release.
