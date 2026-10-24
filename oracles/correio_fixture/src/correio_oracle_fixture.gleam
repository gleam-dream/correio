import gleam/json
import oracle_auth
import oracle_email

pub fn main() {
  let email = oracle_email.run(read("../fixtures/email.json"))
  let #(sequential, concurrent) = oracle_auth.run()
  let output =
    json.object([
      #("email", email),
      #("phoenix", sequential),
      #("ash", concurrent),
    ])
    |> json.to_string
  write(env("CORREIO_ORACLE_RESULTS") <> "/correio.json", output)
}

@external(erlang, "oracle_fixture_ffi", "read")
fn read(path: String) -> String

@external(erlang, "oracle_fixture_ffi", "write")
fn write(path: String, contents: String) -> Nil

@external(erlang, "oracle_fixture_ffi", "env")
fn env(name: String) -> String
