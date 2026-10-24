import correio/address
import correio/message
import correio/mime
import gleam/bit_array
import gleam/list
import gleam/string
import gleeunit/should

pub fn bcc_is_envelope_only_test() {
  let assert Ok(from) = address.parse("sender@EXAMPLE.com")
  let assert Ok(to) = address.parse("recipient@example.com")
  let assert Ok(hidden) = address.parse("secret@example.com")
  let assert Ok(mail) = message.new(from, to, "Hello", message.Text("World"))
  let mail = message.add_bcc(mail, hidden)
  message.envelope(mail).1 |> list.length |> should.equal(2)
  let assert Ok(raw) = mime.render(mail)
  let assert Ok(raw) = bit_array.to_string(raw)
  raw |> string.contains("secret@example.com") |> should.be_false
  address.email(from) |> should.equal("sender@example.com")
}

pub fn injection_and_empty_content_are_refused_test() {
  address.parse("a@example.com\r\nBcc: x@example.com") |> should.be_error
  address.parse("a..b@example.com") |> should.be_error
  let assert Ok(from) = address.parse("a@example.com")
  address.named(from, "name\nBcc: x") |> should.be_error
  address.named(from, "name\u{0085}Bcc: x") |> should.be_error
  address.named(from, "name\u{2028}Bcc: x") |> should.be_error
  message.new(from, from, "Subject\r\nBcc: x", message.Text("hello"))
  |> should.be_error
  message.new(from, from, "Subject", message.Text("")) |> should.be_error
  let assert Ok(mail) =
    message.new(from, from, "Subject", message.Text("hello"))
  message.header(mail, "bCc", "x@example.com") |> should.be_error
  message.header(mail, "Content-Type", "bad") |> should.be_error
  message.header(mail, "X-Custom", "ok\r\nx: bad") |> should.be_error
}

pub fn envelope_deduplicates_mailboxes_with_distinct_names_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(named) = address.named(a, "A different name")
  let assert Ok(mail) = message.new(a, a, "Hello", message.Text("body"))
  message.add_cc(mail, named)
  |> message.envelope
  |> fn(e) { list.length(e.1) }
  |> should.equal(1)
}

pub fn metadata_and_encoded_submission_are_bounded_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Hello", message.Text("body"))
  let assert Ok(limits) = message.limits(1, 1, 20, 10, 10, 5000)
  message.add_to(mail, a)
  |> message.validate(limits)
  |> should.equal(Error(message.TooManyRecipients))
  let assert Ok(small) = message.limits(10, 10, 20, 10, 10, 1)
  mime.render_with_limits(mail, small)
  |> should.equal(Error(message.SubmissionTooLarge))
  let assert Ok(file) =
    message.attachment("empty.txt", "text/plain", <<>>, message.AttachmentFile)
  let many =
    list.fold(list.repeat(Nil, 10), mail, fn(m, _) { message.attach(m, file) })
  mime.render_with_limits(many, limits)
  |> should.equal(Error(message.SubmissionTooLarge))
  message.limits(-1, 1, 1, 1, 1, 1)
  |> should.equal(Error(message.InvalidLimits))
}

pub fn unsupported_nested_message_attachment_is_refused_test() {
  message.attachment(
    "bits",
    "application/octet-stream",
    <<1:size(1)>>,
    message.AttachmentFile,
  )
  |> should.equal(Error(message.InvalidAttachment))
  message.attachment(
    "forwarded.eml",
    "message/rfc822",
    <<>>,
    message.AttachmentFile,
  )
  |> should.equal(Error(message.InvalidAttachment))
  message.attachment("nested", "multipart/mixed", <<>>, message.AttachmentFile)
  |> should.equal(Error(message.InvalidAttachment))
  message.attachment("x", "text/plain", <<>>, message.Inline("bad>\r\n"))
  |> should.equal(Error(message.InvalidAttachment))
}

@external(erlang, "correio_mail_test_ffi", "wire_semantics")
fn wire_semantics(raw: BitArray) -> Bool

pub fn binary_attachment_and_text_decode_independently_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Hello", message.Text("hello\nworld"))
  let assert Ok(file) =
    message.attachment(
      "binary.dat",
      "application/octet-stream",
      <<0, 255, 128, 13, 10>>,
      message.AttachmentFile,
    )
  let assert Ok(raw) = mail |> message.attach(file) |> mime.render
  wire_semantics(raw) |> should.be_true
}

pub fn structured_custom_headers_preserve_wire_syntax_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Hello", message.Text("body"))
  let assert Ok(mail) =
    message.header(
      mail,
      "List-Unsubscribe",
      "<https://example.test/unsubscribe>",
    )
  let assert Ok(mail) =
    message.header(mail, "List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  let assert Ok(raw) = mime.render(mail)
  let assert Ok(raw) = bit_array.to_string(raw)
  string.contains(
    raw,
    "List-Unsubscribe: <https://example.test/unsubscribe>\r\n",
  )
  |> should.be_true
  string.contains(raw, "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n")
  |> should.be_true
  message.header(mail, "X-Custom", "café")
  |> should.equal(Error(message.InvalidHeader))
  message.header(mail, "X-Custom", string.repeat("x", 1000))
  |> should.equal(Error(message.InvalidHeader))
}

pub fn terminal_line_feed_cannot_bypass_field_validation_test() {
  address.parse("a@example.test\n") |> should.be_error
  address.parse("a\n@example.test") |> should.be_error
  let assert Ok(a) = address.parse("a@example.test")
  let assert Ok(mail) = message.new(a, a, "Subject", message.Text("body"))
  message.header(mail, "X-Test\n", "value") |> should.be_error
  message.attachment("file.txt", "text/plain\n", <<>>, message.AttachmentFile)
  |> should.be_error
  message.attachment("file.txt", "text/plain", <<>>, message.Inline("image\n"))
  |> should.be_error
}
