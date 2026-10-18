//// Deliver through an injected `delivery.Sender` and act on each outcome.
//// Correio never retries; the application decides, and an unknown outcome
//// must not be retried because it may duplicate the message.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/smtp
import gleam/result

pub type Next {
  /// The provider accepted the submission. Inbox delivery is unconfirmed.
  Done
  /// Nothing was submitted. Fix the cause, then submitting again is safe.
  SafeToRetry
  /// The provider refused the message. Retry only a temporary refusal.
  Refused(retry_later: Bool)
  /// The message may have been transmitted. Do not resend automatically.
  Investigate
}

pub fn next(outcome: delivery.Outcome) -> Next {
  case outcome {
    delivery.Accepted(_) -> Done
    delivery.NotSent(_) -> SafeToRetry
    delivery.Rejected(delivery.Temporary) -> Refused(retry_later: True)
    delivery.Rejected(delivery.Permanent) -> Refused(retry_later: False)
    delivery.OutcomeUnknown -> Investigate
  }
}

/// Application code depends on the `Sender` function, not on a provider.
pub fn notify(sender: delivery.Sender, mail: message.Message) -> Next {
  sender(mail) |> next
}

fn mail() -> message.Message {
  let assert Ok(from) = address.parse("hello@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) =
    message.new(from, to, "Welcome", message.Text("Welcome aboard."))
  mail
}

pub fn run() -> Nil {
  let mail = mail()

  // A capture is an explicitly owned, bounded sender for local use and tests.
  let assert Ok(box) = capture.start(1)
  let sender = capture.sender(box)
  assert notify(sender, mail) == Done
  // The capture is full: nothing was submitted, so a retry is safe.
  assert sender(mail) == delivery.NotSent(delivery.CapacityReached)
  assert notify(sender, mail) == SafeToRetry
  let assert Ok(Nil) = capture.clear(box)
  assert notify(sender, mail) == Done
  let assert Ok(Nil) = capture.stop(box)

  // Scripted senders stand in for provider outcomes without any network.
  assert notify(fn(_) { delivery.Rejected(delivery.Temporary) }, mail)
    == Refused(retry_later: True)
  assert notify(fn(_) { delivery.Rejected(delivery.Permanent) }, mail)
    == Refused(retry_later: False)
  assert notify(fn(_) { delivery.OutcomeUnknown }, mail) == Investigate

  // SMTP is configured as data and injected the same way. Configuration
  // contacts no server; only `smtp.send` or the sender it returns does.
  let assert Ok(config) =
    smtp.starttls("smtp.example.com", 587) |> result.try(smtp.deadline(_, 5000))
  let _smtp_sender: delivery.Sender = smtp.sender(config)
  assert result.is_error(smtp.starttls("", 587))

  // Safe diagnostics omit addresses, bodies and provider responses.
  assert delivery.describe(delivery.OutcomeUnknown) != ""
  Nil
}
