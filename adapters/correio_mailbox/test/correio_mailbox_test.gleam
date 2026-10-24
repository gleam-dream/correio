import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio_mailbox as mailbox
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn mail(subject: String, body: message.Body) {
  let assert Ok(from) = address.parse("sender@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) = message.new(from, to, subject, body)
  mail
}

pub fn mailbox_is_read_only_bounded_and_uses_stable_identifiers_test() {
  let assert Ok(capture) = capture.start(60)
  let assert Ok(ui) = mailbox.new(capture, at: "/dev/mail")
  list.repeat(Nil, 55)
  |> list.each(fn(_) {
    let assert delivery.Accepted(_) =
      capture.send(capture, mail("Hello", message.Text("body")))
  })
  let page = mailbox.handle(ui, request.new() |> request.set_path("/dev/mail"))
  page.status |> should.equal(200)
  string.split(page.body, "data-message-id=") |> list.length |> should.equal(51)
  page.body |> string.contains("/dev/mail/55") |> should.be_true
  let detail =
    mailbox.handle(ui, request.new() |> request.set_path("/dev/mail/1"))
  detail.status |> should.equal(200)
  detail.body |> string.contains("reader@example.com") |> should.be_true
  mailbox.handle(
    ui,
    request.new()
      |> request.set_path("/dev/mail")
      |> request.set_method(http.Post),
  ).status
  |> should.equal(405)
  capture.clear(capture) |> should.equal(Ok(Nil))
  let assert delivery.Accepted(_) =
    capture.send(capture, mail("Later", message.Text("new")))
  mailbox.handle(ui, request.new() |> request.set_path("/dev/mail/1")).status
  |> should.equal(404)
  mailbox.handle(ui, request.new() |> request.set_path("/dev/mail/56")).status
  |> should.equal(200)
  mailbox.handle(ui, request.new() |> request.set_path("/dev/mail-other")).status
  |> should.equal(404)
  capture.stop(capture) |> should.equal(Ok(Nil))
  mailbox.handle(ui, request.new() |> request.set_path("/dev/mail")).status
  |> should.equal(503)
}

pub fn untrusted_content_has_no_active_markup_and_security_headers_test() {
  let assert Ok(capture) = capture.start(1)
  let assert Ok(ui) = mailbox.new(capture, at: "/mail")
  let html =
    "<p>Hello</p><script>parent.pwned=true</script><meta http-equiv=refresh content='0;url=https://example.com/login'><img src=https://example.com/track><a href=https://example.com/login>login</a><form action=https://example.com/login><input></form>"
  let assert delivery.Accepted(_) =
    capture.send(
      capture,
      mail("<img src=x>", message.Alternative("<plain>", html)),
    )
  let page = mailbox.handle(ui, request.new() |> request.set_path("/mail/1"))
  page.body |> string.contains("<img src=x>") |> should.be_false
  page.body |> string.contains("&lt;plain&gt;") |> should.be_true
  page.body |> string.contains("sandbox=\"\"") |> should.be_true
  page.body |> string.contains("<script>") |> should.be_false
  response.get_header(page, "cache-control") |> should.equal(Ok("no-store"))
  response.get_header(page, "referrer-policy")
  |> should.equal(Ok("no-referrer"))
  response.get_header(page, "x-content-type-options")
  |> should.equal(Ok("nosniff"))
  capture.stop(capture) |> should.equal(Ok(Nil))
}

pub fn mount_paths_are_validated_test() {
  let assert Ok(capture) = capture.start(1)
  [
    "",
    "/",
    "//mail",
    "/mail/",
    "/a/../mail",
    "/mail?x",
    "/mail#x",
    "/m\"ail",
    "/mail%2fsecret",
  ]
  |> list.each(fn(path) {
    mailbox.new(capture, at: path)
    |> should.equal(Error(mailbox.InvalidMountPath))
  })
  let assert Ok(_) = mailbox.new(capture, at: "/dev/mail-box_2")
  capture.stop(capture) |> should.equal(Ok(Nil))
}
