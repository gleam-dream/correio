import correio/address
import correio/capture
import correio/delivery
import correio/message
import gleeunit/should

fn mail() -> message.Message {
  let assert Ok(a) = address.parse("a@example.com")
  let assert Ok(mail) = message.new(a, a, "Subject", message.Text("body"))
  mail
}

pub fn capture_is_bounded_explicit_and_isolated_test() {
  let assert Ok(first) = capture.start(1)
  let assert Ok(second) = capture.start(1)
  let mail = mail()
  let assert delivery.Accepted(_) = capture.send(first, mail)
  capture.send(first, mail)
  |> should.equal(delivery.NotSent(delivery.CapacityReached))
  capture.messages(first) |> should.equal(Ok([mail]))
  capture.messages(second) |> should.equal(Ok([]))
  capture.clear(first) |> should.equal(Ok(Nil))
  capture.messages(first) |> should.equal(Ok([]))
  capture.stop(first) |> should.equal(Ok(Nil))
  capture.send(first, mail)
  |> should.equal(delivery.NotSent(delivery.CaptureUnavailable))
  capture.stop(second) |> should.equal(Ok(Nil))
}

pub fn invalid_capture_capacity_is_refused_test() {
  capture.start(0) |> should.equal(Error(capture.InvalidCapacity))
  capture.start(-1) |> should.equal(Error(capture.InvalidCapacity))
  capture.start(10_001) |> should.equal(Error(capture.InvalidCapacity))
}
