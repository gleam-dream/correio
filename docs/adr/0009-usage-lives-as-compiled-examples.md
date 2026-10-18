# Usage lives as compiled examples that the repository gate runs

<a id="adr-0009"></a>

## Decision

- Each usage topic is runnable code: one module per topic in the separate consumer package, and a local-peer test in the Postmark adapter. The README keeps a short usage section that mirrors the first examples and links the rest.
- The fast gate compiles and runs every example. The PostgreSQL example runs against a disposable cluster in the same lane that already runs the consumer's tests.
- No standalone prose usage guide exists. A change to a public API updates its example in the same change.

## Rationale

- A prose guide drifts from the library without any signal. An example that compiles and runs fails the gate when the API moves.
- An example needs a scripted peer or a disposable database to run, so each example states which inputs it needs and runs without credentials, a live provider, or an existing database.
- Examples show ordinary use, a typed refusal, and recovery, so a reader sees the failure contract as well as the success path. A real SMTP or Postmark submission is out of scope for an example because it would need a live provider.

## Consequences

- The oracle reference and the benchmark reference remain separate retained documents. They record pins and measurements, which no example can express. See [ADR 0004](0004-oracle-comparisons-judge-named-behavior.md) and [ADR 0005](0005-benchmarks-impose-no-threshold.md).
- An example that needs a new external input must also name it in the gate. The consumer's tests require `DATABASE_URL` from the disposable cluster.
