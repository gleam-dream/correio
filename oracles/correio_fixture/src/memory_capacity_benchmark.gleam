//// Issue latency of the memory store at capacity. Prints one JSON line per
//// case. Run with `gleam run -m memory_capacity_benchmark`; no database needed.

import correio/passwordless
import correio/passwordless/memory
import gleam/int
import gleam/io
import gleam/list

const key = <<"benchmark-only-application-key-not-for-deployment">>

const capacity = 100_000

const samples = 200

pub fn main() {
  // Every retained challenge expires at the same instant, then issuance resumes.
  run("expired_together", fn(clock, service) {
    fill(service)
    clock_set(clock, 1_000_000)
    fn() { issue(service) }
  })
  // One retained challenge expires per millisecond and each issue arrives one
  // millisecond after the previous one, so each issue can free one slot at most.
  run("expired_one_per_issue", fn(clock, service) {
    list.repeat(Nil, capacity)
    |> list.each(fn(_) {
      clock_set(clock, clock_get(clock) + 1)
      issue(service)
    })
    fn() {
      clock_set(clock, clock_get(clock) + 1)
      issue(service)
    }
  })
  // Nothing has expired: every issue is refused.
  run("none_expired", fn(_clock, service) {
    fill(service)
    fn() { issue(service) }
  })
}

fn run(
  name: String,
  prepare: fn(Clock, passwordless.Service(Int)) -> fn() -> String,
) -> Nil {
  let clock = clock_new(0)
  let assert Ok(runtime) =
    memory.start_with_clock(capacity, fn() { clock_get(clock) })
  let assert Ok(service) =
    passwordless.new(memory.store(runtime), "benchmark", "login", key)
  // Validity 100 s, retention 1 day, on the injected millisecond clock.
  let assert Ok(service) =
    passwordless.with_policy(service, 100_000, 5, 86_400_000)
  let operation = prepare(clock, service)
  let observed =
    list.repeat(Nil, samples)
    |> list.map(fn(_) {
      let start = micros()
      let outcome = operation()
      #(micros() - start, outcome)
    })
  let latencies =
    list.map(observed, fn(pair) { pair.0 }) |> list.sort(int.compare)
  let issued = list.count(observed, fn(pair) { pair.1 == "issued" })
  io.println(
    "{\"case\":\""
    <> name
    <> "\",\"capacity\":"
    <> int.to_string(capacity)
    <> ",\"samples\":"
    <> int.to_string(samples)
    <> ",\"issued\":"
    <> int.to_string(issued)
    <> ",\"p50_us\":"
    <> int.to_string(nth(latencies, samples / 2))
    <> ",\"p95_us\":"
    <> int.to_string(nth(latencies, samples * 95 / 100))
    <> ",\"max_us\":"
    <> int.to_string(nth(latencies, samples - 1))
    <> "}",
  )
  let assert Ok(_) = memory.stop(runtime)
  Nil
}

fn fill(service: passwordless.Service(Int)) -> Nil {
  list.repeat(Nil, capacity) |> list.each(fn(_) { issue(service) })
}

fn issue(service: passwordless.Service(Int)) -> String {
  case
    passwordless.issue(
      service,
      17,
      "reader@example.test",
      passwordless.MagicLink,
    )
  {
    Ok(_) -> "issued"
    Error(_) -> "refused"
  }
}

fn nth(values: List(Int), index: Int) -> Int {
  case list.drop(values, index) {
    [value, ..] -> value
    [] -> 0
  }
}

type Clock

@external(erlang, "benchmark_ffi", "clock_new")
fn clock_new(now: Int) -> Clock

@external(erlang, "benchmark_ffi", "clock_get")
fn clock_get(clock: Clock) -> Int

@external(erlang, "benchmark_ffi", "clock_set")
fn clock_set(clock: Clock, now: Int) -> Nil

@external(erlang, "benchmark_ffi", "micros")
fn micros() -> Int
