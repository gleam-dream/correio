//// Test an application email flow: inject a capture sender, record a
//// checkpoint before triggering the flow, then await the matching message.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/testing

/// The application code under test receives its delivery dependency.
pub fn welcome(
  sender: delivery.Sender,
  recipient: address.Address,
) -> delivery.Outcome {
  let assert Ok(from) = address.parse("hello@example.com")
  let assert Ok(mail) =
    message.new(
      from,
      recipient,
      "Welcome",
      message.Text("Open https://app.example.test/start to begin."),
    )
  sender(mail)
}

pub fn run() -> Nil {
  // snips-start: capture-flow
  let assert Ok(recipient) = address.parse("reader@example.com")
  let assert Ok(other) = address.parse("someone-else@example.com")

  // Give each test its own capture so parallel tests cannot see each other.
  let assert Ok(outbox) = capture.start(100)
  let sender = capture.sender(outbox)

  // Mail sent before the checkpoint can never satisfy the helper.
  let assert delivery.Accepted(_) = welcome(sender, other)
  let assert Ok(checkpoint) = capture.checkpoint(outbox)

  let assert delivery.Accepted(_) = welcome(sender, recipient)
  let assert Ok(mail) =
    testing.await(checkpoint, matching: testing.to(recipient), timeout_ms: 1000)
  assert message.view(mail).subject == "Welcome"
  assert message.view(mail).body
    == message.Text("Open https://app.example.test/start to begin.")

  // Awaiting mail that never arrives is a bounded, typed failure.
  assert testing.await(checkpoint, matching: testing.to(other), timeout_ms: 50)
    == Error(testing.TimedOut)
  assert testing.await(checkpoint, matching: testing.to(other), timeout_ms: -1)
    == Error(testing.InvalidTimeout)

  // Inspection never consumes: since() returns the post-checkpoint messages.
  let assert Ok(after) = capture.since(checkpoint)
  assert after != []
  let assert Ok(Nil) = capture.stop(outbox)
  // snips-end: capture-flow
  Nil
}
