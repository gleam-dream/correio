import correio/address
import correio/delivery
import correio/message
import correio/smtp
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should

type Peer

type Mode {
  Accepting
  RefuseSecond
  RejectData
  DisconnectAfterData
  NoStarttls
  HangData
  HangBanner
  ImplicitTls
  Starttls
}

@external(erlang, "correio_mail_test_ffi", "peer")
fn peer(mode: Mode) -> #(Int, Peer)

@external(erlang, "correio_mail_test_ffi", "report")
fn report(peer: Peer) -> #(List(String), BitArray)

@external(erlang, "correio_mail_test_ffi", "certificate")
fn certificate() -> BitArray

fn mail() -> message.Message {
  let assert Ok(from) = address.parse("sender@example.com")
  let assert Ok(to) = address.parse("to@example.com")
  let assert Ok(bcc) = address.parse("private@example.com")
  let assert Ok(mail) =
    message.new(from, to, "Hello", message.Text("hello\nworld"))
  message.add_bcc(mail, bcc)
}

pub fn smtp_acceptance_includes_private_envelope_recipient_test() {
  let #(port, peer) = peer(Accepting)
  let assert Ok(config) = smtp.local_test("127.0.0.1", port)
  let assert delivery.Accepted(receipt) = smtp.send(config, mail())
  list.length(receipt.recipients) |> should.equal(2)
  let #(commands, raw) = report(peer)
  list.any(commands, string.contains(_, "RCPT TO:<private@example.com>"))
  |> should.be_true
  let assert Ok(raw) = bit_array.to_string(raw)
  string.contains(raw, "private@example.com") |> should.be_false
}

pub fn partial_recipient_refusal_aborts_before_data_test() {
  let #(port, peer) = peer(RefuseSecond)
  let assert Ok(config) = smtp.local_test("127.0.0.1", port)
  smtp.send(config, mail())
  |> should.equal(delivery.Rejected(delivery.Permanent))
  let #(commands, raw) = report(peer)
  list.contains(commands, "DATA\r\n") |> should.be_false
  raw |> should.equal(<<>>)
}

pub fn lost_data_acknowledgement_is_unknown_without_retry_test() {
  let #(port, peer) = peer(DisconnectAfterData)
  let assert Ok(config) = smtp.local_test("127.0.0.1", port)
  smtp.send(config, mail()) |> should.equal(delivery.OutcomeUnknown)
  let #(commands, _) = report(peer)
  commands
  |> list.filter(fn(x) { x == "DATA\r\n" })
  |> list.length
  |> should.equal(1)
}

pub fn definite_negative_data_reply_is_rejected_test() {
  let #(port, peer) = peer(RejectData)
  let assert Ok(config) = smtp.local_test("127.0.0.1", port)
  smtp.send(config, mail())
  |> should.equal(delivery.Rejected(delivery.Temporary))
  let _ = report(peer)
}

pub fn mandatory_starttls_never_sends_without_tls_test() {
  let #(port, peer) = peer(NoStarttls)
  let assert Ok(config) = smtp.starttls("127.0.0.1", port)
  let assert delivery.NotSent(_) = smtp.send(config, mail())
  let #(commands, _) = report(peer)
  list.any(commands, string.starts_with(_, "MAIL")) |> should.be_false
  list.any(commands, string.starts_with(_, "AUTH")) |> should.be_false
}

pub fn deadline_after_data_remains_unknown_test() {
  let #(port, peer) = peer(HangData)
  let assert Ok(config) =
    smtp.local_test("127.0.0.1", port) |> result.try(smtp.deadline(_, 100))
  smtp.send(config, mail()) |> should.equal(delivery.OutcomeUnknown)
  let _ = report(peer)
}

pub fn deadline_before_banner_is_no_send_test() {
  let #(port, peer) = peer(HangBanner)
  let assert Ok(config) =
    smtp.local_test("127.0.0.1", port) |> result.try(smtp.deadline(_, 100))
  smtp.send(config, mail())
  |> should.equal(delivery.NotSent(delivery.DeadlineExceeded))
  let _ = report(peer)
}

