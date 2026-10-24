import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/testing
import gleeunit/should

fn mail(subject: String) -> message.Message {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, subject, message.Text("body"))
  mail
}

pub fn checkpoint_excludes_old_mail_and_survives_clear_test() {
  let assert Ok(capture) = capture.start(3)
  let old = mail("old")
  let new = mail("new")
  let assert delivery.Accepted(_) = capture.send(capture, old)
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  capture.clear(capture) |> should.equal(Ok(Nil))
  let assert delivery.Accepted(_) = capture.send(capture, new)
  capture.entries(capture) |> should.equal(Ok([capture.Entry(2, new)]))
  capture.since(checkpoint) |> should.equal(Ok([new]))
  testing.await(checkpoint, fn(_) { True }, 0) |> should.equal(Ok(new))
  capture.stop(capture) |> should.equal(Ok(Nil))
}

pub fn checkpoint_binding_and_earliest_matching_message_test() {
  let assert Ok(first) = capture.start(4)
  let assert Ok(second) = capture.start(1)
  let assert delivery.Accepted(_) = capture.send(first, mail("old"))
  let assert Ok(checkpoint) = capture.checkpoint(first)
  let assert delivery.Accepted(_) = capture.send(second, mail("other"))
  testing.await(checkpoint, fn(_) { True }, 0)
  |> should.equal(Error(testing.TimedOut))
  let assert delivery.Accepted(_) = capture.send(first, mail("skip"))
  let assert delivery.Accepted(_) = capture.send(first, mail("match"))
  let assert delivery.Accepted(_) = capture.send(first, mail("later"))
  testing.await(checkpoint, fn(m) { message.view(m).subject != "skip" }, 0)
  |> should.equal(Ok(mail("match")))
  capture.stop(first) |> should.equal(Ok(Nil))
  capture.stop(second) |> should.equal(Ok(Nil))
}

pub fn delayed_delivery_and_stopping_while_waiting_test() {
  let assert Ok(capture) = capture.start(2)
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  let expected = mail("delayed")
  let worker =
    after(30, fn() {
      let assert delivery.Accepted(_) = capture.send(capture, expected)
      Nil
    })
  testing.await(checkpoint, caller_predicate(), 500)
  |> should.equal(Ok(expected))
  join(worker) |> should.be_true
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  let worker =
    after(30, fn() {
      let assert Ok(Nil) = capture.stop(capture)
      Nil
    })
  testing.await(checkpoint, fn(_) { True }, 500)
  |> should.equal(Error(testing.CaptureFailed(capture.Unavailable)))
  join(worker) |> should.be_true
}

pub fn timeout_and_duration_validation_test() {
  let assert Ok(capture) = capture.start(1)
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  testing.await(checkpoint, fn(_) { True }, -1)
  |> should.equal(Error(testing.InvalidTimeout))
  testing.await(checkpoint, fn(_) { True }, 60_001)
  |> should.equal(Error(testing.InvalidTimeout))
  testing.await(checkpoint, fn(_) { True }, 20)
  |> should.equal(Error(testing.TimedOut))
  capture.stop(capture) |> should.equal(Ok(Nil))
  testing.await(checkpoint, fn(_) { True }, 0)
  |> should.equal(Error(testing.CaptureFailed(capture.Unavailable)))
}

pub fn recipient_matching_uses_envelope_including_bcc_test() {
  let assert Ok(blind) = address.parse("Person@EXAMPLE.COM")
  let assert Ok(same) = address.parse("Person@example.com")
  let assert Ok(different_local) = address.parse("person@example.com")
  let assert Ok(named) = address.named(same, "A display name")
  let mail = message.add_bcc(mail("Bcc"), blind)
  testing.to(named)(mail) |> should.be_true
  testing.to(different_local)(mail) |> should.be_false
}

pub fn slow_capture_query_obeys_positive_wait_deadline_test() {
  let assert Ok(capture) = capture.start(1)
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  suspend(capture)
  let started = now()
  let result = testing.await(checkpoint, fn(_) { True }, 30)
  let elapsed = now() - started
  resume(capture)
  result |> should.equal(Error(testing.TimedOut))
  { elapsed >= 20 && elapsed < 500 } |> should.be_true
  capture.stop(capture) |> should.equal(Ok(Nil))
}

pub type Worker

@external(erlang, "correio_testing_test_ffi", "after_delay")
fn after(delay_ms: Int, run: fn() -> Nil) -> Worker

@external(erlang, "correio_testing_test_ffi", "join")
fn join(worker: Worker) -> Bool

@external(erlang, "correio_testing_test_ffi", "suspend")
fn suspend(capture: capture.Capture) -> Nil

@external(erlang, "correio_testing_test_ffi", "resume")
fn resume(capture: capture.Capture) -> Nil

@external(erlang, "correio_testing_test_ffi", "now_ms")
fn now() -> Int

/// A capture query can fail before a longer application wait expires.
pub fn capture_query_deadline_is_distinct_from_flow_timeout_test() {
  let assert Ok(capture) = capture.start(1)
  let assert Ok(checkpoint) = capture.checkpoint(capture)
  suspend(capture)
  let result = testing.await(checkpoint, fn(_) { True }, 5000)
  resume(capture)
  result |> should.equal(Error(testing.CaptureFailed(capture.DeadlineExceeded)))
  capture.stop(capture) |> should.equal(Ok(Nil))
  capture.entries(capture) |> should.equal(Error(capture.Unavailable))
  capture.checkpoint(capture) |> should.equal(Error(capture.Unavailable))
  capture.since(checkpoint) |> should.equal(Error(capture.Unavailable))
}

@external(erlang, "correio_testing_test_ffi", "caller_predicate")
fn caller_predicate() -> fn(message.Message) -> Bool
