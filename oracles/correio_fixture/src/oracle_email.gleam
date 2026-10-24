import correio/address
import correio/message
import correio/mime
import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn run(input: String) -> json.Json {
  let assert Ok(fixtures) = json.parse(input, decode.list(decode.dynamic))
  fixtures |> list.map(render) |> json.object
}

fn field(data: Dynamic, name: String, decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) = decode.run(data, decode.at([name], decoder))
  value
}

fn optional(
  data: Dynamic,
  name: String,
  decoder: decode.Decoder(a),
  default: a,
) -> a {
  decode.run(data, decode.at([name], decoder)) |> result.unwrap(default)
}

fn mailbox(data: Dynamic) -> address.Address {
  let assert Ok(mailbox) = address.parse(field(data, "address", decode.string))
  case optional(data, "name", decode.optional(decode.string), None) {
    None -> mailbox
    Some(name) -> {
      let assert Ok(named) = address.named(mailbox, name)
      named
    }
  }
}

fn render(data: Dynamic) -> #(String, json.Json) {
  let id = field(data, "id", decode.string)
  let sender = field(data, "from", decode.dynamic) |> mailbox
  let assert [first, ..rest] =
    field(data, "to", decode.list(decode.dynamic)) |> list.map(mailbox)
  let text = optional(data, "text", decode.optional(decode.string), None)
  let html = optional(data, "html", decode.optional(decode.string), None)
  let body = case text, html {
    Some(text), Some(html) -> message.Alternative(text, html)
    Some(text), None -> message.Text(text)
    None, Some(html) -> message.Html(html)
    None, None -> panic as "fixture lacks body"
  }
  let assert Ok(mail) =
    message.new(sender, first, field(data, "subject", decode.string), body)
  let mail = list.fold(rest, mail, message.add_to)
  let mail =
    list.fold(
      optional(data, "cc", decode.list(decode.dynamic), []),
      mail,
      fn(mail, item) { message.add_cc(mail, mailbox(item)) },
    )
  let mail =
    list.fold(
      optional(data, "bcc", decode.list(decode.dynamic), []),
      mail,
      fn(mail, item) { message.add_bcc(mail, mailbox(item)) },
    )
  let mail = case
    optional(data, "reply_to", decode.optional(decode.dynamic), None)
  {
    None -> mail
    Some(reply) -> message.set_reply_to(mail, mailbox(reply))
  }
  let headers =
    optional(
      data,
      "headers",
      decode.dict(decode.string, decode.string),
      dict.new(),
    )
    |> dict.to_list
  let mail =
    list.fold(headers, mail, fn(mail, pair) {
      let assert Ok(mail) = message.header(mail, pair.0, pair.1)
      mail
    })
  let mail =
    list.fold(
      optional(data, "attachments", decode.list(decode.dynamic), []),
      mail,
      fn(mail, item) {
        let disposition = case field(item, "disposition", decode.string) {
          "inline" -> message.Inline(field(item, "cid", decode.string))
          "attachment" -> message.AttachmentFile
          _ -> panic as "unknown fixture disposition"
        }
        let assert Ok(bytes) =
          bit_array.base64_decode(field(item, "body_base64", decode.string))
        let assert Ok(attachment) =
          message.attachment(
            field(item, "filename", decode.string),
            field(item, "content_type", decode.string),
            bytes,
            disposition,
          )
        message.attach(mail, attachment)
      },
    )
  let assert Ok(raw) = mime.render(mail)
  let #(sender, recipients) = message.envelope(mail)
  #(
    id,
    json.object([
      #("raw_base64", json.string(bit_array.base64_encode(raw, True))),
      #(
        "envelope",
        json.object([
          #("sender", json.string(address.email(sender))),
          #(
            "recipients",
            recipients
              |> list.map(address.email)
              |> json.array(json.string),
          ),
        ]),
      ),
    ]),
  )
}
