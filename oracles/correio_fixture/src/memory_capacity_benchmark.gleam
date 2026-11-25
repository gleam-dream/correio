//// Issue latency of the memory store at capacity. Prints one JSON line per
//// case. Run with `gleam run -m memory_capacity_benchmark`; no database needed.
//// A capacity refusal is an observation. Any other issue failure is an
//// infrastructure failure: it is counted, and the command fails after every
//// case has printed its line.

import correio/passwordless
import correio/passwordless/memory
import correio/passwordless/store
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/static_supervisor as supervisor

const key = <<"benchmark-only-application-key-not-for-deployment">>

const capacity = 100_000

const samples = 200

pub fn main() {
  let errors =
    [
      run_expired_together(),
      run_expired_one_per_issue(),
      run_none_expired(),
    ]
    |> int.sum
  case errors {
    0 -> Nil
    _ -> panic as { int.to_string(errors) <> " infrastructure failures" }
  }
}

fn run_expired_together() -> Int {
  // Every retained challenge expires at the same instant, then issuance resumes.
  run("expired_together", fn(clock, service) {
    fill(service)
    clock_set(clock, 1_000_000)
    fn() { issue(service) }
  })
}

fn run_expired_one_per_issue() -> Int {
  // One retained challenge expires per millisecond and each issue arrives one
  // millisecond after the previous one, so each issue can free one slot at most.
  run("expired_one_per_issue", fn(clock, service) {
    list.repeat(Nil, capacity)
    |> list.each(fn(_) {
      clock_set(clock, clock_get(clock) + 1)
      prepared(issue(service))
    })
    fn() {
      clock_set(clock, clock_get(clock) + 1)
      issue(service)
    }
  })
}

fn run_none_expired() -> Int {
  // Nothing has expired: every issue is refused.
  run("none_expired", fn(_clock, service) {
    fill(service)
    fn() { issue(service) }
  })
}

fn run(
  name: String,
  prepare: fn(Clock, passwordless.Service(Int)) -> fn() -> String,
) -> Int {
  let clock = clock_new(0)
  let challenges = process.new_name("benchmark_challenges")
  let assert Ok(config) = memory.new(challenges, capacity)
  let assert Ok(challenge_supervisor) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(
      memory.supervised(memory.with_clock(config, fn() { clock_get(clock) })),
    )
    |> supervisor.start
  let assert Ok(service) =
    passwordless.new(memory.store(challenges), "benchmark", "login", key)
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
  let refused = list.count(observed, fn(pair) { pair.1 == "refused" })
  let errors = list.count(observed, fn(pair) { pair.1 == "error" })
  io.println(
    "{\"case\":\""
    <> name
    <> "\",\"capacity\":"
    <> int.to_string(capacity)
    <> ",\"samples\":"
    <> int.to_string(samples)
    <> ",\"issued\":"
    <> int.to_string(issued)
    <> ",\"refused\":"
    <> int.to_string(refused)
    <> ",\"errors\":"
    <> int.to_string(errors)
    <> ",\"p50_us\":"
    <> int.to_string(nearest_rank(latencies, 50))
    <> ",\"p95_us\":"
    <> int.to_string(nearest_rank(latencies, 95))
    <> ",\"max_us\":"
    <> int.to_string(nearest_rank(latencies, 100))
    <> "}",
  )
  process.unlink(challenge_supervisor.pid)
  process.kill(challenge_supervisor.pid)
  errors
}

/// Fills the store to capacity. Preparation must issue every challenge, so
/// measurement always starts from a full store.
fn fill(service: passwordless.Service(Int)) -> Nil {
  list.repeat(Nil, capacity) |> list.each(fn(_) { prepared(issue(service)) })
}

fn prepared(outcome: String) -> Nil {
  case outcome {
    "issued" -> Nil
    _ -> panic as { "preparation did not issue: " <> outcome }
  }
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
    Error(passwordless.IssueFailed(store.Capacity)) -> "refused"
    Error(_) -> "error"
  }
}

/// The nearest-rank percentile of sorted values: the value at rank
/// ceil(percent * n / 100), counted from one.
fn nearest_rank(values: List(Int), percent: Int) -> Int {
  nth(values, { percent * list.length(values) + 99 } / 100 - 1)
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
