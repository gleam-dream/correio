# Correio

- Correio provides transactional email and passwordless verification for Gleam on Erlang.
- Applications own accounts, templates, delivery scheduling, browser policy, and sessions.
- Messages work with SMTP, Postmark, or an explicitly owned capture adapter. Passwordless verification works independently with memory or PostgreSQL storage.
- Version `0.1.0` is pre-release and not yet published to Hex.

## Construct email

<!-- prettier-ignore-start -->

<!-- snips: apps/passwordless_demo/src/usage/compose_message.gleam#compose-message -->
```gleam
// Parse addresses with ordinary `Result` handling. A display name is optional.
let assert Ok(from) =
  address.parse("hello@example.com")
  |> result.try(address.named(_, "Correio Store"))
let assert Ok(to) = address.parse("reader@example.com")
let assert Ok(copy) = address.parse("copy@example.com")
let assert Ok(audit) = address.parse("audit@example.com")
let assert Ok(support) = address.parse("support@example.com")
let assert Ok(bounce) = address.parse("bounces@example.com")

let assert Ok(mail) =
  message.new(
    from,
    to,
    "Your order",
    message.Alternative(
      "Your order is ready.",
      "<p>Your order is ready.</p><img src=\"cid:logo\">",
    ),
  )
```

<!-- prettier-ignore-end -->

- The assertions above validate fixed configuration. Parse user input through ordinary `Result` handling.
- Add recipients, reply-to, custom headers, attachments, and an explicit envelope sender through `correio/message`.
- `delivery.Sender` is a function from `Message` to `Outcome`. Inject `smtp.sender`, `correio_postmark.sender`, or `capture.sender` where the application needs delivery.
- `Accepted` means that the provider accepted the submission, not that the message reached an inbox. `NotSent`, `Rejected`, and `OutcomeUnknown` mean that submission did not occur, was refused, or may have occurred.
- Correio does not retry email, because retrying `OutcomeUnknown` can deliver a duplicate.

## Test an application email flow

Here `welcome` is application code that accepts an injected sender and builds its message.

<!-- prettier-ignore-start -->

<!-- snips: apps/passwordless_demo/src/usage/capture_flow.gleam#capture-flow -->
```gleam
let assert Ok(recipient) = address.parse("reader@example.com")
let assert Ok(other) = address.parse("someone-else@example.com")

// Give each test its own capture so parallel tests cannot see each other.
let assert Ok(outbox) = capture.start(100)
let sender = capture.sender(outbox)

// Mail sent before the checkpoint can never satisfy the helper.
let assert delivery.Accepted(_) = welcome(sender, other)
let assert Ok(checkpoint) = capture.checkpoint(outbox)

let assert delivery.Accepted(_) = welcome(sender, recipient)
let assert Ok(mail) =
  testing.await(checkpoint, matching: testing.to(recipient), timeout_ms: 1000)
assert message.view(mail).subject == "Welcome"
assert message.view(mail).body
  == message.Text("Open https://app.example.test/start to begin.")

// Awaiting mail that never arrives is a bounded, typed failure.
assert testing.await(checkpoint, matching: testing.to(other), timeout_ms: 50)
  == Error(testing.TimedOut)
assert testing.await(checkpoint, matching: testing.to(other), timeout_ms: -1)
  == Error(testing.InvalidTimeout)

// Inspection never consumes: since() returns the post-checkpoint messages.
let assert Ok(after) = capture.since(checkpoint)
assert after != []
let assert Ok(Nil) = capture.stop(outbox)
```

<!-- prettier-ignore-end -->

- Record the checkpoint before triggering the flow. Earlier messages cannot satisfy the helper.
- Give each parallel test its own capture, or match an application correlation field in a custom predicate.
- The optional [`correio_mailbox`](adapters/correio_mailbox) package adds a read-only development inbox for the same capture.
- Try the complete local flow without PostgreSQL or credentials:

```sh
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```

## Verify a native application subject

The runnable example defines `AccountId(Int)` and a demonstration key; supply your own stable secret in an application.

<!-- prettier-ignore-start -->

