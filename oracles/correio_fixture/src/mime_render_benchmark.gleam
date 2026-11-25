//// Render time of one message per body shape, through `mime.render`. Prints
//// one JSON line per case with the median and range of the renders, in
//// microseconds. Run with `gleam run -m mime_render_benchmark`; no database
//// needed.

import correio/address
import correio/message
import correio/mime
import gleam/int
import gleam/io
import gleam/list
import gleam/string

const renders = 7

const mebibyte = 1_048_576

pub fn main() {
  run(
    "small_alternative",
    message.Alternative(
      "Use this link to sign in:\nhttps://example.test/login?token=abc",
      "<p><a href=\"https://example.test/login?token=abc\">Sign in</a></p>",
    ),
  )
  // Each 1 MiB body repeats one line: 7bit, quoted-printable and base64.
  run(
    "mebibyte_ascii",
    message.Text(fill(
      "The quick brown fox jumps over the lazy dog, again and again.\n",
    )),
  )
  run(
    "mebibyte_portuguese",
    message.Text(fill(
      "Olá, a reunião começa às nove; não se atrase, por favor, João.\n",
    )),
  )
  run("mebibyte_japanese", message.Text(fill("これは日本語の本文です。会議は九時に始まります。\n")))
}

fn fill(line: String) -> String {
  string.repeat(line, mebibyte / string.byte_size(line))
}

fn run(name: String, body: message.Body) -> Nil {
  let assert Ok(from) = address.parse("sender@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) = message.new(from, to, "Benchmark", body)
  // One warmup render, then the measured ones.
  let assert Ok(_) = mime.render(mail)
  let samples =
    list.repeat(Nil, renders)
    |> list.map(fn(_) {
      let start = micros()
      let assert Ok(_) = mime.render(mail)
      micros() - start
    })
    |> list.sort(int.compare)
  let at = fn(index) {
    let assert [value, ..] = list.drop(samples, index)
    int.to_string(value)
  }
  io.println(
    "{\"case\":\""
    <> name
    <> "\",\"renders\":"
    <> int.to_string(renders)
    <> ",\"median_us\":"
    <> at(renders / 2)
    <> ",\"min_us\":"
    <> at(0)
    <> ",\"max_us\":"
    <> at(renders - 1)
    <> "}",
  )
}

@external(erlang, "benchmark_ffi", "micros")
fn micros() -> Int
