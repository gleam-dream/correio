//// Compile the root README's public examples. Tests never contact this provider.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/passwordless
import correio/passwordless/memory
import correio/smtp
import correio/testing

pub fn send_welcome() -> delivery.Outcome {
  let assert Ok(from) = address.parse("hello@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) =
    message.new(
      from,
      to,
      "Welcome",
      message.Alternative("Welcome aboard.", "<p>Welcome aboard.</p>"),
    )
  let assert Ok(transport) = smtp.starttls("smtp.example.com", 587)
  smtp.send(transport, mail)
}

pub type AccountId {
  AccountId(Int)
}

pub fn service(key: BitArray) {
  let assert Ok(runtime) = memory.start(1000)
  let assert Ok(auth) =
    passwordless.new(memory.store(runtime), "example-app", "login", key)
  #(runtime, auth)
}

/// Application callback receives the injected capture sender.
pub fn test_email_flow(
  recipient: address.Address,
  trigger: fn(delivery.Sender) -> Nil,
) {
  let assert Ok(outbox) = capture.start(100)
  let assert Ok(checkpoint) = capture.checkpoint(outbox)
  trigger(capture.sender(outbox))
  let assert Ok(mail) =
    testing.await(checkpoint, matching: testing.to(recipient), timeout_ms: 1000)
  let assert Ok(Nil) = capture.stop(outbox)
  mail
}
