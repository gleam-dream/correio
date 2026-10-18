# Correio development mailbox

A read-only HTTP handler that lists and shows the messages in a caller-owned capture. Behavior, limits, and the preview rules are specified in the [delivery design](../../docs/design/delivery/design.typ).

Runnable example: [`development_mailbox`](../../apps/passwordless_demo/src/usage/development_mailbox.gleam), run by the repository gate.

## Mount

```gleam
import correio/capture
import correio_mailbox

let assert Ok(outbox) = capture.start(100)
let send = capture.sender(outbox)
let assert Ok(mailbox) = correio_mailbox.new(outbox, at: "/dev/mailbox")
// Inject send into your application's delivery dependency.
// In your development router, pass the original Gleam HTTP request:
let response = correio_mailbox.handle(mailbox, request)
```

- Enable the route only in a development environment. Captured mail exposes secrets and blind recipients, and the application owns access control and the server.
- No HTTP listener starts in this package.

## Try it

```sh
# From the Correio repository root; no database or credentials needed.
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```