<!-- snips: apps/passwordless_demo/src/usage/passwordless_memory.gleam#passwordless-service -->
```gleam
let assert Ok(runtime) = memory.start(1000)
let assert Ok(auth) =
  passwordless.new(memory.store(runtime), "example-app", "login", demo_key)
let assert Ok(auth) = passwordless.with_policy(auth, 60_000, 3, 3_600_000)
```

<!-- prettier-ignore-end -->

- Supply a stable application secret of 32–4096 cryptographically random bytes. Never use a literal demonstration key in a deployed application.
- `passwordless.issue(auth, AccountId(42), destination, MagicLink)` returns an opaque challenge, and `EmailCode(8)` selects an eight-digit code. Issuing a challenge does not send email.
- `passwordless.verify(auth, id, destination, answer)` returns opaque `Verified(AccountId)` evidence after confirmed consumption. The application checks account policy and publishes its own session.
- `IssueUnknown`, `VerifyUnknown`, and `RevokeUnknown` carry recovery handles. Call the corresponding `recover_*` function to resolve the original operation.
- Retain confirmed evidence when session publication fails, and retry publication with `verification_id` as the idempotency identity.
- Memory state is bounded and disappears on restart. Use the PostgreSQL adapter for shared durable authority.

## Runnable examples

Every topic below is code that compiles and runs in the repository gate, so it stays current with the library. The snippets above are excerpts of the message, capture and passwordless examples.

| Topic                                  | Example                                                                                 |
| -------------------------------------- | --------------------------------------------------------------------------------------- |
| Construct a message                    | [`compose_message`](apps/passwordless_demo/src/usage/compose_message.gleam)             |
| Deliver and act on each outcome        | [`delivery_outcomes`](apps/passwordless_demo/src/usage/delivery_outcomes.gleam)         |
| Test an application email flow         | [`capture_flow`](apps/passwordless_demo/src/usage/capture_flow.gleam)                   |
| Mount the development mailbox          | [`development_mailbox`](apps/passwordless_demo/src/usage/development_mailbox.gleam)     |
| Verify a native subject, with recovery | [`passwordless_memory`](apps/passwordless_demo/src/usage/passwordless_memory.gleam)     |
| Verify over PostgreSQL                 | [`passwordless_postgres`](apps/passwordless_demo/src/usage/passwordless_postgres.gleam) |
| Send through Postmark                  | [`usage_test`](adapters/correio_postmark/test/usage_test.gleam)                         |

## Packages and example

| Package                                         | Responsibility                                                  |
| ----------------------------------------------- | --------------------------------------------------------------- |
| `correio`                                       | Message values, MIME, SMTP, capture, verification, memory store |
| [`correio_postgres`](adapters/correio_postgres) | Atomic durable challenge transitions and cleanup                |
| [`correio_postmark`](adapters/correio_postmark) | Typed Postmark email submission                                 |
| [`correio_mailbox`](adapters/correio_mailbox)   | Read-only development inbox and safe formatting preview         |
| [`passwordless_demo`](apps/passwordless_demo)   | Local browser flow and application-native Warden composition    |

- The core package uses Hex dependencies. The Postmark adapter and example depend on the unpublished [HTTP Gun](https://github.com/gleam-dream/http_gun) and [Warden](https://github.com/gleam-dream/warden) as Git dependencies on `main`; their `manifest.toml` files lock the resolved revisions.

## Development

```sh
nix develop -c scripts/check
nix develop -c scripts/e2e
nix develop -c scripts/oracles
nix develop -c scripts/benchmark
```

- Tests use local scripted peers and a disposable PostgreSQL. They need no provider credentials or existing database.
- [Oracle comparisons](docs/ORACLE.md) record their pinned upstream sources and limits, and [benchmarks](docs/BENCHMARKS.md) record their method and dated results. Each links to the other.
- The [design](docs/design/design.typ) defines each context's contracts and limits. Its [context map](docs/CONTEXT-MAP.md), [coverage map](docs/COVERAGE.md), and [decision records](docs/adr) hold vocabulary, ownership, and rationale.
- Code is licensed under [Apache 2.0](LICENSE). Oracle inputs are fetched from their upstream projects at run time and are not committed.
