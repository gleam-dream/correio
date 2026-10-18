//// Runnable usage of the Postmark adapter against a local scripted peer.
//// The README's `Use` section mirrors this file. No provider is contacted.

import correio/address
import correio/delivery
import correio/message
import correio_postmark as postmark
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/redaction

type Peer

type Mode {
  Reply(Int, String)
}

@external(erlang, "correio_postmark_peer", "start")
fn peer(mode: Mode) -> #(Int, Peer)

@external(erlang, "correio_postmark_peer", "report")
fn report(peer: Peer) -> #(String, String)

fn mail() -> message.Message {
  let assert Ok(from) = address.parse("sender@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) =
    message.new(from, to, "Hello", message.Text("Hello from Correio."))
  mail
}

pub fn send_through_postmark_test() {
  let #(port, peer) =
    peer(Reply(200, "{\"ErrorCode\":0,\"MessageID\":\"local-message-id\"}"))

  // The application owns the HTTP client. Add the provider token header to
  // the redaction policy before starting it. This example also admits loopback
  // because the peer is local; a production client talks to Postmark over TLS.
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
  receipt.provider_id |> should.equal(Some("local-message-id"))
  let #(head, _body) = report(peer)
  string.starts_with(head, "POST /email HTTP/1.1\r\n") |> should.be_true

  // Invalid configuration is a typed error.
  postmark.new(client, "") |> should.be_error
  postmark.deadline(provider, 0) |> should.be_error

  // Postmark controls the return path, so an envelope-sender override cannot
  // be preserved and is refused before anything is submitted.
  let assert Ok(bounce) = address.parse("bounces@example.com")
  send(message.set_envelope_sender(mail(), bounce))
  |> should.equal(
    delivery.NotSent(delivery.UnsupportedCapability(
      delivery.EnvelopeSenderOverride,
    )),
  )

  http_gun.stop(client)
}
