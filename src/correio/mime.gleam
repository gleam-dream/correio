//// RFC 5322 serialization with independent MIME encoding.

import correio/address
import correio/message.{type Body, type Limits, type Message, type MessageError}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result

pub fn render(message: Message) -> Result(BitArray, MessageError) {
  render_with_limits(message, message.default_limits())
}

pub fn render_with_limits(
  message: Message,
  limits: Limits,
) -> Result(BitArray, MessageError) {
  use _ <- result.try(message.validate(message, limits))
  let v = message.view(message)
  let addresses = fn(values) {
    list.map(values, fn(a) { #(address.email(a), address.name(a)) })
  }
  let attachments =
    list.map(v.attachments, fn(a) {
      let a = message.attachment_view(a)
      #(a.filename, a.content_type, a.bytes, a.disposition)
    })
  use raw <- result.try(encode(
    #(address.email(v.from), address.name(v.from)),
    addresses(v.to),
    addresses(v.cc),
    v.subject,
    v.body,
    v.reply_to
      |> gleam_option_map(fn(a) { #(address.email(a), address.name(a)) }),
    v.headers,
    attachments,
  ))
  case bit_array.byte_size(raw) <= message.maximum_submission_bytes(limits) {
    True -> Ok(raw)
    False -> Error(message.SubmissionTooLarge)
  }
}

fn gleam_option_map(value: Option(a), f: fn(a) -> b) -> Option(b) {
  case value {
    option.Some(a) -> option.Some(f(a))
    option.None -> option.None
  }
}

@external(erlang, "correio_mail_ffi", "encode")
fn encode(
  from: #(String, Option(String)),
  to: List(#(String, Option(String))),
  cc: List(#(String, Option(String))),
  subject: String,
  body: Body,
  reply_to: Option(#(String, Option(String))),
  headers: List(#(String, String)),
  attachments: List(#(String, String, BitArray, message.Disposition)),
) -> Result(BitArray, MessageError)
