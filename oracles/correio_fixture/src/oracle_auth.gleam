import correio/passwordless
import correio/passwordless/store
import correio_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import pog

const key = <<"local-oracle-application-key-32-bytes-minimum">>

type Pool {
  Pool(name: process.Name(pog.Message), data: pog.Connection, pid: process.Pid)
}

fn service(db: Pool, purpose: String) -> passwordless.Service(String) {
  let codec =
    correio_postgres.Codec(fn(value) { value }, fn(value) { Ok(value) })
  let assert Ok(service) =
    passwordless.new(
      correio_postgres.new(db.name, codec),
      "oracle",
      purpose,
      key,
    )
  service
}

fn pool() {
  let name = process.new_name("oracle")
  let assert Ok(config) = pog.url_config(name, env("DATABASE_URL"))
  let assert Ok(started) = pog.start(config |> pog.pool_size(1))
  Pool(name, started.data, started.pid)
}

pub fn run() -> #(json.Json, json.Json) {
  let database = pool()
  let assert Ok(_) = correio_postgres.migrate(database.data)
  let sequential =
    ["valid", "reuse", "expired", "wrong_purpose", "wrong_destination"]
    |> list.map(fn(name) {
      #(name, json.string(sequential_case(database, name)))
    })
    |> json.object
  let workers = list.repeat(Nil, 24) |> list.map(fn(_) { pool() })
  let concurrent =
    [1, 2, 3]
    |> list.map(fn(round) { concurrent_case(database, workers, round) })
    |> json.array(fn(value) { value })
  list.each(workers, fn(worker) { stop(worker.pid) })
  stop(database.pid)
  #(sequential, concurrent)
}

fn sequential_case(db: Pool, name: String) -> String {
  let original = service(db, "login")
  let assert Ok(challenge) =
    passwordless.issue(
      original,
      "account-" <> name,
      "reader@example.test",
      passwordless.MagicLink,
    )
  let id = passwordless.challenge_id(challenge)
  let answer = passwordless.challenge_answer(challenge)
  case name {
    "reuse" -> {
      let assert Ok(_) =
        passwordless.verify(original, id, "reader@example.test", answer)
      Nil
    }
    "expired" -> {
      let assert Ok(_) =
        pog.query(
          "UPDATE ecarta_challenges SET expires_at_ms = 1 WHERE id = $1",
        )
        |> pog.parameter(pog.text(id))
        |> pog.execute(db.data)
      Nil
    }
    _ -> Nil
  }
  let verifier = case name {
    "wrong_purpose" -> service(db, "change_email")
    _ -> original
  }
  let destination = case name {
    "wrong_destination" -> "changed@example.test"
    _ -> "reader@example.test"
  }
  case passwordless.verify(verifier, id, destination, answer) {
    Ok(_) -> "accepted"
    Error(passwordless.Refused(_)) -> "rejected"
    Error(_) -> panic as "storage failure is not authentication refusal"
  }
}

fn backend(db: pog.Connection) -> Int {
  let assert Ok(result) =
    pog.query("SELECT pg_backend_pid()")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db)
  let assert [id] = result.rows
  id
}

fn concurrent_case(db: Pool, connections: List(Pool), round: Int) -> json.Json {
  let original = service(db, "login")
  let assert Ok(challenge) =
    passwordless.issue(
      original,
      "race-" <> int.to_string(round),
      "reader@example.test",
      passwordless.MagicLink,
    )
  let id = passwordless.challenge_id(challenge)
  let answer = passwordless.challenge_answer(challenge)
  let preparations =
    connections
    |> list.map(fn(connection) {
      fn() {
        let before = backend(connection.data)
        #(before, fn() {
          let accepted = case
            passwordless.verify(
              service(connection, "login"),
              id,
              "reader@example.test",
              answer,
            )
          {
            Ok(_) -> True
            Error(passwordless.Refused(store.Consumed)) -> False
            Error(_) -> panic as "unexpected concurrent verification result"
          }
          let assert True = before == backend(connection.data)
          accepted
        })
      }
    })
  let observations = race(preparations)
  let successes =
    observations |> list.filter(fn(value) { value.1 }) |> list.length
  let assert True = successes == 1
  let assert Error(passwordless.Refused(store.Consumed)) =
    passwordless.verify(original, id, "reader@example.test", answer)
  json.object([
    #("round", json.int(round)),
    #("attempts", json.int(24)),
    #("successes", json.int(successes)),
    #("rejections", json.int(24 - successes)),
    #(
      "backend_ids",
      observations |> list.map(fn(value) { value.0 }) |> json.array(json.int),
    ),
  ])
}

@external(erlang, "oracle_fixture_ffi", "race")
fn race(preparations: List(fn() -> #(Int, fn() -> Bool))) -> List(#(Int, Bool))

@external(erlang, "oracle_fixture_ffi", "env")
fn env(name: String) -> String

@external(erlang, "oracle_fixture_ffi", "stop")
fn stop(pid: process.Pid) -> Nil
