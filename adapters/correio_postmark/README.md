# Correio Postmark adapter

Sends one Correio message through Postmark's email endpoint. Acceptance rules, limits, and redaction rules are specified in the [delivery design](../../docs/design/delivery/design.typ).

Runnable example: [`test/usage_test.gleam`](test/usage_test.gleam) sends through a local scripted peer in this package's tests. The snippet below mirrors it.

## Use

```gleam
import correio_postmark as postmark
import http_gun
import http_gun/config
import http_gun/redaction

let settings =
  config.default()
  |> config.with_redaction(postmark.redact_token(redaction.default()))
let assert Ok(client) = http_gun.start(settings)
let assert Ok(provider) = postmark.new(client, server_token)
let result = postmark.send(provider, message, postmark.options())
http_gun.stop(client)
```

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
