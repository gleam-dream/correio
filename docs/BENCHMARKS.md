# Benchmarks

Benchmarks describe measured throughput and latency on one recorded host. They are observations, never a guarantee, and they never gate a change. The correctness companion is [ORACLE.md](ORACLE.md). The policy is in the [evidence design](design/evidence/design.typ) and [ADR 0005](adr/0005-benchmarks-impose-no-threshold.md). [AGENTS.md](../AGENTS.md) lists the commands.

## Scope

- A separate Gleam consumer exercises public APIs only: message preparation, in-memory verification, PostgreSQL verification, and same-challenge contention.
- No benchmark imposes a throughput or latency threshold. Host load, scheduler count, database settings, and warm caches affect results.

## Method

| Workload                  | Measurement                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| MIME preparation          | A text and HTML alternative with a 4096-byte attachment; three repetitions of 1000 messages after 100 warmup operations                      |
| Memory authentication     | 500 issue-and-verify operations per repetition after 100 warmup operations; capacity for 100000 retained challenges                          |
| PostgreSQL authentication | 120 issue-and-verify operations per repetition at concurrency 1, 8, and 24 after 24 warmup operations; a caller-owned pool of 24 connections |
| Same-challenge contention | 24 simultaneous verifications of one newly issued challenge per repetition; one acceptance and 23 refusals are required                      |

- Every authentication service uses a ten-minute validity interval, five failed attempts, and one-day retention. Every run starts from an empty database, and successful terminal records accumulate within the run.
- Worker startup and pool initialization precede measurement. Elapsed time spans dispatching prepared workers to receiving all results. Per-operation latency covers the complete public operation, in monotonic microseconds, with nearest-rank percentiles.
- Samples include every outcome. Infrastructure failures are counted separately and fail the command after the report is preserved. Refusals never count as successful authentications.

## Run

```sh
nix develop -c scripts/benchmark
```

- The command starts a disposable PostgreSQL cluster and runs the consumer, then `benchmarks/report.py` summarizes the samples.
- `CORREIO_BENCHMARK_RESULTS` selects the output directory. The default is `benchmarks/results`, which is git-ignored.
- `samples.json` retains every latency and outcome. `report.json` retains the host and CPU, PostgreSQL, Gleam, and OTP versions, scheduler count, workload configuration, source digest, throughput, outcome counts, and percentiles.
- The CI benchmark workflow runs only when dispatched and keeps its output for thirty days.

## Retained results

Recorded 2026-10-09 on Linux aarch64 (Cortex-A76, 4 cores) with Gleam 1.18.1, OTP 28 (ERTS 16.4), four schedulers, and PostgreSQL 16.15. The table gives the median of three repetitions. No operation failed.

| Workload                    | Concurrency | Samples per repetition |              Operations/s | p50 µs | p95 µs | p99 µs |
| --------------------------- | ----------: | ---------------------: | ------------------------: | -----: | -----: | -----: |
| MIME preparation            |           1 |                   1000 |                    18,976 |     51 |     58 |     74 |
| Memory issue-and-verify     |           1 |                    500 |                    25,160 |     37 |     58 |     77 |
| PostgreSQL issue-and-verify |           1 |                    120 |                       292 |  3,628 |  3,839 |  4,009 |
| PostgreSQL issue-and-verify |           8 |                    120 |                       845 |  8,995 | 11,975 | 13,507 |
| PostgreSQL issue-and-verify |          24 |                    120 |                       949 | 23,832 | 34,465 | 36,582 |
| Same-challenge contention   |          24 |                     24 | 1,526 total (64 accepted) |  9,749 | 15,060 | 15,453 |

- Each contention repetition produced one acceptance and 23 refusals.
- The correio source digest was `dd6b5bc6927582f707136083eaf94650cea585ade7d40410c28a9d53ebb2d82a` (120 files, including uncommitted files).
- The raw samples from this run are not retained in the repository because the results directory is git-ignored. Rerun the command to produce comparable data on another host.

## Limits

- The table describes one host, one repetition set, and one source state. It is context for later runs, not a performance claim.
- The numbers were recorded on OTP 28. The repository now builds with OTP 29, so rerun before comparing.
- PostgreSQL results include a local disposable cluster, not a networked or tuned deployment.
