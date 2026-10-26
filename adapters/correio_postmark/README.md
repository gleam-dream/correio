# Correio Postmark adapter

Sends one Correio message through Postmark's email endpoint. Acceptance rules, limits, and redaction rules are specified in the [delivery design](../../docs/design/design-layer.pdf).

Runnable example: [`test/usage_test.gleam`](test/usage_test.gleam) sends through a local scripted peer in this package's tests. The snippet below mirrors it.

## Installation

Add Correio and HTTP Gun from Hex and the Postmark adapter from its Git subdirectory:

```toml
[dependencies]
correio = ">= 0.1.0 and < 0.2.0"
http_gun = ">= 0.1.0 and < 0.2.0"
correio_postmark = { git = "https://github.com/gleam-dream/correio.git", ref = "main", path = "adapters/correio_postmark" }
```

Commit `gleam.toml` and `manifest.toml` to retain the resolved versions and Git commit.

## Use

This excerpt sends a message to the test's scripted loopback peer at `port`, using a dummy token and its `mail()` fixture. Production uses the application's server token and the default Postmark endpoint.

<!-- prettier-ignore-start -->

<!-- snips: test/usage_test.gleam#postmark-send -->
```gleam
let settings =
  config.default()
  |> config.allow_loopback
  |> config.with_redaction(postmark.redact_token(redaction.default()))
let assert Ok(client) = http_gun.start(settings)

// A server token is validated, and `local_test` selects the local endpoint.
let assert Ok(provider) =
  postmark.new(client, "DUMMY_SERVER_TOKEN")
  |> result.try(postmark.local_test(_, port))
let assert Ok(provider) = postmark.deadline(provider, 5000)
let assert Ok(provider) = postmark.response_limit(provider, 65_536)

// Provider options are typed and validated.
let assert Ok(options) =
  postmark.options()
  |> postmark.tag("welcome")
  |> result.try(postmark.stream(_, "outbound"))
  |> result.try(postmark.metadata(_, "account", "42"))

// `sender` supplies Correio's common delivery function for injection.
let send: delivery.Sender = postmark.sender(provider, options)
let assert delivery.Accepted(receipt) = send(mail())
```

<!-- prettier-ignore-end -->

- The application owns the HTTP Gun client and its shutdown. `sender(provider, options)` supplies Correio's common `delivery.Sender` function.
- Configure `redact_token` before starting a client or recording. The default redaction policy does not hide the Postmark server token, and recordings also retain message bodies and addresses unless `redaction.with_body` is supplied.
- `local_test(provider, port)` targets a loopback server, and the client must also allow loopback destinations.
- Postmark's [email API](https://postmarkapp.com/developer/api/email-api) and [API overview](https://postmarkapp.com/developer/api/overview) define message fields, acceptance responses, and rejection codes.

## Test

```sh
cd adapters/correio_postmark
nix develop ../.. -c gleam format --check src test
nix develop ../.. -c gleam build --warnings-as-errors
nix develop ../.. -c gleam test
```

- Tests use local HTTP peers and dummy tokens. They do not contact Postmark or qualify a live account.
