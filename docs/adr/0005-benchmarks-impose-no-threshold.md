# Benchmarks retain raw samples and impose no throughput threshold

<a id="adr-0005"></a>

## Decision

- Benchmarks run only on explicit request and never gate a change.
- Each run retains every latency and outcome sample, the host description, the workload configuration, and a source digest that includes uncommitted files.
- Infrastructure failures are counted separately and fail the command after the report is preserved. Refused duplicate verifications never count as successful authentications.
- The method and dated results live in the retained reference document, which cross-links the oracle reference.

## Rationale

- Host load, scheduler count, database settings, and warm caches change results, so no machine-independent threshold is defensible.
- Raw samples let a reader recompute any percentile instead of trusting a summary.
- Same-challenge contention measures refusal behavior, so counting refusals as throughput would misreport authentication capacity.

## Reference

- [docs/BENCHMARKS.md](../BENCHMARKS.md) retains the workloads, method, run command, limits, and a dated summary of the last recorded run. That run used Gleam 1.18.1, OTP 28, and four schedulers, and its numbers describe one host.
- A new recorded run updates the table with its date and environment. The numbers are context for later runs, not a guarantee.
