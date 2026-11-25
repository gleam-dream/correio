import correio/address
import correio/message
import correio/mime
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "correio_mail_test_ffi", "wire_fields")
fn wire_fields(raw: BitArray) -> Result(List(#(String, BitArray)), Nil)

/// Renders a message and returns the wire text with the fields an independent
/// parser decodes from it. Every rendered message must parse without defects,
/// use only CRLF line breaks, and keep each line within 998 bytes.
fn rendered(mail: message.Message) -> #(String, List(#(String, BitArray))) {
  let assert Ok(raw) = mime.render(mail)
  let assert Ok(fields) = wire_fields(raw)
  field(fields, "defects") |> should.equal("0")
  field(fields, "bare-line-breaks") |> should.equal("0")
  let assert Ok(longest) = int.parse(field(fields, "longest-line"))
  { longest <= 998 } |> should.be_true
  let assert Ok(text) = bit_array.to_string(raw)
  #(text, fields)
}

fn field(fields: List(#(String, BitArray)), name: String) -> String {
  let assert Ok(value) = list.key_find(fields, name)
  let assert Ok(text) = bit_array.to_string(value)
  text
}

fn mailbox(email: String, name: String) -> address.Address {
  let assert Ok(parsed) = address.parse(email)
  let assert Ok(named) = address.named(parsed, name)
  named
}

pub fn ascii_message_is_readable_on_the_wire_test() {
  let assert Ok(mail) =
    message.new(
      mailbox("sender@example.com", "Example Accounts"),
      mailbox("reader@example.com", "Doe, Jane"),
      "Sign in to Example",
      message.Alternative(
        "Use this link:\nhttps://example.test/login?token=abc",
        "<p><a href=\"https://example.test/login?token=abc\">Sign in</a></p>",
      ),
    )
  let #(text, fields) = rendered(mail)
  string.contains(text, "Subject: Sign in to Example\r\n") |> should.be_true
  string.contains(text, "From: Example Accounts <sender@example.com>\r\n")
  |> should.be_true
  string.contains(text, "To: \"Doe, Jane\" <reader@example.com>\r\n")
  |> should.be_true
  string.contains(
    text,
    "Use this link:\r\nhttps://example.test/login?token=abc",
  )
  |> should.be_true
  string.contains(text, "base64") |> should.be_false
  string.contains(text, "=?UTF-8?") |> should.be_false
  field(fields, "part.0.encoding") |> should.equal("7bit")
  field(fields, "part.1.encoding") |> should.equal("7bit")
  field(fields, "part.1.body")
  |> should.equal(
    "<p><a href=\"https://example.test/login?token=abc\">Sign in</a></p>",
  )
  field(fields, "to.0.name") |> should.equal("Doe, Jane")
}

pub fn non_ascii_text_round_trips_in_every_field_test() {
  let assert Ok(file) =
    message.attachment(
      "relatório ✓.txt",
      "text/plain",
      <<"conteúdo\n":utf8>>,
      message.AttachmentFile,
    )
  let assert Ok(mail) =
    message.new(
      mailbox("sender@example.com", "José Ünïcode"),
      mailbox("reader@example.com", "世界"),
      "Olá, 世界 ✓",
      message.Alternative(
        "Olá, tudo bem?\nAté já.",
        "<p>こんにちは世界、これは日本語の本文です。</p>",
      ),
    )
  let mail =
    mail
    |> message.add_cc(mailbox("copy@example.com", "Ångström"))
    |> message.set_reply_to(mailbox("reply@example.com", "Réponse"))
    |> message.attach(file)
  let #(_, fields) = rendered(mail)
  field(fields, "subject") |> should.equal("Olá, 世界 ✓")
  field(fields, "from.0.name") |> should.equal("José Ünïcode")
  field(fields, "to.0.name") |> should.equal("世界")
  field(fields, "cc.0.name") |> should.equal("Ångström")
  field(fields, "reply-to.0.name") |> should.equal("Réponse")
  // Mostly ASCII text stays readable as quoted-printable; this HTML would
  // triple in size, so it is base64.
  field(fields, "part.0.encoding") |> should.equal("quoted-printable")
  field(fields, "part.0.body") |> should.equal("Olá, tudo bem?\r\nAté já.")
  field(fields, "part.1.encoding") |> should.equal("base64")
  field(fields, "part.1.body")
  |> should.equal("<p>こんにちは世界、これは日本語の本文です。</p>")
  field(fields, "part.2.encoding") |> should.equal("base64")
  field(fields, "part.2.filename") |> should.equal("relatório ✓.txt")
  field(fields, "part.2.body") |> should.equal("conteúdo\n")
}

pub fn ascii_that_resembles_syntax_stays_data_test() {
  let hostile = "Eve\" <eve@example.net>, \"x\\"
  let assert Ok(mail) =
    message.new(
      mailbox("sender@example.com", hostile),
      mailbox("reader@example.com", "=?UTF-8?B?QmNjOiB4?="),
      "=?UTF-8?B?QmNjOiB4QGV4YW1wbGUuY29t?=",
      message.Text("body"),
    )
  let mail =
    mail
    |> message.add_cc(mailbox("copy@example.com", " (comment) <x@y.test> "))
    |> message.set_reply_to(mailbox("reply@example.com", "a@b.test, c@d.test"))
  let #(_, fields) = rendered(mail)
  field(fields, "subject")
  |> should.equal("=?UTF-8?B?QmNjOiB4QGV4YW1wbGUuY29t?=")
  field(fields, "from.0.name") |> should.equal(hostile)
  field(fields, "from.0.address") |> should.equal("sender@example.com")
  field(fields, "to.0.name") |> should.equal("=?UTF-8?B?QmNjOiB4?=")
  field(fields, "cc.0.name") |> should.equal(" (comment) <x@y.test> ")
  field(fields, "cc.0.address") |> should.equal("copy@example.com")
  field(fields, "reply-to.0.name") |> should.equal("a@b.test, c@d.test")
  list.key_find(fields, "from.1.address") |> should.be_error
  list.key_find(fields, "cc.1.address") |> should.be_error
  list.key_find(fields, "reply-to.1.address") |> should.be_error
  field(fields, "header-names")
  |> should.equal(
    "cc,content-transfer-encoding,content-type,date,from,message-id,mime-version,reply-to,subject,to",
  )
}

pub fn line_breaks_are_refused_in_every_header_field_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Subject", message.Text("body"))
  ["\r\nBcc: x@example.com", "\nBcc: x@example.com", "\rBcc: x@example.com"]
  |> list.each(fn(injection) {
    address.parse("a@example.com" <> injection) |> should.be_error
    address.named(a, "Name" <> injection) |> should.be_error
    message.new(a, a, "Subject" <> injection, message.Text("body"))
    |> should.be_error
    message.header(mail, "X-Test" <> injection, "value") |> should.be_error
    message.header(mail, "X-Test", "value" <> injection) |> should.be_error
    message.attachment(
      "file.txt" <> injection,
      "text/plain",
      <<>>,
      message.AttachmentFile,
    )
    |> should.be_error
    message.attachment(
      "file.txt",
      "text/plain" <> injection,
      <<>>,
      message.AttachmentFile,
    )
    |> should.be_error
    message.attachment(
      "file.png",
      "image/png",
      <<>>,
      message.Inline("cid" <> injection),
    )
    |> should.be_error
  })
}

pub fn body_text_cannot_add_headers_or_parts_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let text =
    "Hello\r\nBcc: x@example.com\r\n\r\n--boundary\r\nContent-Type: text/html\r\n\r\n.\r\nFrom the team\r\ntrailing space \r\n=?UTF-8?B?eA==?="
  let html = "<p>lone\rcarriage return</p>"
  let assert Ok(mail) =
    message.new(a, a, "Subject", message.Alternative(text, html))
  let #(_, fields) = rendered(mail)
  field(fields, "header-names")
  |> should.equal("content-type,date,from,message-id,mime-version,subject,to")
  field(fields, "part.0.type") |> should.equal("text/plain")
  field(fields, "part.0.encoding") |> should.equal("quoted-printable")
  field(fields, "part.0.body") |> should.equal(text)
  field(fields, "part.1.type") |> should.equal("text/html")
  // A carriage return outside CRLF is preserved exactly, which needs base64.
  field(fields, "part.1.encoding") |> should.equal("base64")
  field(fields, "part.1.body") |> should.equal(html)
  list.key_find(fields, "part.2.type") |> should.be_error
}

