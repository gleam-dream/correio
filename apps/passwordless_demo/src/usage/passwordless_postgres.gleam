//// The same verification service over the PostgreSQL adapter: caller-owned
//// named pool, explicit migration, native subject codec and explicit cleanup.

import correio/passwordless
import correio_postgres
import gleam/erlang/process
import gleam/int
import gleam/result
import pog

pub type AccountId {
  AccountId(Int)
}

const demo_key = <<"0123456789abcdef0123456789abcdef":utf8>>

/// `database_url` names a disposable database. The adapter owns its
/// transaction boundary, so pass the pool's name, never an open connection.
pub fn run(database_url: String) -> Nil {
  let name = process.new_name("correio_usage_postgres")
  let assert Ok(config) = pog.url_config(name, database_url)
  let assert Ok(pool) = config |> pog.pool_size(4) |> pog.start

  // Migrate during deployment, never during authentication requests.
  let assert Ok(Nil) = correio_postgres.migrate(pool.data)

  // The codec serializes the application's native subject type.
  let codec =
    correio_postgres.Codec(
      fn(account) {
        let AccountId(value) = account
        int.to_string(value)
      },
      fn(raw) { int.parse(raw) |> result.map(AccountId) },
    )
  let store = correio_postgres.new(name, codec)
  let assert Ok(auth) =
    passwordless.new(store, "example-app", "login", demo_key)
  // Short validity and retention so that cleanup below has work to do.
  let assert Ok(auth) = passwordless.with_policy(auth, 1000, 3, 1)

  let assert Ok(challenge) =
    passwordless.issue(
      auth,
      AccountId(42),
      "alice@example.com",
      passwordless.MagicLink,
    )
  let assert Ok(evidence) =
    passwordless.verify(
      auth,
      passwordless.challenge_id(challenge),
      "alice@example.com",
      passwordless.challenge_answer(challenge),
    )
  assert passwordless.subject(evidence) == AccountId(42)

  // Terminal rows are retained until validity plus retention have elapsed
  // (1000 ms + 1 ms here). Run cleanup explicitly; each call removes at most
  // the given number of eligible rows.
  process.sleep(1200)
  let assert Ok(removed) = store.cleanup(100)
  assert removed >= 1

  process.send_exit(pool.pid)
  Nil
}
