# Correio Postmark adapter

- `correio_postmark` sends one Correio message through Postmark's `/email` endpoint. The application owns the HTTP Gun client and its shutdown.
- The adapter requires `ErrorCode: 0` and a nonempty bounded `MessageID` before reporting acceptance. Acceptance does not establish inbox delivery.
- A lost acknowledgement, malformed successful response, or server error remains `OutcomeUnknown`. The adapter never retries.

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

- `sender(provider, options)` supplies Correio's common `delivery.Sender` function. It starts no process and retains the caller's client handle.
- `tag`, `stream`, and `metadata` validate provider options. `track_opens` and `track_links` configure tracking through typed values.
- `deadline` sets a finite HTTP exchange timeout between 1 ms and 120 seconds. `response_limit` sets the collected response bound between 1 byte and 1 MiB; the default is 64 KiB.
- `limits` accepts Correio's validated message limits. Provider admission independently bounds recipient count, subject, sender, and encoded request size.
- A distinct envelope sender returns `UnsupportedCapability(EnvelopeSenderOverride)`. Postmark controls its return path, so the adapter cannot preserve that override.

## Credentials and recordings

- `redact_token` adds `x-postmark-server-token` to an existing HTTP Gun redaction policy. Configure this policy before starting a client or a recording.
- HTTP Gun's default credential list does not contain this provider-specific header. Recording with an unmodified default policy retains the token.
- Recordings also retain message bodies and addresses unless the application supplies `redaction.with_body`. The adapter's ordinary delivery diagnostics contain no provider response, token, address, or message body.
- Caller-owned playback and recording clients remain available. They are explicit application choices and do not establish live-provider acceptance.

## Transport and evidence

- Production requests use `https://api.postmarkapp.com/email` with an explicit host and TLS destination policy. HTTP Gun verifies certificates and hostnames.
- `local_test(provider, port)` selects `http://127.0.0.1:PORT/email`. The caller must also configure its client to allow loopback destinations.
- Destination policies intersect with the caller's existing policies. The adapter does not widen them or alter the client's trust roots.
- `NotSent` and `MaybeSent` HTTP failures remain separate delivery evidence. An observed documented rejection remains a rejection even when its response body exceeds the collection limit.
- Postmark's official [email API](https://postmarkapp.com/developer/api/email-api) defines message fields and acceptance responses. Its [API overview](https://postmarkapp.com/developer/api/overview) documents HTTP rejection codes and possible message loss during server errors.
- Adapter admission conservatively measures sender and subject limits in bytes. Encoded JSON must fit 10,000,000 bytes; core message limits and the caller's HTTP request limits also apply.

## Verification

```sh
cd adapters/correio_postmark
nix develop ../.. -c gleam format --check src test
nix develop ../.. -c gleam build --warnings-as-errors
nix develop ../.. -c gleam test
```

- Tests use native local HTTP peers and dummy tokens. They exercise provider acceptance, typed options, attachment bytes, blind-recipient privacy, rejection, uncertain effects, deadlines, response bounds, destination policy, and redaction.
- These tests do not contact Postmark or claim live account qualification.