pub fn long_values_fold_within_line_limits_test() {
  let assert Ok(a) = address.parse("a@example.com")
  let subject = string.repeat("word ", 80) <> "end"
  let line = string.repeat("x", 2000)
  let assert Ok(mail) = message.new(a, a, subject, message.Text(line))
  let #(text, fields) = rendered(mail)
  string.contains(text, "Subject: word word") |> should.be_true
  field(fields, "subject") |> should.equal(subject)
  field(fields, "part.0.encoding") |> should.equal("quoted-printable")
  field(fields, "part.0.body") |> should.equal(line)
  // A subject with no space to fold at is emitted as encoded words.
  let unbroken = string.repeat("x", 950)
  let assert Ok(mail) = message.new(a, a, unbroken, message.Text("body"))
  let #(_, fields) = rendered(mail)
  field(fields, "subject") |> should.equal(unbroken)
  let padded = "  two leading and one trailing space "
  let assert Ok(mail) = message.new(a, a, padded, message.Text("body"))
  let #(_, fields) = rendered(mail)
  field(fields, "subject") |> should.equal(padded)
}

fn text_message(body: String) -> message.Message {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Subject", message.Text(body))
  mail
}

/// Each case is the text body, the transfer encoding the renderer must choose
/// for it, and the body a reader decodes. Text line breaks decode as CRLF.
pub fn text_transfer_encoding_choice_test() {
  [
    #("plain words", "7bit", "plain words"),
    #("tab\tinside", "7bit", "tab\tinside"),
    #("=?UTF-8?B?eA==?= stays", "7bit", "=?UTF-8?B?eA==?= stays"),
    #("from is lower case", "7bit", "from is lower case"),
    #(" From after a space", "7bit", " From after a space"),
    #(string.repeat("x", 998), "7bit", string.repeat("x", 998)),
    #(string.repeat("x", 999), "quoted-printable", string.repeat("x", 999)),
    #("trailing space ", "quoted-printable", "trailing space "),
    #("trailing tab\t", "quoted-printable", "trailing tab\t"),
    #(
      "space before break \nnext",
      "quoted-printable",
      "space before break \r\nnext",
    ),
    #("From the team", "quoted-printable", "From the team"),
    #("Hello\nFrom the team", "quoted-printable", "Hello\r\nFrom the team"),
    #("form\u{000C}feed", "quoted-printable", "form\u{000C}feed"),
    // Two of four bytes are outside ASCII: quoted-printable is exactly twice
    // the text, the largest size that keeps it.
    #("Olá", "quoted-printable", "Olá"),
    #("日本語", "base64", "日本語"),
    #("lone\rreturn", "base64", "lone\rreturn"),
  ]
  |> list.each(fn(case_) {
    let #(body, encoding, decoded) = case_
    let #(_, fields) = rendered(text_message(body))
    #(body, field(fields, "part.0.encoding"))
    |> should.equal(#(body, encoding))
    #(body, field(fields, "part.0.body")) |> should.equal(#(body, decoded))
  })
}

