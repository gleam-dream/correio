//// Mount the read-only development mailbox over a capture. The mailbox
//// returns a response for a request; the application owns the HTTP server and
//// must expose the route only in development.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio_mailbox
import gleam/http
import gleam/http/request
import gleam/string

pub fn run() -> Nil {
  // snips-start: mailbox-setup
  let assert Ok(outbox) = capture.start(100)
  let send = capture.sender(outbox)
  let assert Ok(mailbox) = correio_mailbox.new(outbox, at: "/dev/mailbox")
  // snips-end: mailbox-setup

  // Mount paths are slash-separated ASCII segments with no empty segments.
  assert correio_mailbox.new(outbox, at: "/")
    == Error(correio_mailbox.InvalidMountPath)
  assert correio_mailbox.new(outbox, at: "/dev/mailbox/")
    == Error(correio_mailbox.InvalidMountPath)

  let assert Ok(from) = address.parse("hello@example.com")
  let assert Ok(to) = address.parse("alice@example.com")
  let assert Ok(mail) =
    message.new(
      from,
      to,
      "Sign in",
      message.Alternative("Open the link.", "<p>Open the <b>link</b>.</p>"),
    )
  let assert delivery.Accepted(_) = send(mail)

  // GET lists retained messages and shows a message by its stable number.
  let list = get(mailbox, "/dev/mailbox")
  assert list.status == 200
  assert string.contains(list.body, "Sign in")
  let detail = get(mailbox, "/dev/mailbox/1")
  assert detail.status == 200
  assert string.contains(detail.body, "alice@example.com")

  // Every other method, unknown message and path outside the mount is refused.
  let post =
    correio_mailbox.handle(
      mailbox,
      request.new()
        |> request.set_method(http.Post)
        |> request.set_path("/dev/mailbox"),
    )
  assert post.status == 405
  assert get(mailbox, "/dev/mailbox/999").status == 404
  assert get(mailbox, "/elsewhere").status == 404

  let assert Ok(Nil) = capture.stop(outbox)
  Nil
}

// snips-start: mailbox-handler
fn get(mailbox: correio_mailbox.Mailbox, path: String) {
  correio_mailbox.handle(mailbox, request.new() |> request.set_path(path))
}
// snips-end: mailbox-handler
