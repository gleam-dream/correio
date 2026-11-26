# Migrating from Correio 0.1 to 0.2

Correio 0.2.0 is a breaking release. The adapters `correio_postgres`, `correio_postmark`, and `correio_mailbox` are released next and build on this core version, so their migration is part of this guide.

This guide lists the changes in the order of how many applications they affect. If you only use `smtp`, `capture`, and `passwordless` with the PostgreSQL store, read sections 2, 3, and 5.

## 1. The memory store runs only under your supervisor

Affects every application that uses `correio/passwordless/memory`.

**What changed.** `memory.start`, `memory.start_with_clock`, `memory.start_with_cleanup_interval`, `memory.stop`, `memory.Runtime`, and `memory.StartError` are removed. The store is now a child of your supervisor, registered under a `process.Name` that you create once.

**Why.** A store started by an ordinary process stopped with that process, and a store that failed left every caller holding a handle to a dead process. A name lets one store port survive restarts.

**Before.**

```gleam
let assert Ok(runtime) = memory.start(1000)
let assert Ok(auth) =
  passwordless.new(memory.store(runtime), "my-app", "login", key)
// ...
let assert Ok(Nil) = memory.stop(runtime)
```

**After.**

```gleam
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor

let challenges = process.new_name("my_app_challenges")
let assert Ok(config) = memory.new(challenges, 1000)
let assert Ok(_) =
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(memory.supervised(config))
  |> supervisor.start
let assert Ok(auth) =
  passwordless.new(memory.store(challenges), "my-app", "login", key)
```

Steps:

1. Create the name once at application start, never from request input. Pass it to both `memory.supervised` and `memory.store`.
2. Replace `memory.start(capacity)` with `memory.new(name, capacity)`. It returns `Error(InvalidCapacity)` for a capacity outside 1 to 1,000,000, before any process starts. Chain `memory.with_clock(config, clock)` or `memory.with_cleanup_interval(config, milliseconds)` where you used the old variants.
3. Add `memory.supervised(config)` to the supervisor you already run, or start a small one as above.
4. Build the store with `memory.store(name)`. It takes the name, not a runtime value.
5. Delete the `memory.stop` call and the field that held the runtime. Stop the store by stopping its supervisor.

The core package now depends on `gleam_otp` and `gleam_erlang` (each `>= 1.0.0 and < 2.0.0`). Run `gleam deps update correio` after raising the Correio version, naming each installed adapter as well (section 2).

Behavior to know:

- A store that fails restarts empty under the same name, and every store port built with `memory.store` reaches the replacement. A command sent while no process holds the name returns `Unavailable`. A command in progress when the store fails returns `Unknown`.
- A full store now admits a new challenge by discarding a row past retention or, failing that, the longest-expired challenge that was never consumed. Before, a store full of expired challenges could refuse issuance indefinitely. A consumption receipt keeps its slot for its whole retention, so rate-limit issuance in your application.
- The store removes rows past retention on its own timer, once a minute by default.
- The store's time never goes below the latest value it has sampled, including with an injected `with_clock` function. A clock that moves backward can no longer revive a challenge the store discarded.

## 2. Adapter dependency ranges

Affects every application that installs an adapter.

**What changed.** The adapters build on Correio 0.2. A dependency range of `>= 0.1.0 and < 0.2.0` no longer resolves with the new adapters.

**Before.**

```toml
correio = ">= 0.1.0 and < 0.2.0"
```

**After.**

```toml
correio = ">= 0.2.0 and < 0.3.0"
```

Change the range in your `gleam.toml`, then run `gleam deps update correio correio_postmark` (a project that installs the Postmark adapter) and commit `manifest.toml`. Add each adapter your project installs to that command instead, using the dependency name from its install line: a locked adapter at its 0.1 revision requires Correio 0.1 and blocks the update unless it is unlocked too. Adapters install from Git subdirectories until they are on Hex; the install lines in each adapter README show the current form.

