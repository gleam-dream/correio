#import "../.render/designlib.typ": *
#let title = [Evidence]
#let accent = "amber"
#let body = [
  #section(title: "Foundation", lead: "Each check names its authority and its limits. Distinct kinds of evidence are never merged into one claim.", body: [
    #goal(title: "Make failure and scale measurable")[Executable consumers establish transport, persistence, recovery, and concurrency behavior. Repeatable benchmarks describe measured throughput and latency.]
    #goal(title: "Judge behavior against pinned independent implementations")[Oracle comparisons execute exact upstream sources, not imitations of their algorithms.]
    #goal(title: "Keep documented usage executable")[Each documented usage topic is code that compiles and runs in the repository gate, so documentation cannot drift from the library.]
    #no-goal(title: "Qualify a live provider or certify a throughput level")[Scripted local peers qualify no remote provider, and no benchmark imposes a machine-independent threshold.]
    #invariant(title: "Evidence kinds stay distinct", enforcement: "mechanism")[Compiler checks, oracle comparisons, real transport tests, PostgreSQL fault tests, browser checks, and benchmarks each report separately with their own limits.]
    #invariant(title: "Oracle sources are pinned and clean", enforcement: "mechanism")[An oracle run checks exact source revisions, source cleanliness, and vendored template hashes before it executes.]
    #invariant(title: "Documented usage runs in the gate", enforcement: "mechanism")[Every usage example is compiled and executed by the fast gate, so an API change that breaks an example fails the gate.]
    #principle(title: "State the limit with the result")[Every evidence row records what it does not establish.]
  ])

  #section(title: "Evidence classes", lead: "Each class exercises one contract and declares its limit.", body: [
    #md-table(3, (
      [Evidence], [Contract exercised], [Limit],
      [Gleam compiler and separate consumer], [Ordinary and advanced public calls with application-native types], [Compilation alone proves no network or database behavior],
      [Swoosh oracle], [Normalized recipients, bodies, headers, attachment bytes, and MIME structure], [No inbox-delivery or provider-wide parity claim],
      [Phoenix oracle], [Sequential challenge acceptance, expiry, purpose and destination binding, and reuse refusal], [Generated application policy is compared only where Correio's contract matches],
      [AshAuthentication oracle], [Concurrent single-use consumption on separate PostgreSQL connections], [Upstream success does not establish Correio's store correctness],
      [Usage examples], [Ordinary use, typed refusal, and recovery for each documented topic, run offline against scripted peers and a disposable cluster], [Examples contact no live provider and demonstrate rather than qualify a contract],
      [Native transport and database faults], [TLS refusal, ambiguous submission, commit uncertainty, lock expiry, restart, and concurrency], [Scripted local peers do not qualify every remote provider],
      [Browser check], [Cookie navigation policy through a real Chromium session], [Negative origin, CSRF, and recovery cases run in separate HTTP tests],
      [Benchmarks], [Message preparation, verification, database throughput and latency, and contention], [Recorded host, concurrency, workload, and revision delimit the result],
    ))
    #points([All checks use #term("term-scripted-peer") values and a #term("term-disposable-cluster"). None needs provider credentials, a live provider, or an existing database.], [The native, browser, and benchmark harness targets Linux. The library itself targets Erlang.])
  ])

  #section(title: "Oracle comparisons", lead: "An oracle judges a named subset of behavior. Each comparison states its normalization and its limit.", body: [
    #points([An #term("term-oracle") manifest pins version, exact source revision, license, fixture inputs, command, normalization, and intentional differences. The dependency lock retains every transitive version. Swoosh and AshAuthentication use exact Git revisions, and Phoenix templates remain byte-for-byte copies of the pinned source checked against the manifest.], [A run produces an #term("term-oracle-receipt") that includes platform, source revisions, the Correio source digest, and scenario counts. Raw authentication answers are never serialized. Authentication random values are never compared; only outcomes and connection counts are.])
    #points([Swoosh judges message semantics. Its retained fixtures are submitted through the real SMTP adapter, a loopback peer records the actual SMTP commands, and an independent MIME parser normalizes both sides. Recipient roles, headers, charset, multipart topology, decoded bytes, disposition, filename, and content identifiers are significant. Generated values, header folding, recipient ordering, and equivalent encodings are ignored.], [Phoenix judges sequential challenge behavior: acceptance, reuse refusal, expiry, wrong purpose, and destination mismatch. AshAuthentication judges concurrent single use: three races of twenty-four redemptions on separate connections must produce exactly one success.], [Correio must independently pass each observable result, because upstream success does not establish Correio's correctness. Account policy, browser policy, sessions, and unrelated upstream strategies are outside every comparison. The pinned AshAuthentication dependency has published advisories that the isolated oracle never exercises. #adr(4)])
    #points([The pinned sources, per-source normalization, outcome classification, exclusions, run command, and last receipt are retained in the #lnk("../../ORACLE.md")[oracle reference]. Its measurement counterpart is the #lnk("../../BENCHMARKS.md")[benchmark reference].])
  ])

  #section(title: "Benchmarks", lead: "Benchmarks describe measured throughput and latency on one recorded host. They never gate a change.", body: [
    #md-table(3, (
      [Workload], [Measurement], [Policy],
      [MIME preparation], [A text and HTML alternative with a 4096-byte attachment; three repetitions of 1000 messages after 100 warmup operations], [Public message API only],
      [Memory authentication], [500 issue-and-verify operations per repetition after 100 warmup operations; capacity for 100000 retained challenges], [Local serialized store],
      [PostgreSQL authentication], [120 issue-and-verify operations per repetition at concurrency 1, 8, and 24 after 24 warmup operations; a pool of 24 connections], [Caller-owned pool],
      [Same-challenge contention], [24 simultaneous verifications of one new challenge per repetition; one acceptance and 23 refusals are required], [Refusals never count as authentications],
    ))
    #points([Every run starts from an empty database. Samples include every outcome, infrastructure failures are counted separately and fail the command after the report is preserved, and refusals never count as authentications.], [A run retains every observed latency and outcome with its host, tool versions, workload configuration, and a source digest that includes uncommitted files. The command imposes no throughput or latency threshold, because host load, scheduler count, database settings, and warm caches affect results. #adr(5)])
    #points([The method, run command, limits, and dated results of the last recorded run are retained in the #lnk("../../BENCHMARKS.md")[benchmark reference]. Its correctness counterpart is the #lnk("../../ORACLE.md")[oracle reference].])
  ])

  #section(title: "Usage examples", lead: "Documented usage is runnable code that the gate executes.", body: [
    #points([Each usage topic is one runnable module in the separate consumer: constructing a message, acting on each delivery outcome, testing an email flow, mounting the development mailbox, verifying a native subject with recovery, and verifying over PostgreSQL. The Postmark adapter carries its own example against a scripted peer. #adr(9)], [Every example shows ordinary use, a typed refusal, and recovery where one exists. Examples need no credentials, live provider, or existing database. The PostgreSQL example runs against a #term("term-disposable-cluster").], [The README keeps a short usage section that mirrors the first examples and links the rest. No standalone prose guide exists, and an API change updates its example in the same change.])
  ])

  #section(title: "Continuous integration", lead: "CI runs the native, formatting, design, and oracle checks. It runs benchmarks only on explicit dispatch.", body: [
    #points([The fast gate checks formatting, compiles, and tests the package, both adapters, and the consumer including every usage example, then runs the native protocol and database suites. Every database suite receives a new #term("term-disposable-cluster") and uses no existing database or live provider.], [CI requires the native checks, repository formatting, design integrity, and the pinned oracle comparisons. The benchmark workflow runs only when dispatched and imposes no machine-dependent threshold.], [The consumer and Postmark adapter use sibling checkouts of Warden, Sinal, and HTTP Gun. A #term("term-sibling-revision-pin") records each clean revision, and the checkout action validates every pin and disables persisted checkout credentials. #adr(6)], [Cold builds reach GitHub, Nix binary caches, and Hex to fetch the locked toolchain and dependencies, and the oracle suite fetches pinned Git revisions. Tests then communicate only with local peers.], [CI restores no shared compiled dependency cache. Lock files and oracle source checks remain authoritative.], [Failed jobs retain their logs and available machine-readable receipts. Native and oracle artifacts expire after fourteen days and benchmark observations after thirty. No credential, database data, or authentication answer belongs in an artifact.])
  ])

  #section(title: "Browser evidence", lead: "A real Chromium session exercises cookie navigation policy that HTTP-level tests cannot.", body: [
    #points([Chromium submits the issue form, opens a link from a separate localhost webmail origin into the loopback application, follows the clean confirmation redirect, submits the rendered CSRF form, and checks the authenticated session and its rotated cookie.], [A database assertion between preview and POST proves that navigation did not consume the challenge.], [The same session opens the mailbox inbox and a message detail page and proves that hostile scripts, forms, images, frames, and refresh markup neither execute nor request a sign-in URL. A missing browser fails the check.])
  ])
]
