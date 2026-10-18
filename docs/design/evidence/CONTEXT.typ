#let terms = (
  (
    slug: "term-oracle",
    title: [Oracle],
    body: [A pinned external implementation used to judge an explicitly named subset of observable behavior.],
  ),
  (
    slug: "term-oracle-receipt",
    title: [Oracle receipt],
    body: [The machine-readable record of one oracle run: platform, source revisions, Correio source digest, and scenario counts. It never contains raw authentication answers.],
  ),
  (
    slug: "term-scripted-peer",
    title: [Scripted peer],
    body: [A local SMTP or HTTP server that records real protocol exchanges and injects declared faults. It stands in for a provider and qualifies none.],
  ),
  (
    slug: "term-disposable-cluster",
    title: [Disposable cluster],
    body: [A fresh PostgreSQL cluster created for one check and discarded afterward. No check uses an existing database.],
  ),
  (
    slug: "term-sibling-revision-pin",
    title: [Sibling revision pin],
    body: [An exact commit of a sibling repository (Warden, Sinal, HTTP Gun) recorded in the pin file for composition evidence.],
  ),
  (
    slug: "term-usage-example",
    title: [Usage example],
    body: [Runnable code that demonstrates one documented usage topic and is compiled and executed by the repository gate.],
  ),
  (
    slug: "term-benchmark-workload",
    title: [Benchmark workload],
    body: [One named measurement case with fixed warmup, repetitions, concurrency, and policy. A workload result is delimited by its recorded host and source digest.],
  ),
)