`correio_postmark` 0.3.0 requires HTTP Gun 0.4. Version 0.2.0 required `http_gun >= 0.1.0 and < 0.2.0`, so it could not resolve in an application that uses any other gleam-dream library on HTTP Gun 0.4. Its configuration takes an `http_gun.Client` and an `http_gun/redaction.Redaction`, so the application's own HTTP Gun client moves to 0.4 with it:

```toml
http_gun = ">= 0.4.0 and < 0.5.0"
correio_postmark = { git = "https://github.com/gleam-dream/correio.git", ref = "correio_postmark-v0.3.0", path = "adapters/correio_postmark" }
```

Run `gleam deps update http_gun correio_postmark`, then follow the [HTTP Gun migration guide](https://github.com/gleam-dream/http_gun/blob/main/docs/MIGRATION.md) for the code that starts and configures the client. The adapter's own calls keep their behavior: `postmark.deadline` still bounds each submission, a submission that passes that deadline after its request may have been written returns `OutcomeUnknown`, and every status keeps its mapping.

## 3. Receipts carry the Message-ID

Affects code that matches or builds a `delivery.Receipt`, such as test fakes and custom senders.

**What changed.** `delivery.Receipt` has a new first field, `message_id: Option(String)`.

**Why.** The renderer writes a random `Message-ID` into every message and used to discard it. A bounce or reply carries that identifier, so an application can now match it to the send.

**Before.**

```gleam
delivery.Accepted(delivery.Receipt(Some("provider-id"), recipients))
```

**After.**

```gleam
delivery.Accepted(delivery.Receipt(
  message_id: None,
  provider_id: Some("provider-id"),
  recipients: recipients,
))
```

- Code that only reads `receipt.provider_id` or `receipt.recipients` needs no change.
- Code that builds or matches a receipt by position adds the first field. Use labels, as above.
- SMTP and capture receipts set `message_id` to the header value written into the message, angle brackets included. A Postmark receipt has `message_id: None`, because Postmark writes its own header. Its identifier stays in `provider_id`.
- The `Message-ID` identifies a send for matching. It does not deduplicate.

## 4. Postmark: a refused token is an authentication failure

Affects applications that use `correio_postmark` and branch on `Rejected(Permanent)`.

**What changed.** HTTP 401 and 403 from Postmark return `NotSent(AuthenticationFailed)` instead of `Rejected(Permanent)`, whatever the size of the response body. Every other status keeps its mapping.

**Why.** Postmark refuses a missing or wrong server token before it processes the message, so nothing was submitted and no recipient was judged. A rotated token looked like an undeliverable address.

**Before.**

```gleam
case send(message) {
  delivery.Rejected(delivery.Permanent) -> suppress_recipients(message)
  // ...
}
```

**After.** Handle the credential failure as a configuration fault. `Rejected(Permanent)` carries no detail on which recipient was refused, so do not suppress recipients on every `Rejected(Permanent)`. Record the outcome and decide by your own policy.

```gleam
case send(message) {
  delivery.NotSent(delivery.AuthenticationFailed) -> alert_operator()
  delivery.Rejected(delivery.Permanent) -> record_permanent_rejection(message)
  // ...
}
```

Correct the token before retrying, as with any `NotSent` outcome.

## 5. PostgreSQL: definite failures are faults

Affects applications that use `correio_postgres`.

**What changed.** The store used to return `Unknown` (with a recovery handle) for failures that stored nothing. It now reports them as definite faults:

| Situation                                                                                                                                                  | Before        | After              |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ------------------ |
| Pool has no available connection                                                                                                                           | `Unknown`     | `Unavailable`      |
| Server refused a statement inside a transaction and rolled back: data, constraint, or schema error (SQLSTATE class 22, 23, or 42, such as a missing table) | `Unknown`     | `IncompatibleData` |
| Same, for lock, resource, and cancellation errors                                                                                                          | `Unknown`     | `Unavailable`      |
| Missing table on `verify` and `revoke`                                                                                                                     | `Unavailable` | `IncompatibleData` |

**Why.** `Unknown` tells the application that a mutation may have been stored and that it must keep a handle and recover. For these failures the answer is that nothing happened.

**Steps.**

1. Do not expect a recovery handle for these failures. `IssueFailed`, `VerifyFailed`, and `RevokeFailed` carry the fault, and a retry is a new operation.
2. Treat `IncompatibleData` as a deployment fault: run `migrate`, or fix the schema or stored data.
3. Keep your handling of `IssueUnknown`, `VerifyUnknown`, and `RevokeUnknown`. They remain for a failed begin, commit, or rollback, a lost reply to `cleanup` or `migrate`, and a driver exception.

## 6. Recovery handles are bound to a store incarnation

Affects applications that keep an `IssueUnknown` handle across a memory store restart.

**What changed.** Each memory store process starts with a new unguessable incarnation, and every issue command carries the incarnation it was stamped with. A recovery handle from before a restart now ends in `IssueFailed(IssueExpired)`. Verify and revoke handles find no row and are refused as `Missing`.

**Why.** A restarted store lost every row, including consumption receipts. Recovering an old issue handle would have inserted the challenge as active again, and the same link could sign a user in twice.

**What to do.** Treat `IssueExpired` from `recover_issue` as the end of that operation and issue a new challenge if the user still needs one. The PostgreSQL store keeps its rows across restarts and has one incarnation, so its handles remain recoverable.

## 7. Rendering and text encoding

Affects code that calls `correio/mime` directly, and anything that compares raw message bytes.

**What changed.**

- `mime.render` and `mime.render_with_limits` return `Result(mime.Rendered, MessageError)` instead of `Result(BitArray, MessageError)`.
- Printable ASCII subjects, display names, and text bodies are emitted readable instead of base64. A text part uses `7bit` when its lines are printable ASCII within 998 bytes, quoted-printable or base64 otherwise. Non-ASCII content and attachments keep their previous encoding.
- Text line breaks are emitted as CRLF. A body written with LF decodes with CRLF. Attachment bytes are never altered.

**Why.** A plain sign-in mail went out with a base64 subject, From name, and body, a pattern that content filters score. Raw messages were also unreadable in logs.

**Before.**

```gleam
let assert Ok(bytes) = mime.render(message)
```

**After.**

```gleam
let assert Ok(rendered) = mime.render(message)
let bytes = rendered.bytes
let message_id = rendered.message_id
```

Applications that only send through `smtp`, `capture`, or an adapter need no change. Update tests that assert the exact bytes or the base64 form of an ASCII message.

## 8. Custom store authors

Affects code that implements `correio/passwordless/store.Store`. Applications that only use `passwordless` are unaffected.

**What changed.**

- `Store.now` returns `store.Instant(milliseconds: Int, incarnation: String)` instead of an `Int`.
- `store.Issue` has a new last field, `incarnation: String`.

**What to do.**

1. Return the store's incarnation together with its time from `now`.
2. Refuse an `Issue` whose incarnation differs from the store's current one, with `IssueExpired`.
3. A store whose rows survive restarts uses one constant incarnation. A store that loses rows on restart creates a new unguessable incarnation each time it starts.

The reasons are in [ADR 0012](https://github.com/gleam-dream/correio/blob/main/docs/adr/0012-memory-store-runs-under-the-application-supervisor.md).

## Checklist

- [ ] Raise `correio` to `>= 0.2.0 and < 0.3.0`, and run `gleam deps update correio` with the names of your installed adapters.
- [ ] Move the memory store under your supervisor (section 1).
- [ ] Add `message_id:` to every `delivery.Receipt` you build or match (section 3).
- [ ] With `correio_postmark` 0.3, raise `http_gun` to `>= 0.4.0 and < 0.5.0` (section 2).
- [ ] Handle `NotSent(AuthenticationFailed)` from Postmark (section 4).
- [ ] Stop expecting recovery handles for definite PostgreSQL failures (section 5).
- [ ] Treat `IssueExpired` from `recover_issue` as final (section 6).
- [ ] Update `mime.render` callers and byte-exact test assertions (section 7).
