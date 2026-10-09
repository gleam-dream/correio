//// Explicitly owned, bounded local capture for application tests.
//// Captured messages contain secrets; retrieval is an explicit inspection API.

import correio/delivery
import correio/message.{type Message}
import correio/mime
import gleam/option.{None}

pub opaque type Capture {
  Capture(Handle)
}

/// One retained delivery, identified within its capture lifetime.
pub type Entry {
  Entry(id: Int, message: Message)
}

/// A position bound to one capture. Clearing retained messages does not rewind it.
pub opaque type Checkpoint {
  Checkpoint(handle: Handle, position: Int)
}

pub type Error {
  InvalidCapacity
  Unavailable
  DeadlineExceeded
}

pub type Handle

/// Start a capture owned by the calling process. The runtime exits when its
/// owner exits. Capacity must be between 1 and 10,000 complete messages.
pub fn start(capacity: Int) -> Result(Capture, Error) {
  case capacity > 0 && capacity <= 10_000 {
    True -> Ok(Capture(start_runtime(capacity)))
    False -> Error(InvalidCapacity)
  }
}

pub fn send(capture: Capture, message: Message) -> delivery.Outcome {
  case mime.render(message) {
    Error(error) -> delivery.NotSent(delivery.InvalidMessage(error))
    Ok(_) -> {
      let Capture(handle) = capture
      case record(handle, message) {
        Stored ->
          delivery.Accepted(delivery.Receipt(None, message.envelope(message).1))
        Full -> delivery.NotSent(delivery.CapacityReached)
        Stopped -> delivery.NotSent(delivery.CaptureUnavailable)
        Uncertain -> delivery.OutcomeUnknown
      }
    }
  }
}

pub fn sender(capture: Capture) -> delivery.Sender {
  fn(message) { send(capture, message) }
}

pub fn messages(capture: Capture) -> Result(List(Message), Error) {
  let Capture(handle) = capture
  read(handle)
}

/// Return retained entries in delivery order. Identifiers never repeat after clear.
pub fn entries(capture: Capture) -> Result(List(Entry), Error) {
  let Capture(handle) = capture
  read_entries(handle)
}

/// Record the current position before triggering the application flow under test.
pub fn checkpoint(capture: Capture) -> Result(Checkpoint, Error) {
  let Capture(handle) = capture
  case position(handle) {
    Ok(position) -> Ok(Checkpoint(handle, position))
    Error(error) -> Error(error)
  }
}

/// Return retained messages delivered after the checkpoint, in delivery order.
/// Inspection does not consume messages. A checkpoint may be reused.
pub fn since(checkpoint: Checkpoint) -> Result(List(Message), Error) {
  read_since(checkpoint)
}

pub fn clear(capture: Capture) -> Result(Nil, Error) {
  let Capture(handle) = capture
  clear_runtime(handle)
}

pub fn stop(capture: Capture) -> Result(Nil, Error) {
  let Capture(handle) = capture
  stop_runtime(handle)
}

type RecordResult {
  Stored
  Full
  Stopped
  Uncertain
}

@external(erlang, "correio_capture_ffi", "start")
fn start_runtime(capacity: Int) -> Handle

@external(erlang, "correio_capture_ffi", "record")
fn record(handle: Handle, message: Message) -> RecordResult

@external(erlang, "correio_capture_ffi", "read")
fn read(handle: Handle) -> Result(List(Message), Error)

@external(erlang, "correio_capture_ffi", "clear")
fn clear_runtime(handle: Handle) -> Result(Nil, Error)

@external(erlang, "correio_capture_ffi", "stop")
fn stop_runtime(handle: Handle) -> Result(Nil, Error)

@external(erlang, "correio_capture_ffi", "entries")
fn read_entries(handle: Handle) -> Result(List(Entry), Error)

@external(erlang, "correio_capture_ffi", "position")
fn position(handle: Handle) -> Result(Int, Error)

@external(erlang, "correio_capture_ffi", "since")
fn read_since(checkpoint: Checkpoint) -> Result(List(Message), Error)
