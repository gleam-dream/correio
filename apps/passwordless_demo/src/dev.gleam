//// Run with `gleam run -m dev`. This local-only example stores all state in memory.

import correio/passwordless
import correio/passwordless/memory
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor as supervisor
import passwordless_demo

pub fn main() {
  let challenges = process.new_name("local_demo_challenges")
  let assert Ok(config) = memory.new(challenges, 1000)
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(memory.supervised(config))
    |> supervisor.start
  let assert Ok(service) =
    passwordless.new(memory.store(challenges), "local-demo", "login", <<
      "local-development-key-not-for-production":utf8,
    >>)
  let assert Ok(app) = passwordless_demo.start_with_mailbox(service)
  io.println("Sign-in form: " <> passwordless_demo.origin(app))
  io.println(
    "Development mailbox: " <> passwordless_demo.origin(app) <> "/dev/mailbox",
  )
  io.println(
    "Use alice@example.com. Stop with Ctrl-C. State disappears on exit.",
  )
  process.receive_forever(process.new_subject())
}
