import correio/address
import correio/delivery
import correio/message
import correio_postmark as postmark
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/redaction

pub fn main() {
  gleeunit.main()
}

type Peer

type Mode {
  Reply(Int, String)
  CloseOnAccept
  CloseAfterRequest
  Stall
}

@external(erlang, "correio_postmark_peer", "start")
fn peer(mode: Mode) -> #(Int, Peer)

@external(erlang, "correio_postmark_peer", "report")
fn report(peer: Peer) -> #(String, String)

@external(erlang, "correio_postmark_peer", "now_ms")
fn now_ms() -> Int

@external(erlang, "correio_postmark_peer", "pause")
fn pause(milliseconds: Int) -> Nil

// HTTP Gun releases pool membership asynchronously after body termination.
// Observe convergence with a finite budget instead of asserting a scheduling race.
fn no_open_bodies(client: http_gun.Client, deadline: Int) -> Bool {
  case http_gun.stats(client) {
    Ok(stats) ->
      case stats.open_bodies == 0 {
        True -> True
        False ->
          case now_ms() < deadline {
            True -> {
              pause(10)
              no_open_bodies(client, deadline)
            }
            False -> False
          }
      }
    Error(_) -> False
  }
}

fn client() -> http_gun.Client {
  let settings =
    config.default()
    |> config.allow_loopback
    |> config.with_redaction(postmark.redact_token(redaction.default()))
  let assert Ok(client) = http_gun.start(settings)
  client
}

fn mail() -> message.Message {
  let assert Ok(a) = address.parse("sender@example.com")
  let assert Ok(b) = address.parse("reader@example.com")
  let assert Ok(hidden) = address.parse("private@example.com")
  let assert Ok(mail) =
    message.new(
      a,
      b,
      "Hello",
      message.Alternative("Hello", "<p>Hello</p><img src=\"cid:logo\">"),
    )
  message.add_bcc(mail, hidden)
}

fn configured(client: http_gun.Client, port: Int) -> postmark.Config {
  let assert Ok(config) =
    postmark.new(client, "PRIVATE_TEST_TOKEN")
    |> result.try(postmark.local_test(_, port))
  config
}

pub fn credentials_cannot_inject_headers_test() {
  let client = client()
  postmark.new(client, "token\r\nX-Injected: true") |> should.be_error
  http_gun.stop(client)
}

pub fn native_postmark_request_preserves_capabilities_test() {
  let #(port, peer) =
    peer(Reply(200, "{\"ErrorCode\":0,\"MessageID\":\"provider-local-id\"}"))
  let client = client()
  let config = configured(client, port)
  let assert Ok(file) =
    message.attachment(
      "logo.png",
      "image/png",
      <<0, 255>>,
      message.Inline("logo"),
    )
  let mail = message.attach(mail(), file)
  let assert Ok(options) =
    postmark.options()
    |> postmark.tag("login")
    |> result.try(postmark.stream(_, "outbound"))
    |> result.try(postmark.metadata(_, "account", "42"))
  let options =
    options
    |> postmark.track_opens(False)
    |> postmark.track_links(postmark.NoLinks)
  let assert delivery.Accepted(receipt) = postmark.send(config, mail, options)
  receipt.provider_id |> should.equal(Some("provider-local-id"))
  list.length(receipt.recipients) |> should.equal(2)
  let #(head, body) = report(peer)
  string.starts_with(head, "POST /email HTTP/1.1\r\n") |> should.be_true
  string.contains(head, "private@example.com") |> should.be_false
  let decoder = {
    use bcc <- decode.field("Bcc", decode.string)
    use tag <- decode.field("Tag", decode.string)
    use stream <- decode.field("MessageStream", decode.string)
    use tracking <- decode.field("TrackLinks", decode.string)
    use attachments <- decode.field(
      "Attachments",
      decode.list({
        use cid <- decode.field("ContentID", decode.string)
        use content <- decode.field("Content", decode.string)
        decode.success(#(cid, content))
      }),
    )
    decode.success(#(bcc, tag, stream, tracking, attachments))
  }
  json.parse(body, decoder)
  |> should.equal(
    Ok(
      #("private@example.com", "login", "outbound", "None", [
        #("cid:logo", "AP8="),
      ]),
    ),
  )
  no_open_bodies(client, now_ms() + 1000) |> should.be_true
  http_gun.stop(client)
}

fn check_response(status: Int, body: String, expected: delivery.Outcome) {
  let #(port, peer) = peer(Reply(status, body))
  let client = client()
  postmark.send(configured(client, port), mail(), postmark.options())
  |> should.equal(expected)
  let _ = report(peer)
  http_gun.stop(client)
}

pub fn provider_refusals_and_uncertainty_are_distinct_test() {
  check_response(
    422,
    "{\"ErrorCode\":406,\"Message\":\"private recipient\"}",
    delivery.Rejected(delivery.Permanent),
  )
  check_response(
    200,
    "{\"ErrorCode\":406}",
    delivery.Rejected(delivery.Permanent),
  )
  check_response(429, "{}", delivery.Rejected(delivery.Temporary))
  check_response(500, "{\"ErrorCode\":101}", delivery.OutcomeUnknown)
  check_response(503, "{\"ErrorCode\":100}", delivery.OutcomeUnknown)
  check_response(200, "not-json", delivery.OutcomeUnknown)
  check_response(200, "{\"ErrorCode\":0}", delivery.OutcomeUnknown)
  check_response(200, "{\"MessageID\":\"id\"}", delivery.OutcomeUnknown)
}

