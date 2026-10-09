# Correio

- Correio provides transactional email and passwordless verification for Gleam on Erlang.
- Applications own accounts, templates, delivery scheduling, browser policy, and sessions.
- Messages work with SMTP, Postmark, or an explicitly owned capture adapter. Passwordless verification works independently with memory or PostgreSQL storage.
- This checkout is version `0.1.0`; it has not been published to Hex.

## Construct and send email

```gleam
import correio/address
import correio/delivery
import correio/message
import correio/smtp

pub fn send_welcome() -> delivery.Outcome {
  let assert Ok(from) = address.parse("hello@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) = message.new(
    from,
    to,
    "Welcome",
    message.Alternative("Welcome aboard.", "<p>Welcome aboard.</p>"),
  )
  let assert Ok(transport) = smtp.starttls("smtp.example.com", 587)
  smtp.send(transport, mail)
}
```

- The assertions above validate fixed configuration. Parse user input through ordinary `Result` handling.
- Add recipients, reply-to, custom headers, attachments, and an explicit envelope sender through `correio/message`.
- `smtp.credentials` supplies credentials to a TLS configuration. `smtp.deadline`, `smtp.trust_roots`, and `smtp.limits` configure bounded exchanges.
- `delivery.Sender` is a function from `Message` to `Outcome`. Inject `smtp.sender`, `correio_postmark.sender`, or `capture.sender` where the application needs delivery.
- `Accepted` means that the provider accepted the submission. It does not mean that the message reached an inbox.
- `NotSent` means that submission did not occur. `Rejected` means that the provider refused the submission. `OutcomeUnknown` means that it may have occurred.
- Correio does not automatically retry email. Retrying `OutcomeUnknown` can deliver a duplicate.
- `delivery.describe` returns a redacted description. Message projections intentionally expose content to the application.

## Test an application email flow

```gleam
import correio/capture
import correio/testing

let assert Ok(outbox) = capture.start(100)
let assert Ok(checkpoint) = capture.checkpoint(outbox)
// Inject capture.sender(outbox), then trigger your application's flow.
let assert Ok(mail) = testing.await(
  checkpoint,
  matching: testing.to(recipient),
  timeout_ms: 1000,
)
// Inspect message.view(mail).body and drive your application intentionally.
let assert Ok(Nil) = capture.stop(outbox)
```

- Record the checkpoint before triggering the flow. Earlier messages cannot satisfy the helper, including after a clear. Matching includes normalized To, Cc, and Bcc envelope mailboxes.
- `testing.await` returns the earliest retained match without consuming it. A zero timeout inspects once with a bounded one-second capture query. Positive waits accept deadlines through 60 seconds; predicate execution time and runtime scheduling remain caller-owned. Timeout, invalid duration, and capture failure are distinct errors.
- Give each parallel test its own capture, or match an application correlation field in a custom predicate. A checkpoint alone does not distinguish concurrent messages sent to the same recipient.
- The optional [`correio_mailbox`](adapters/correio_mailbox) package provides a read-only HTTP handler for an explicitly enabled development route. Inject the same capture into the sender and mailbox. Your application owns its HTTP server and access policy.
- The UI shows the latest fifty messages, full metadata, plain text, original HTML source, and a restricted formatting preview. It never automatically opens message URLs.
- Try the complete local flow without PostgreSQL or credentials:

```sh
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```

## Verify a native application subject

```gleam
import correio/passwordless
import correio/passwordless/memory

pub type AccountId {
  AccountId(Int)
}

pub fn service(key: BitArray) {
  let assert Ok(runtime) = memory.start(1000)
  let assert Ok(auth) = passwordless.new(
    memory.store(runtime),
    "example-app",
    "login",
    key,
  )
  #(runtime, auth)
}
```

- Supply a stable application secret of 32–4096 cryptographically random bytes. Never use a literal demonstration key in a deployed application.
- `passwordless.issue(auth, AccountId(42), destination, MagicLink)` returns an opaque challenge. `EmailCode(8)` selects an eight-digit code.
- `challenge_id`, `challenge_answer`, and `challenge_expires_at` expose the values needed to compose an email. Issuing a challenge does not send email.
- `passwordless.verify(auth, id, destination, answer)` returns opaque `Verified(AccountId)` evidence after confirmed consumption. The application checks account policy and publishes its own session.
- Destinations match exactly. The application supplies its trusted current destination; Correio does not infer account identity or normalize account records.
- Defaults are ten minutes, five failed attempts, and one day of receipt retention beyond expiry. `with_policy` changes these bounds explicitly.
- A challenge has one successful verification command. Another independent verification is refused even when it supplies the correct answer.
- `IssueUnknown`, `VerifyUnknown`, and `RevokeUnknown` carry opaque recovery handles. Call their corresponding `recover_*` function to resolve the original operation.
- Recovery preserves the original expiry and authentication time. It does not create a new opportunity or a second consumption.
- Recovery handles contain live store callbacks and have no stable persistence format. Applications own any durable recovery protocol needed across application restarts.
- Retain confirmed evidence when session publication fails. Retry application session publication with `verification_id` as an idempotency identity; do not verify the consumed answer again.
- `memory.stop(runtime)` waits for the local runtime to stop. Memory state is bounded and disappears on restart. Use the PostgreSQL adapter for shared durable authority.

