#import "../.render/designlib.typ": *
#let title = [Passwordless]
#let accent = "violet"
#let body = [
  #section(title: "Foundation", lead: "Passwordless verification proves possession of an email address for one explicit purpose. It does not decide account or session policy.", body: [
    #goal(title: "Verify possession with one confirmed consumption")[A caller authenticates an application-native subject through a short-lived magic link or email code whose consumption is atomic across concurrent callers.]
    #no-goal(title: "Decide accounts, sessions, or permissions")[Account lookup, registration, account linking, account discovery responses, permission decisions, and session publication remain application responsibilities.]
    #invariant(title: "One command consumes a challenge", enforcement: "mechanism")[Only a confirmed atomic consumption yields verification evidence. Repeating the same recovery command can recover its receipt without authorizing a second consumption.]
    #invariant(title: "Expiry is checked at the serialization boundary", enforcement: "mechanism")[The store samples authoritative time after acquiring the challenge's serialization authority. A pre-lock clock sample cannot authorize an expired challenge.]
    #principle(title: "Make illegal authentication states unrepresentable")[Opaque challenge and evidence values cannot be constructed through the public API. Closed results separate refusal from infrastructure failure.]
  ])

  #pending-ledger(
    pending-entry(
      title: "Recovery, retention, and revocation rules are unchecked",
      kind: "verify",
      since: "2026-10-17",
    )[The defaults, ranges, and capacities were compared with the code. The recovery, retention, revocation, and clock-discipline rules carried over from retired guides remain unchecked against the code.],
  )

  #section(title: "System at a glance", lead: "The application issues and verifies challenges through one service over an injected store. The service never sends email.", visual: diagram(
    altitude: "L3", viewpoint: "runtime", title: "Passwordless components",
    nodes: (
      (id: "app", label: "Application", sub: "subjects, destinations, sessions", kind: "external-system"),
      (id: "service", label: "Challenge service", kind: "component", tint: "violet"),
      (id: "memory", label: "Memory store", kind: "component", tint: "violet"),
      (id: "postgres", label: "PostgreSQL store", kind: "component", tint: "violet"),
      (id: "cluster", label: "PostgreSQL cluster", kind: "database"),
    ),
    edges: (
      (from: "app", to: "service", relation: "call", label: "issue, verify, revoke, recover"),
      (from: "service", to: "memory", relation: "call", label: "atomic transition"),
      (from: "service", to: "postgres", relation: "call", label: "atomic transition"),
      (from: "postgres", to: "cluster", relation: "call", label: "row-locked transaction"),
      (from: "service", to: "app", relation: "dataflow", label: "verification evidence"),
    ), caption: [Issuing a challenge does not deliver it. The application composes the answer into a message with the delivery context.]), body: [
    #md-table(3, (
      [Package or module], [Owned contract], [Effect owner],
      [correio/passwordless], [Challenge generation, bindings, and evidence], [Injected semantic store],
      [correio/passwordless/store], [The challenge store port and its operation values], [Adapter authors],
      [correio/passwordless/memory], [Bounded local serialized rows], [Explicitly started local runtime],
      [adapters/correio_postgres], [Durable atomic transitions and cleanup], [Caller-owned named Pog pool],
    ))
  ])

  #section(title: "Challenge verification", lead: "A challenge proves possession for one explicit purpose. It does not decide account or session policy.", body: [
    #answers(title: "Challenge service",
      responsibility: [Issue and verify a #term("term-challenge") for a caller-owned subject and configured scope.],
      interface: [A validated service over a typed #term("term-challenge-store"); issue, verify, revoke, and recovery operations; opaque challenge and #term("term-verification-evidence") values with explicit projections.],
      interactions: [The application chooses subjects and destinations and delivers secrets. Store adapters serialize challenge transitions and sample time. Cryptographic randomness and keyed verification use OTP primitives.],
      invariants: [A challenge binds subject, scope, purpose, destination, secret verifier, expiry, and attempt budget. A verification result exists only after confirmed consumption. No user enumeration or account linking occurs inside the package.],
      failure: [Malformed, missing, expired, revoked, exhausted, and already consumed challenges are refused. Unavailable storage and uncertain mutation are distinct infrastructure outcomes.],
    )
    #points([Magic-link secrets contain at least 256 bits of cryptographic randomness and use URL-safe encoding. Email codes use unbiased cryptographic generation with a configurable length. Code verifiers are keyed hashes bound to the challenge and service scope, so a database reader cannot enumerate codes without the application key.], [Raw answers are never persisted in challenge rows. A challenge identifier is independent of its answer and is not authentication authority. The application supplies a stable secret of 32 through 4096 cryptographically random bytes.], [The challenge service captures one store, scope, purpose, signing key, and validated policy. Configuration is validated before any effect. Defaults use a ten-minute validity interval, five failed attempts, and one day of terminal receipt retention beyond validity.], [Validity ranges from 1 millisecond to 24 hours, attempts from 1 to 100, email codes from 6 to 10 digits, and retention from 1 millisecond to 30 days. Scope, purpose, and destination are nonempty, at most 320 bytes, and exclude null and line-break characters.], [Destinations match exactly. The application supplies its trusted current destination, and the package neither infers account identity nor normalizes account records.], [Issuing a challenge exposes its identifier, answer, and expiry for message composition. The application can use a native subject type; a durable adapter requires a caller-selected codec for that type and refuses incompatible stored values explicitly.])
    #points([Each issue command has a fresh identity. An uncertain insertion recovers the same challenge without generating another answer.], [Each verification command has a fresh identity. Recovery reads or repeats only that command's atomic transition and preserves its original authentication time.], [A challenge has one successful verification command. A duplicate recovery command can return the same receipt while retention permits it. Recovery never extends the authentication lifetime or creates another consumption.], [Recovery handles contain live store callbacks and have no stable persistence format. The application owns any durable recovery protocol it needs across restarts.], [Confirmed evidence survives a failed session publication. The application retries publication with the #term("term-verification-identity") as an idempotency identity and never verifies the consumed answer again.])
    #points([Wrong answers atomically spend an attempt only on an active challenge. Exhaustion withdraws further verification. Missing or malformed identifiers cannot create rows.], [A correct answer arriving after expiry is refused even if it waited for a lock while unexpired. Secret delivery delayed beyond expiry cannot authenticate.], [Revocation serializes with consumption. A revocation that wins prevents consumption; a consumption that wins remains historical evidence, and application session invalidation remains a separate responsibility.], [Resending an existing message does not extend challenge expiry. Issuing another challenge does not revoke older challenges; applications revoke explicitly when their resend policy requires it.], [Ordinary error descriptions redact secrets. Runtime inspection and explicitly requested secret projection are outside that guarantee.])
    #state-type(id: "challenge-status", title: "Challenge status", variants: ("active", "consumed", "revoked", "exhausted", "expired"))
    #entity(id: "challenge", title: "Challenge", description: [One opportunity to prove possession.], kind: "aggregate", owner: "Challenge verification", lifecycle: "stateful", domain: "Authentication", tint: "violet")[
      #attribute(name: "Identity and binding", type: "Challenge binding", provenance: "derived")[Random identifier plus the application subject, destination, scope, and purpose captured at issue.]
      #attribute(name: "Verification policy", type: "Validity and attempt limits", provenance: "authored")[Validated service policy captured for this challenge.]
      #attribute(id: "status", name: "Status", type: "Challenge status", provenance: "derived", state-type: "challenge-status", state-machine: "challenge-lifecycle")[The result of serialized verification, expiry, or revocation.]
      #attribute(name: "Consumption receipt", type: "Optional command and authentication time", provenance: "observed")[The confirmed winning command and the time at which its authentication evidence arose.]
    ]
    #state-machine(id: "challenge-lifecycle", subject: "challenge", state-field: "status", state-type: "challenge-status", title: "Challenge consumption", accent: "violet", initial: "active", accepting: ("consumed", "revoked", "exhausted", "expired"), states: ("active", "consumed", "revoked", "exhausted", "expired"), transitions: (("active", "active", "wrong answer with attempts left"), ("active", "consumed", "correct answer before expiry"), ("active", "revoked", "revoke wins"), ("active", "exhausted", "last wrong answer"), ("active", "expired", "expiry reached")), caption: [No transition recreates an active challenge. Recovery observes the original command rather than resetting this lifecycle.])
    #points([The public lifecycle describes authentication authority. Storage represents exhaustion with zero remaining attempts and records observed expiry as a terminal status. Retention expiration can discard a consumption receipt without recreating an authentication opportunity.], [A verification command carries a fresh command identity and the original challenge binding. Failed command identities are retained within the attempt bound, so recovery of a wrong answer does not spend another attempt. Confirmed consumption stores the winning command identity and original authentication time.], [A verification receipt references one challenge and one winning command. The opaque public evidence projects only the subject, destination, scope, purpose, challenge identity, and authentication time. Recovery handles are sensitive application state; generic runtime printing is outside redacted diagnostics.])
    #behavior(title: "Concurrent verification has one winner", area: "Consumption", level: "boundary")[#given[An active challenge has a correct answer.] #given[Storage remains available, no revocation competes, and the first serialized verification occurs before expiry.] #when[Independent callers verify it concurrently.] #then[Exactly one consumption succeeds.] #then[Every other caller is refused.]]
    #behavior(title: "Expiry is checked after waiting", area: "Consumption expiry", level: "boundary")[#given[A verification waits for serialization while its challenge expires.] #when[The store obtains authority to consume it.] #then[The challenge is refused as expired.]]
    #behavior(title: "Wrong answers spend a bounded budget", area: "Attempt admission", level: "boundary")[#given[An active challenge has a finite #term("term-attempt-budget").] #when[Callers submit wrong answers concurrently.] #then[The store counts the failed attempts atomically.] #then[Exhaustion prevents subsequent authentication.]]
    #behavior(title: "Uncertain acknowledgement cannot mint evidence", area: "Storage recovery", level: "boundary")[#given[A challenge mutation may have committed without acknowledgement.] #when[The caller receives the uncertain result.] #then[The result carries #term("term-recovery") authority for the original command.] #then[Verification evidence is withheld until that command's consumption is confirmed.]]
    #behavior(title: "A correct answer for another destination is refused", area: "Destination binding", level: "boundary")[#given[An active challenge is bound to one destination.] #when[A caller verifies the correct answer with a different destination.] #then[Verification is refused.] #then[The challenge remains unconsumed.]]
  ])

  #section(title: "Storage and runtime ownership", lead: "Adapters enforce atomic semantic operations, including time and attempt accounting, rather than exposing a generic compare-and-set as sufficient evidence.", body: [
    #answers(title: "Challenge store",
      responsibility: [Serialize issue, verify, recovery, and revoke while retaining terminal receipts.],
      interface: [A generic typed store port with immutable operation inputs, closed results, explicit unavailable and unknown outcomes, and bounded cleanup.],
      interactions: [Memory storage owns explicit bounded process state. PostgreSQL storage captures a caller-owned connection pool and a subject codec.],
      invariants: [Expiry is sampled under serialization. Different challenges can progress independently. Recovery identities and secret verifiers are bound to the original challenge and scope. Cleanup cannot remove still-live authentication opportunities or receipts inside their configured retention.],
      failure: [Capacity, decoding, availability, contention deadline, and uncertain commit are explicit outcomes. A timeout never proves rollback.],
    )
    #points([The memory adapter is for local use and tests, and restart loses its data. It bounds retained rows to its configured capacity, at most one million. Its clock can be injected for deterministic tests but is sampled inside the serialized operation.], [Stopping a local runtime reports its actual completion boundary and never claims rollback of a timed-out external operation. Memory cleanup scans bounded retained state.], [Issuance reads the store's authoritative clock once to bind immutable absolute expiry and retention into its command. Insertion refuses an already expired command. Recovery cannot renew those timestamps or reinsert an expired opportunity after cleanup.], [Terminal rows remain until validity plus configured retention. Recovery checks the retention deadline even if cleanup has not run.], [The authoritative clock must be trustworthy. Observing expiry persists a terminal refusal, so a later clock rollback cannot revive that observed opportunity. A clock that moves backward before expiry is observed remains an operational clock-discipline risk.], [The application protects its signing key, database write authority, and trusted store implementation. A malicious injected store can forge receipts. Rotating to an unrelated signing key invalidates outstanding answers, so a deployment retains the original key through the intended challenge lifetime or accepts revocation.])
    #subsection(title: "PostgreSQL store")[
      #points([The constructor accepts a named Pog pool and a subject codec, never an arbitrary connection. This type boundary prevents the adapter from committing an enclosing application transaction. Pool capacity, supervision, shutdown, database availability, and clock discipline remain application responsibilities.], [Each verification locks its row, reads the database clock after acquiring the lock, applies one transition, and commits before returning evidence. A transaction records one complete transition or none. Separate pooled connections establish multi-process concurrency; one connection behind a shared test transaction does not prove it.], [A query timeout defaults to five seconds and accepts 1 through 60000 milliseconds. A timeout or missing commit acknowledgement returns an unknown outcome with a recovery handle for the same authoritative store.], [An explicit migration creates the fixed challenge table and a retention index. Migration never runs during authentication requests. The table identifiers and verifier domain are stable across package names. #adr(3)], [Schema constraints protect challenge identity, attempt bounds, legal status, and receipt consistency. Queries use parameterized values and fixed table identifiers. Timestamp columns hold integer Unix milliseconds.], [Cleanup is explicit, never a background process. Each call deletes between 1 and 1000 eligible rows ordered by the retention index and skips locked rows.], [Horizontal scale comes from independent application nodes sharing the authoritative PostgreSQL rows. Different challenges progress independently while same-challenge traffic serializes on its row.])
    ]
    #sequence(title: "Recover a committed verification", accent: "violet", participants: (
      (id: "app", label: "Application"),
      (id: "service", label: "Challenge service"),
      (id: "db", label: "PostgreSQL", shape: "database"),
    ), steps: (
      seq-msg("app", "service", [Verify answer]),
      seq-msg("service", "db", [Lock, check time, consume]),
      seq-msg("service", "db", [Commit]),
      seq-note("db", [Committed; reply lost]),
      seq-msg("service", "app", [Unknown with recovery handle], dashed: true),
      seq-msg("app", "service", [Recover the same command]),
      seq-msg("service", "db", [Lock; confirm winning receipt]),
      seq-msg("db", "service", [Original authentication time], dashed: true),
      seq-msg("service", "app", [Verification evidence], dashed: true),
    ), caption: [Recovery confirms one consumption. Application session publication remains a separate effect.])
  ])
]
