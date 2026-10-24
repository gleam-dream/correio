import correio/address
import correio/message
import correio/mime
import correio/passwordless
import correio/passwordless/memory
import correio/passwordless/store
import correio_postgres
import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import pog

const key = <<"benchmark-only-application-key-not-for-deployment">>

pub fn main() {
  let pool_name = process.new_name("bench")
  let assert Ok(config) = pog.url_config(pool_name, env("DATABASE_URL"))
  let assert Ok(database) =
    pog.start(config |> pog.pool_size(24) |> pog.queue_target(1000))
  let assert Ok(_) = correio_postgres.migrate(database.data)
  let codec =
    correio_postgres.Codec(fn(value) { value }, fn(value) { Ok(value) })
  let assert Ok(durable) =
    passwordless.new(
      correio_postgres.new(pool_name, codec),
      "benchmark",
      "login",
      key,
    )
  let assert Ok(runtime) = memory.start(100_000)
  let assert Ok(local) =
    passwordless.new(memory.store(runtime), "benchmark", "login", key)
  let mail = message_fixture()
  let mime_case = fn() {
    case mime.render(mail) {
      Ok(_) -> "prepared"
      Error(_) -> "encoding_error"
    }
  }
  let memory_case = fn() { issue_verify(local) }
  let postgres_case = fn() { issue_verify(durable) }
  // Warmup operations execute outside every recorded measurement.
  repeat(100, mime_case)
  repeat(100, memory_case)
  repeat(24, postgres_case)
  let observations =
    [1, 2, 3]
    |> list.flat_map(fn(repetition) {
      [
        measure("mime_prepare", repetition, 1, 1000, mime_case),
        measure("memory_issue_verify", repetition, 1, 500, memory_case),
        measure("postgres_issue_verify", repetition, 1, 120, postgres_case),
        measure("postgres_issue_verify", repetition, 8, 15, postgres_case),
        measure("postgres_issue_verify", repetition, 24, 5, postgres_case),
        contention(durable, repetition),
      ]
    })
  let #(otp, erts, schedulers, architecture) = metadata()
  let output =
    json.object([
      #(
        "runtime",
        json.object([
          #("otp", json.string(otp)),
          #("erts", json.string(erts)),
          #("schedulers_online", json.int(schedulers)),
          #("architecture", json.string(architecture)),
        ]),
      ),
      #(
        "configuration",
        json.object([
          #("warmup_mime", json.int(100)),
          #("warmup_memory", json.int(100)),
          #("warmup_postgres", json.int(24)),
          #("repetitions", json.int(3)),
          #("postgres_pool_size", json.int(24)),
          #("memory_capacity", json.int(100_000)),
          #("challenge_ttl_ms", json.int(600_000)),
          #("attempt_limit", json.int(5)),
          #("retention_ms", json.int(86_400_000)),
          #("attachment_bytes", json.int(4096)),
        ]),
      ),
      #("observations", json.array(observations, fn(value) { value })),
    ])
    |> json.to_string
  write(env("CORREIO_BENCHMARK_RESULTS") <> "/samples.json", output)
  let assert Ok(_) = memory.stop(runtime)
  stop(database.pid)
}

fn issue_verify(service: passwordless.Service(String)) -> String {
  case
    passwordless.issue(
      service,
      "native-account-17",
      "reader@example.test",
      passwordless.MagicLink,
    )
  {
    Error(_) -> "issue_error"
    Ok(challenge) ->
      case
        passwordless.verify(
          service,
          passwordless.challenge_id(challenge),
          "reader@example.test",
          passwordless.challenge_answer(challenge),
        )
      {
        Ok(_) -> "accepted"
        Error(_) -> "verify_error"
      }
  }
}

fn contention(
  service: passwordless.Service(String),
  repetition: Int,
) -> json.Json {
  let assert Ok(challenge) =
    passwordless.issue(
      service,
      "contended-account",
      "reader@example.test",
      passwordless.MagicLink,
    )
  measure("postgres_same_challenge", repetition, 24, 1, fn() {
    case
      passwordless.verify(
        service,
        passwordless.challenge_id(challenge),
        "reader@example.test",
        passwordless.challenge_answer(challenge),
      )
    {
      Ok(_) -> "accepted"
      Error(passwordless.Refused(store.Consumed)) -> "refused"
      Error(_) -> "verify_error"
    }
  })
}

fn measure(
  name: String,
  repetition: Int,
  concurrency: Int,
  per_worker: Int,
  operation: fn() -> String,
) -> json.Json {
  let workers =
    list.repeat(Nil, concurrency)
    |> list.map(fn(_) { fn() { repeat(per_worker, operation) } })
  let #(elapsed, samples) = parallel(workers)
  json.object([
    #("case", json.string(name)),
    #("repetition", json.int(repetition)),
    #("concurrency", json.int(concurrency)),
    #("elapsed_us", json.int(elapsed)),
    #(
      "samples",
      json.array(samples, fn(sample) {
        json.object([
          #("latency_us", json.int(sample.0)),
          #("outcome", json.string(sample.1)),
        ])
      }),
    ),
  ])
}

fn repeat(count: Int, operation: fn() -> String) -> List(#(Int, String)) {
  list.repeat(Nil, count)
  |> list.map(fn(_) {
    let start = micros()
    let outcome = operation()
    #(micros() - start, outcome)
  })
}

fn message_fixture() -> message.Message {
  let assert Ok(sender) = address.parse("sender@example.test")
  let assert Ok(recipient) = address.parse("reader@example.test")
  let assert Ok(mail) =
    message.new(
      sender,
      recipient,
      "Benchmark message",
      message.Alternative("Hello world", "<p>Hello world</p>"),
    )
  let bytes = string.repeat("x", 4096) |> bit_array.from_string
  let assert Ok(attachment) =
    message.attachment(
      "payload.bin",
      "application/octet-stream",
      bytes,
      message.AttachmentFile,
    )
  message.attach(mail, attachment)
}

@external(erlang, "benchmark_ffi", "micros")
fn micros() -> Int

@external(erlang, "benchmark_ffi", "parallel")
fn parallel(
  jobs: List(fn() -> List(#(Int, String))),
) -> #(Int, List(#(Int, String)))

@external(erlang, "benchmark_ffi", "metadata")
fn metadata() -> #(String, String, Int, String)

@external(erlang, "oracle_fixture_ffi", "env")
fn env(name: String) -> String

@external(erlang, "oracle_fixture_ffi", "write")
fn write(path: String, value: String) -> Nil

@external(erlang, "oracle_fixture_ffi", "stop")
fn stop(pid: process.Pid) -> Nil