## Packages and example

| Package                                         | Responsibility                                                  | Runtime owner                                                    |
| ----------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------- |
| `correio`                                       | Message values, MIME, SMTP, capture, verification, memory store | Caller starts capture and memory; SMTP owns one bounded exchange |
| [`correio_postgres`](adapters/correio_postgres) | Atomic durable challenge transitions and cleanup                | Caller owns the named Pog pool                                   |
| [`correio_postmark`](adapters/correio_postmark) | Typed Postmark email submission                                 | Caller owns the HTTP Gun client and pool                         |
| [`correio_mailbox`](adapters/correio_mailbox)   | Read-only development inbox and safe formatting preview         | Caller owns capture, HTTP server, and development access         |
| [`passwordless_demo`](apps/passwordless_demo)   | Local browser flow and application-native Warden composition    | Example owns accounts, browser state, and sessions               |

- The example uses an initiating-browser binding, intentional POST confirmation, origin and CSRF checks, session rotation, explicit cross-device codes, and session-publication recovery.
- Warden OIDC identity and Correio email evidence remain distinct authentication methods in the application's principal type. Correio has no Warden runtime dependency.
- The core package uses Hex dependencies. The Postmark adapter and example use sibling checkouts of HTTP Gun, Sinal, and Warden. CI records their exact revisions in `sibling-revisions.txt`.

## Supported scope

- Addresses support ASCII dot-atom local parts and domain names. Local-part case is preserved; domain case is normalized. Unicode display names are supported. Quoted local parts, address literals, and SMTPUTF8 mailboxes are refused.
- MIME supports text, HTML, alternatives, inline resources, and binary attachments. `message/*` and `multipart/*` attachments are refused because they require additional encoding semantics.
- Custom header values preserve ASCII syntax, including structured unsubscribe headers. Non-ASCII custom values and physical header lines over 998 bytes are refused. Subjects and display names support Unicode.
- Default admission limits are 100 recipients, 50 custom headers, 8 KiB per header value, 1 MiB of body content, 10 MiB per attachment, and 25 MiB for submission preparation. A conservative encoded-size estimate can refuse a message below the final wire-size limit.
- SMTP requires verified STARTTLS or implicit TLS. Plaintext exists only through the explicitly named loopback test constructor. A refused recipient aborts submission before DATA.
- Passwordless policy allows validity up to 24 hours, 1–100 attempts, code lengths of 6–10 digits, and retention up to 30 days. Store time is authoritative; deployments must maintain a trustworthy clock.
- Durable outboxes, bounce processing, provider reconciliation, account linking, inbound email, WebAuthn, and TOTP are outside this package.

## Development and evidence

```sh
nix develop -c scripts/check
nix develop -c scripts/e2e
nix develop -c scripts/oracles
nix develop -c scripts/benchmark
nix flake check
```

- `scripts/check` runs the package, adapter, and separate-consumer checks. `scripts/e2e` runs native protocol, database, and browser evidence.
- The full native harness runs on Linux. `scripts/browser-e2e` runs Chromium through an actual webmail-to-login navigation, intentional confirmation form submission, and session rotation.
- Tests use local scripted peers and disposable PostgreSQL. They require no provider credentials or existing database.
- [Oracle comparisons](oracles/README.md) execute pinned Swoosh, Phoenix, and AshAuthentication sources. Each comparison states its normalization and limits.
- [Benchmarks](benchmarks/README.md) retain workload configuration, repetitions, latency samples, outcome counts, host details, and the tested source digest. They do not impose a machine-independent throughput threshold.
- [Design](docs/design/design.typ), [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md), and [decision rationale](docs/adr/0001-separate-delivery-and-authentication.md) define the package's ownership and contracts.
- Code is licensed under [Apache 2.0](LICENSE). Retained upstream oracle files preserve their MIT licenses under `oracles/licenses`.
