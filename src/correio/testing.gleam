//// Flow assertions over an explicitly owned capture. These helpers inspect mail;
//// they neither deliver messages nor activate links or authentication challenges.

import correio/address.{type Address}
import correio/capture.{type Checkpoint}
import correio/message.{type Message}
import gleam/int
import gleam/list

pub type Error {
  InvalidTimeout
  TimedOut
  CaptureFailed(capture.Error)
}

/// Match a normalized envelope mailbox, including Cc and Bcc. Display names do
/// not affect matching; domains are case-insensitive and local parts retain case.
pub fn to(recipient: Address) -> fn(Message) -> Bool {
  fn(mail) {
    mail
    |> message.envelope
    |> fn(envelope) { envelope.1 }
    |> list.any(fn(candidate) {
      address.email(candidate) == address.email(recipient)
    })
  }
}

/// Return the earliest retained matching message after the checkpoint.
/// Wait duration must be 0 through 60,000 milliseconds. Zero performs one capture
/// inspection (bounded by its one-second query timeout), without polling.
/// Positive waits bound capture queries and polling by a monotonic deadline.
/// Predicates run in the caller, should be pure, and may run more than once;
/// predicate execution time and runtime scheduling remain caller-owned.
/// Inspection is non-consuming, so the same checkpoint can return the same mail.
pub fn await(
  checkpoint: Checkpoint,
  matching matching: fn(Message) -> Bool,
  timeout_ms timeout_ms: Int,
) -> Result(Message, Error) {
  case timeout_ms {
    duration if duration < 0 || duration > 60_000 -> Error(InvalidTimeout)
    0 -> inspect(checkpoint, matching, 1000)
    duration -> poll(checkpoint, matching, now_ms() + duration)
  }
}

fn inspect(
  checkpoint: Checkpoint,
  matching: fn(Message) -> Bool,
  timeout_ms: Int,
) -> Result(Message, Error) {
  case read_since(checkpoint, timeout_ms) {
    Error(error) -> Error(CaptureFailed(error))
    Ok(messages) ->
      case list.find(messages, matching) {
        Ok(message) -> Ok(message)
        Error(Nil) -> Error(TimedOut)
      }
  }
}

fn poll(
  checkpoint: Checkpoint,
  matching: fn(Message) -> Bool,
  deadline: Int,
) -> Result(Message, Error) {
  let remaining = deadline - now_ms()
  case remaining <= 0 {
    True -> Error(TimedOut)
    False -> {
      case inspect(checkpoint, matching, int.min(remaining, 1000)) {
        Ok(message) -> Ok(message)
        Error(CaptureFailed(capture.DeadlineExceeded)) ->
          case now_ms() >= deadline {
            True -> Error(TimedOut)
            False -> Error(CaptureFailed(capture.DeadlineExceeded))
          }
        Error(CaptureFailed(error)) -> Error(CaptureFailed(error))
        Error(InvalidTimeout) -> Error(InvalidTimeout)
        Error(TimedOut) -> {
          let remaining = deadline - now_ms()
          case remaining <= 0 {
            True -> Error(TimedOut)
            False -> {
              sleep(int.min(remaining, 10))
              poll(checkpoint, matching, deadline)
            }
          }
        }
      }
    }
  }
}

@external(erlang, "correio_capture_ffi", "since_for")
fn read_since(
  checkpoint: Checkpoint,
  timeout_ms: Int,
) -> Result(List(Message), capture.Error)

@external(erlang, "correio_capture_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "correio_capture_ffi", "sleep")
fn sleep(milliseconds: Int) -> Nil
