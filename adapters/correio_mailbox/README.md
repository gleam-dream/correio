# Correio development mailbox

A read-only HTTP handler that lists and shows the messages in a caller-owned capture. Behavior, limits, and the preview rules are specified in the [delivery design](../../docs/design/design-layer.pdf).

Runnable example: [`development_mailbox`](../../apps/passwordless_demo/src/usage/development_mailbox.gleam), run by the repository gate.

## Installation

Add Correio from Hex and the mailbox adapter from its Git subdirectory:

```toml
[dependencies]
correio = ">= 0.1.0 and < 0.2.0"
correio_mailbox = { git = "https://github.com/gleam-dream/correio.git", ref = "main", path = "adapters/correio_mailbox" }
```

Commit `gleam.toml` and `manifest.toml` to retain the resolved versions and Git commit.

## Mount

<!-- prettier-ignore-start -->

<!-- snips: ../../apps/passwordless_demo/src/usage/development_mailbox.gleam#mailbox-setup -->
```gleam
let assert Ok(outbox) = capture.start(100)
let send = capture.sender(outbox)
let assert Ok(mailbox) = correio_mailbox.new(outbox, at: "/dev/mailbox")
```

<!-- prettier-ignore-end -->

Inject `send` into the application and route requests through the mailbox. The runnable example uses this GET helper:

<!-- prettier-ignore-start -->

<!-- snips: ../../apps/passwordless_demo/src/usage/development_mailbox.gleam#mailbox-handler -->
```gleam
fn get(mailbox: correio_mailbox.Mailbox, path: String) {
  correio_mailbox.handle(mailbox, request.new() |> request.set_path(path))
}
```

<!-- prettier-ignore-end -->

- Enable the route only in a development environment. Captured mail exposes secrets and blind recipients, and the application owns access control and the server.
- No HTTP listener starts in this package.

## Try it

```sh
# From the Correio repository root; no database or credentials needed.
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```