pub fn disconnect_after_request_is_unknown_without_retry_test() {
  let #(port, peer) = peer(CloseAfterRequest)
  let client = client()
  postmark.send(configured(client, port), mail(), postmark.options())
  |> should.equal(delivery.OutcomeUnknown)
  let #(head, body) = report(peer)
  string.starts_with(head, "POST /email") |> should.be_true
  string.contains(body, "private@example.com") |> should.be_true
  http_gun.stop(client)
}

pub fn close_before_request_does_not_claim_acceptance_test() {
  let #(port, peer) = peer(CloseOnAccept)
  let client = client()
  let outcome =
    postmark.send(configured(client, port), mail(), postmark.options())
  case outcome {
    delivery.NotSent(_) | delivery.OutcomeUnknown -> True
    _ -> False
  }
  |> should.be_true
  let _ = report(peer)
  http_gun.stop(client)
}

pub fn connection_refusal_is_proven_no_send_test() {
  let client = client()
  postmark.send(configured(client, 1), mail(), postmark.options())
  |> should.equal(delivery.NotSent(delivery.ConnectionUnavailable))
  http_gun.stop(client)
}

pub fn deadline_after_request_is_unknown_and_closes_body_test() {
  let #(port, peer) = peer(Stall)
  let client = client()
  let assert Ok(config) = configured(client, port) |> postmark.deadline(100)
  let start = now_ms()
  postmark.send(config, mail(), postmark.options())
  |> should.equal(delivery.OutcomeUnknown)
  { now_ms() - start < 2000 } |> should.be_true
  no_open_bodies(client, now_ms() + 1000) |> should.be_true
  let _ = report(peer)
  http_gun.stop(client)
}

pub fn excessive_response_preserves_observed_rejection_test() {
  let #(port, peer) = peer(Reply(429, string.repeat("x", 1000)))
  let client = client()
  let assert Ok(config) =
    configured(client, port) |> postmark.response_limit(10)
  postmark.send(config, mail(), postmark.options())
  |> should.equal(delivery.Rejected(delivery.Temporary))
  let _ = report(peer)
  http_gun.stop(client)
}

pub fn unsupported_envelope_is_refused_before_network_test() {
  let client = client()
  let assert Ok(bounce) = address.parse("bounces@example.com")
  postmark.send(
    configured(client, 1),
    message.set_envelope_sender(mail(), bounce),
    postmark.options(),
  )
  |> should.equal(
    delivery.NotSent(delivery.UnsupportedCapability(
      delivery.EnvelopeSenderOverride,
    )),
  )
  http_gun.stop(client)
}

pub fn caller_destination_policy_remains_authoritative_test() {
  let assert Ok(client) = http_gun.start(config.default())
  postmark.send(configured(client, 1), mail(), postmark.options())
  |> should.equal(delivery.NotSent(delivery.TransportSecurity))
  http_gun.stop(client)
}

pub fn token_redaction_adds_to_existing_policy_test() {
  let policy =
    redaction.default()
    |> redaction.with_headers(["x-other-secret"])
    |> postmark.redact_token
  redaction.headers(policy, [
    #("X-Postmark-Server-Token", "private"),
    #("authorization", "private"),
    #("x-other-secret", "private"),
    #("content-type", "application/json"),
  ])
  |> should.equal([#("content-type", "application/json")])
}

pub fn provider_admission_limits_are_checked_before_network_test() {
  let client = client()
  let config = configured(client, 1)
  let assert Ok(extra) = address.parse("extra@example.com")
  let many =
    list.fold(list.repeat(Nil, 49), mail(), fn(m, _) {
      message.add_to(m, extra)
    })
  postmark.send(config, many, postmark.options())
  |> should.equal(delivery.NotSent(delivery.ProviderLimitExceeded))
  let assert Ok(limits) = message.limits(1, 10, 8192, 1000, 1000, 10_000)
  postmark.send(postmark.limits(config, limits), mail(), postmark.options())
  |> should.equal(
    delivery.NotSent(delivery.InvalidMessage(message.TooManyRecipients)),
  )
  http_gun.stop(client)
}

pub fn oversized_success_body_is_unknown_test() {
  let #(port, peer) =
    peer(Reply(200, "{\"ErrorCode\":0,\"MessageID\":\"provider-local-id\"}"))
  let client = client()
  let assert Ok(config) =
    configured(client, port) |> postmark.response_limit(10)
  postmark.send(config, mail(), postmark.options())
  |> should.equal(delivery.OutcomeUnknown)
  let _ = report(peer)
  http_gun.stop(client)
}

pub fn provider_options_reject_unbounded_or_invalid_values_test() {
  postmark.options()
  |> postmark.tag(string.repeat("x", 1001))
  |> should.equal(Error(postmark.InvalidTag))
  postmark.options()
  |> postmark.stream("")
  |> should.equal(Error(postmark.InvalidStream))
  postmark.options()
  |> postmark.metadata("", "value")
  |> should.equal(Error(postmark.InvalidMetadata))
  let client = client()
  let config = configured(client, 1)
  postmark.deadline(config, 0) |> should.equal(Error(postmark.InvalidDeadline))
  postmark.response_limit(config, 0)
  |> should.equal(Error(postmark.InvalidResponseLimit))
  http_gun.stop(client)
}
