//// Provider acceptance is submission evidence, never inbox delivery.

import correio/address.{type Address}
import correio/message.{type Message, type MessageError}
import gleam/option.{type Option}

pub type Sender =
  fn(Message) -> Outcome

pub type Receipt {
  Receipt(provider_id: Option(String), recipients: List(Address))
}

pub type Rejection {
  Temporary
  Permanent
}

pub type Failure {
  InvalidMessage(MessageError)
  ConnectionUnavailable
  DeadlineExceeded
  AuthenticationFailed
  TransportSecurity
  AdapterFailure
  CaptureUnavailable
  CapacityReached
  UnsupportedCapability(Capability)
  ProviderLimitExceeded
}

pub type Capability {
  EnvelopeSenderOverride
}

pub type Outcome {
  Accepted(Receipt)
  NotSent(Failure)
  Rejected(Rejection)
  OutcomeUnknown
}

/// Safe diagnostic text omits addresses, body content and provider responses.
pub fn describe(outcome: Outcome) -> String {
  case outcome {
    Accepted(_) ->
      "Provider accepted the submission; inbox delivery is unconfirmed."
    NotSent(InvalidMessage(_)) -> "Message admission refused the submission."
    NotSent(ConnectionUnavailable) ->
      "Connection unavailable before submission."
    NotSent(DeadlineExceeded) -> "Deadline elapsed before submission."
    NotSent(AuthenticationFailed) ->
      "Transport authentication failed before submission."
    NotSent(TransportSecurity) -> "Transport security failed before submission."
    NotSent(AdapterFailure) -> "Adapter failed before submission."
    NotSent(CaptureUnavailable) -> "Capture runtime is unavailable."
    NotSent(CapacityReached) -> "Capture capacity is exhausted."
    NotSent(UnsupportedCapability(_)) ->
      "The selected provider cannot preserve a requested message capability."
    NotSent(ProviderLimitExceeded) ->
      "The message exceeds the selected provider's admission limits."
    Rejected(Temporary) -> "Provider temporarily rejected the submission."
    Rejected(Permanent) -> "Provider permanently rejected the submission."
    OutcomeUnknown -> "Submission may have occurred; automatic retry is unsafe."
  }
}
