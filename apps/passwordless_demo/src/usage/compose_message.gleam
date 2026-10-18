//// Construct a message: addresses, recipients, custom header, inline
//// attachment and an explicit envelope sender. Nothing here sends mail.

import correio/address
import correio/message
import gleam/list
import gleam/option.{Some}
import gleam/result

pub fn run() -> Nil {
  // Parse addresses with ordinary `Result` handling. A display name is optional.
  let assert Ok(from) =
    address.parse("hello@example.com")
    |> result.try(address.named(_, "Correio Store"))
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(copy) = address.parse("copy@example.com")
  let assert Ok(audit) = address.parse("audit@example.com")
  let assert Ok(support) = address.parse("support@example.com")
  let assert Ok(bounce) = address.parse("bounces@example.com")

  let assert Ok(mail) =
    message.new(
      from,
      to,
      "Your order",
      message.Alternative(
        "Your order is ready.",
        "<p>Your order is ready.</p><img src=\"cid:logo\">",
      ),
    )
  let assert Ok(mail) = message.header(mail, "X-Order-Id", "42")
  let assert Ok(logo) =
    message.attachment(
      "logo.png",
      "image/png",
      <<0, 1, 2, 255>>,
      message.Inline("logo"),
    )
  let mail =
    mail
    |> message.add_cc(copy)
    |> message.add_bcc(audit)
    |> message.set_reply_to(support)
    |> message.set_envelope_sender(bounce)
    |> message.attach(logo)

  // The view is a read-only projection of what will be submitted.
  let view = message.view(mail)
  assert view.subject == "Your order"
  assert view.reply_to == Some(support)
  assert view.headers == [#("X-Order-Id", "42")]
  assert list.length(view.attachments) == 1

  // The envelope sender is distinct from the visible From. Cc and Bcc
  // recipients appear in the envelope, never in the visible headers.
  let #(envelope_sender, recipients) = message.envelope(mail)
  assert address.email(envelope_sender) == "bounces@example.com"
  assert list.map(recipients, address.email)
    == ["reader@example.com", "copy@example.com", "audit@example.com"]

  // Invalid input is a typed error, never a panic. A subject containing a
  // line break would allow header injection and is refused.
  assert message.new(from, to, "Hi\r\nBcc: x@example.com", message.Text("body"))
    == Error(message.InvalidSubject)
  assert message.new(from, to, "Subject", message.Text(""))
    == Error(message.EmptyBody)
  assert message.header(mail, "Subject", "overridden")
    == Error(message.ReservedHeader)
  assert address.parse("not an address") |> result.is_error
  Nil
}
