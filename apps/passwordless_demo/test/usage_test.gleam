//// Runs every usage example. The examples under `src/usage` are the
//// documentation of how to use Correio, so API drift fails these tests.

import gleeunit
import usage/capture_flow
import usage/compose_message
import usage/delivery_outcomes
import usage/development_mailbox
import usage/passwordless_memory
import usage/passwordless_postgres

pub fn main() {
  gleeunit.main()
}

@external(erlang, "correio_demo_test_ffi", "database_url")
fn database_url() -> String

pub fn compose_message_test() {
  compose_message.run()
}

pub fn delivery_outcomes_test() {
  delivery_outcomes.run()
}

pub fn capture_flow_test() {
  capture_flow.run()
}

pub fn development_mailbox_test() {
  development_mailbox.run()
}

pub fn passwordless_memory_test() {
  passwordless_memory.run()
}

/// Needs a disposable PostgreSQL: `scripts/with-postgres.sh gleam test`.
pub fn passwordless_postgres_test() {
  passwordless_postgres.run(database_url())
}