pub fn explicit_ca_allows_verified_implicit_tls_test() {
  let #(port, peer) = peer(ImplicitTls)
  let assert Ok(config) =
    smtp.implicit_tls("localhost", port)
    |> result.try(smtp.trust_roots(_, certificate()))
  let assert delivery.Accepted(_) = smtp.send(config, mail())
  let _ = report(peer)
}

pub fn untrusted_certificate_never_transmits_test() {
  let #(port, peer) = peer(ImplicitTls)
  let assert Ok(config) = smtp.implicit_tls("localhost", port)
  let assert delivery.NotSent(_) = smtp.send(config, mail())
  let #(commands, raw) = report(peer)
  commands |> should.equal([])
  raw |> should.equal(<<>>)
}

pub fn explicit_ca_allows_verified_starttls_test() {
  let #(port, peer) = peer(Starttls)
  let assert Ok(config) =
    smtp.starttls("localhost", port)
    |> result.try(smtp.trust_roots(_, certificate()))
  let assert delivery.Accepted(_) = smtp.send(config, mail())
  let #(commands, _) = report(peer)
  list.contains(commands, "STARTTLS\r\n") |> should.be_true
}

pub fn hostname_mismatch_never_sends_credentials_or_content_test() {
  let #(port, peer) = peer(Starttls)
  let assert Ok(config) =
    smtp.starttls("127.0.0.1", port)
    |> result.try(smtp.trust_roots(_, certificate()))
    |> result.try(smtp.credentials(_, "private-user", "private-password"))
  let assert delivery.NotSent(_) = smtp.send(config, mail())
  let #(commands, raw) = report(peer)
  list.any(commands, string.starts_with(_, "AUTH")) |> should.be_false
  list.any(commands, string.starts_with(_, "MAIL")) |> should.be_false
  raw |> should.equal(<<>>)
}

@external(erlang, "correio_mail_test_ffi", "report_closed")
fn report_closed(peer: Peer) -> Bool

pub fn timed_out_exchange_closes_its_socket_test() {
  let #(port, peer) = peer(HangData)
  let assert Ok(config) =
    smtp.local_test("127.0.0.1", port) |> result.try(smtp.deadline(_, 100))
  smtp.send(config, mail()) |> should.equal(delivery.OutcomeUnknown)
  report_closed(peer) |> should.be_true
}

pub fn configured_authentication_cannot_silently_downgrade_test() {
  let #(port, peer) = peer(Starttls)
  let assert Ok(config) =
    smtp.starttls("localhost", port)
    |> result.try(smtp.trust_roots(_, certificate()))
    |> result.try(smtp.credentials(_, "private-user", "private-password"))
  smtp.send(config, mail())
  |> should.equal(delivery.NotSent(delivery.AuthenticationFailed))
  let #(commands, raw) = report(peer)
  list.any(commands, string.starts_with(_, "MAIL")) |> should.be_false
  raw |> should.equal(<<>>)
}

pub fn invalid_message_refuses_before_connecting_test() {
  let assert Ok(config) = smtp.local_test("127.0.0.1", 1)
  let assert Ok(limits) = message.limits(1, 10, 8192, 1000, 1000, 10_000)
  smtp.send(smtp.limits(config, limits), mail())
  |> should.equal(
    delivery.NotSent(delivery.InvalidMessage(message.TooManyRecipients)),
  )
}

pub fn smtp_configuration_rejects_invalid_boundaries_test() {
  smtp.starttls("https://mail.example.com", 587) |> should.be_error
  smtp.starttls("-bad.example.com", 587) |> should.be_error
  smtp.starttls("mail.example.com", 0) |> should.be_error
  smtp.local_test("mail.example.com", 25) |> should.be_error
  let assert Ok(local) = smtp.local_test("127.0.0.1", 25)
  smtp.credentials(local, "user", "pass")
  |> should.equal(Error(smtp.PlaintextCredentialsForbidden))
  smtp.deadline(local, 0) |> should.equal(Error(smtp.InvalidDeadline))
  smtp.trust_roots(local, <<>>) |> should.equal(Error(smtp.InvalidTrustRoots))
}

pub fn terminal_line_feed_in_smtp_host_is_refused_test() {
  smtp.starttls("mail.example.test\n", 587)
  |> should.equal(Error(smtp.InvalidHost))
}