/// LF, CRLF and mixed line breaks in text leave the renderer as CRLF, and a
/// 7bit body is the text itself on the wire.
pub fn text_line_breaks_are_crlf_on_the_wire_test() {
  ["one\ntwo\nthree", "one\r\ntwo\r\nthree", "one\ntwo\r\nthree"]
  |> list.each(fn(body) {
    let #(text, fields) = rendered(text_message(body))
    string.ends_with(text, "\r\n\r\none\r\ntwo\r\nthree") |> should.be_true
    field(fields, "part.0.encoding") |> should.equal("7bit")
  })
}

/// Quoted-printable lines stay within RFC 2045's 76 characters, soft breaks
/// included, and decode to the original text.
pub fn quoted_printable_lines_fit_76_characters_test() {
  let body =
    string.repeat("Olá, mundo = ", 100) <> "\n" <> string.repeat("b", 500)
  let #(text, fields) = rendered(text_message(body))
  field(fields, "part.0.encoding") |> should.equal("quoted-printable")
  field(fields, "part.0.body")
  |> should.equal(string.replace(body, "\n", "\r\n"))
  let assert [_, content] = string.split(text, "\r\n\r\n")
  string.split(content, "\r\n")
  |> list.all(fn(line) { string.byte_size(line) <= 76 })
  |> should.be_true
}
