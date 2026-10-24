//// Postmark single-message delivery over a caller-owned HTTP Gun client.
//// The adapter never starts or stops the client and never retries submission.
//// Production uses a fixed HTTPS origin. Local tests opt into loopback HTTP.

import correio/address
import correio/delivery
import correio/message
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import http_gun/redaction as http_redaction

pub const server_token_header = "x-postmark-server-token"

pub opaque type Config {
  Config(
    client: http_gun.Client,
    token: String,
    local_port: Option(Int),
    timeout_ms: Int,
    response_bytes: Int,
    message_limits: message.Limits,
  )
}

pub type ConfigError {
  InvalidToken
  InvalidPort
  InvalidDeadline
  InvalidResponseLimit
  InvalidTag
  InvalidStream
  InvalidMetadata
}

pub type LinkTracking {
  NoLinks
  HtmlAndText
  HtmlOnly
  TextOnly
}

pub opaque type Options {
  Options(
    tag: Option(String),
    stream: Option(String),
    metadata: List(#(String, String)),
    track_opens: Option(Bool),
    track_links: Option(LinkTracking),
  )
}

pub fn new(
  client: http_gun.Client,
  server_token: String,
) -> Result(Config, ConfigError) {
  case
    server_token != ""
    && string.byte_size(server_token) <= 512
    && ascii_visible(server_token)
  {
    True ->
      Ok(Config(
        client,
        server_token,
        None,
        10_000,
        65_536,
        message.default_limits(),
      ))
    False -> Error(InvalidToken)
  }
}

/// Opt into a literal loopback endpoint. The caller's client must separately
/// admit loopback destinations. Its existing destination policy is not widened.
pub fn local_test(config: Config, port: Int) -> Result(Config, ConfigError) {
  case port > 0 && port <= 65_535 {
    True -> Ok(Config(..config, local_port: Some(port)))
    False -> Error(InvalidPort)
  }
}

pub fn deadline(
  config: Config,
  milliseconds: Int,
) -> Result(Config, ConfigError) {
  case milliseconds > 0 && milliseconds <= 120_000 {
    True -> Ok(Config(..config, timeout_ms: milliseconds))
    False -> Error(InvalidDeadline)
  }
}

pub fn response_limit(
  config: Config,
  bytes: Int,
) -> Result(Config, ConfigError) {
  case bytes > 0 && bytes <= 1_048_576 {
    True -> Ok(Config(..config, response_bytes: bytes))
    False -> Error(InvalidResponseLimit)
  }
}

/// Apply validated message admission limits. Postmark's separate recipient,
/// subject, sender and encoded JSON limits remain enforced.
pub fn limits(config: Config, limits: message.Limits) -> Config {
  Config(..config, message_limits: limits)
}

/// Add this policy before starting or recording a caller-owned client.
/// Request and response bodies require a separate application redactor if they
/// contain secrets. This function never modifies live wire content.
pub fn redact_token(
  redaction: http_redaction.Redaction,
) -> http_redaction.Redaction {
  http_redaction.with_headers(redaction, [server_token_header])
}

pub fn options() -> Options {
  Options(None, None, [], None, None)
}

/// Tag admission uses a conservative 1,000-byte bound.
pub fn tag(options: Options, value: String) -> Result(Options, ConfigError) {
  case safe_text(value) && string.byte_size(value) <= 1000 {
    True -> Ok(Options(..options, tag: Some(value)))
    False -> Error(InvalidTag)
  }
}

pub fn stream(options: Options, value: String) -> Result(Options, ConfigError) {
  case value != "" && string.byte_size(value) <= 30 && ascii_visible(value) {
    True -> Ok(Options(..options, stream: Some(value)))
    False -> Error(InvalidStream)
  }
}

/// Metadata is bounded to 20 pairs, 80-byte keys and 1,000-byte values.
/// Reusing a key replaces its value.
pub fn metadata(
  options: Options,
  key: String,
  value: String,
) -> Result(Options, ConfigError) {
  let entries =
    options.metadata
    |> list.filter(fn(pair) { pair.0 != key })
    |> list.append([#(key, value)])
  case
    key != ""
    && string.byte_size(key) <= 80
    && string.byte_size(value) <= 1000
    && safe_text(key)
    && safe_text(value)
    && list.length(entries) <= 20
  {
    True -> Ok(Options(..options, metadata: entries))
    False -> Error(InvalidMetadata)
  }
}

pub fn track_opens(options: Options, enabled: Bool) -> Options {
  Options(..options, track_opens: Some(enabled))
}

pub fn track_links(options: Options, tracking: LinkTracking) -> Options {
  Options(..options, track_links: Some(tracking))
}

pub fn sender(config: Config, options: Options) -> delivery.Sender {
  fn(message) { send(config, message, options) }
}

pub fn send(
  config: Config,
  message: message.Message,
  options: Options,
) -> delivery.Outcome {
  case prepare(message, options, config.message_limits) {
    Error(failure) -> delivery.NotSent(failure)
    Ok(payload) -> {
      let #(url, policy) = endpoint(config)
      case request.to(url) {
        Error(Nil) -> delivery.NotSent(delivery.AdapterFailure)
        Ok(req) -> {
          let req =
            req
            |> request.set_method(http.Post)
            |> request.set_header("content-type", "application/json")
            |> request.set_header("accept", "application/json")
            |> request.set_header(server_token_header, config.token)
            |> request.set_body(payload)
          let client =
            config.client
            |> http_gun.with_destination(policy)
            |> http_gun.with_timeout(
              http_config.After(duration.milliseconds(config.timeout_ms)),
            )
            |> http_gun.with_body_limit(config.response_bytes, http_gun.Fail)
          case http_gun.send(client, req) {
            Ok(reply) ->
              response(reply.response.status, reply.response.body, message)
            Error(failure) -> failed(failure)
          }
        }
      }
    }
  }
}

fn endpoint(config: Config) -> #(String, destination.Policy) {
  case config.local_port {
    None -> #(
      "https://api.postmarkapp.com/email",
      destination.default()
        |> destination.only_hosts(["api.postmarkapp.com:443"])
        |> destination.with_plaintext(destination.RequireTls),
    )
    Some(port) -> #(
      "http://127.0.0.1:" <> int.to_string(port) <> "/email",
      destination.loopback_only()
        |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)])
        |> destination.with_plaintext(destination.PlaintextToLoopbackOnly),
    )
  }
}

fn prepare(
  mail: message.Message,
  options: Options,
  limits: message.Limits,
) -> Result(BitArray, delivery.Failure) {
  use _ <- result.try(
    message.validate(mail, limits)
    |> result.map_error(delivery.InvalidMessage),
  )
  let v = message.view(mail)
  let count = list.length(v.to) + list.length(v.cc) + list.length(v.bcc)
  // Refuse oversized raw content before JSON/base64 allocation. The exact
  // encoded request limit is checked again below.
  let raw_bytes = raw_content_bytes(v)
  case address.email(v.envelope_sender) != address.email(v.from) {
    True ->
      Error(delivery.UnsupportedCapability(delivery.EnvelopeSenderOverride))
    False ->
      case
        count <= 50
        && string.byte_size(v.subject) <= 2000
        && string.byte_size(mailbox(v.from)) <= 255
        && raw_bytes <= 10_000_000
      {
        False -> Error(delivery.ProviderLimitExceeded)
        True -> {
          let body = case v.body {
            message.Text(text) -> [#("TextBody", json.string(text))]
            message.Html(html) -> [#("HtmlBody", json.string(html))]
            message.Alternative(text, html) -> [
              #("TextBody", json.string(text)),
              #("HtmlBody", json.string(html)),
            ]
          }
          let reply_to = case v.reply_to {
            None -> []
            Some(a) -> [#("ReplyTo", json.string(mailbox(a)))]
          }
          let fields = [
            #("From", json.string(mailbox(v.from))),
            #("To", json.string(mailboxes(v.to))),
            #("Cc", json.string(mailboxes(v.cc))),
            #("Bcc", json.string(mailboxes(v.bcc))),
            #("Subject", json.string(v.subject)),
            #(
              "Headers",
              json.array(v.headers, fn(h) {
                json.object([
                  #("Name", json.string(h.0)),
                  #("Value", json.string(h.1)),
                ])
              }),
            ),
            #("Attachments", json.array(v.attachments, attachment)),
          ]
          let raw =
            list.flatten([fields, body, reply_to, option_fields(options)])
            |> json.object
            |> json.to_string
            |> bit_array.from_string
          case bit_array.byte_size(raw) <= 10_000_000 {
            True -> Ok(raw)
            False -> Error(delivery.ProviderLimitExceeded)
          }
        }
      }
  }
}

fn raw_content_bytes(v: message.View) -> Int {
  let body = case v.body {
    message.Text(t) | message.Html(t) -> string.byte_size(t)
    message.Alternative(t, h) -> string.byte_size(t) + string.byte_size(h)
  }
  let files =
    list.fold(v.attachments, 0, fn(n, a) {
      let a = message.attachment_view(a)
      n
      + bit_array.byte_size(a.bytes)
      + string.byte_size(a.filename)
      + string.byte_size(a.content_type)
      + 100
    })
  let headers =
    list.fold(v.headers, 0, fn(n, h) {
      n + string.byte_size(h.0) + string.byte_size(h.1) + 10
    })
  let addresses =
    list.flatten([
      v.to,
      v.cc,
      v.bcc,
      [v.from],
      case v.reply_to {
        None -> []
        Some(a) -> [a]
      },
    ])
  let address_bytes =
    list.fold(addresses, 0, fn(n, a) { n + string.byte_size(mailbox(a)) + 10 })
  body + files + headers + address_bytes + string.byte_size(v.subject)
}

fn mailbox(a: address.Address) -> String {
  case address.name(a) {
    None | Some("") -> address.email(a)
    Some(name) ->
      "\""
      <> string.replace(string.replace(name, "\\", "\\\\"), "\"", "\\\"")
      <> "\" <"
      <> address.email(a)
      <> ">"
  }
}

fn mailboxes(addresses: List(address.Address)) -> String {
  list.map(addresses, mailbox) |> string.join(", ")
}

fn attachment(a: message.Attachment) -> json.Json {
  let a = message.attachment_view(a)
  let cid = case a.disposition {
    message.AttachmentFile -> []
    message.Inline(id) -> [#("ContentID", json.string("cid:" <> id))]
  }
  json.object(list.append(
    [
      #("Name", json.string(a.filename)),
      #("ContentType", json.string(a.content_type)),
      #("Content", json.string(bit_array.base64_encode(a.bytes, True))),
    ],
    cid,
  ))
}

fn option_fields(options: Options) -> List(#(String, json.Json)) {
  list.flatten([
    case options.tag {
      None -> []
      Some(t) -> [#("Tag", json.string(t))]
    },
    case options.stream {
      None -> []
      Some(s) -> [#("MessageStream", json.string(s))]
    },
    case options.track_opens {
      None -> []
      Some(b) -> [#("TrackOpens", json.bool(b))]
    },
    case options.track_links {
      None -> []
      Some(t) -> [
        #(
          "TrackLinks",
          json.string(case t {
            NoLinks -> "None"
            HtmlAndText -> "HtmlAndText"
            HtmlOnly -> "HtmlOnly"
            TextOnly -> "TextOnly"
          }),
        ),
      ]
    },
    [
      #(
        "Metadata",
        options.metadata
          |> list.map(fn(p) { #(p.0, json.string(p.1)) })
          |> json.object,
      ),
    ],
  ])
}

fn response(
  status: Int,
  body: BitArray,
  mail: message.Message,
) -> delivery.Outcome {
  case status {
    429 -> delivery.Rejected(delivery.Temporary)
    400 | 401 | 403 | 404 | 405 | 413 | 415 | 422 ->
      delivery.Rejected(delivery.Permanent)
    status if status >= 200 && status < 300 -> {
      let decoder = {
        use code <- decode.field("ErrorCode", decode.int)
        use id <- decode.optional_field("MessageID", "", decode.string)
        decode.success(#(code, id))
      }
      case json.parse_bits(body, decoder) {
        Ok(#(0, id)) ->
          case id != "" && string.byte_size(id) <= 256 && safe_text(id) {
            True ->
              delivery.Accepted(delivery.Receipt(
                Some(id),
                message.envelope(mail).1,
              ))
            False -> delivery.OutcomeUnknown
          }
        Ok(#(100, _)) -> delivery.Rejected(delivery.Temporary)
        Ok(#(101, _)) -> delivery.OutcomeUnknown
        Ok(#(code, _)) if code > 0 -> delivery.Rejected(delivery.Permanent)
        _ -> delivery.OutcomeUnknown
      }
    }
    _ -> delivery.OutcomeUnknown
  }
}

fn failed(failure: http_error.Failure) -> delivery.Outcome {
  case http_error.evidence(failure) {
    http_error.NotSent ->
      case http_error.kind(failure) {
        http_error.TimedOut -> delivery.NotSent(delivery.DeadlineExceeded)
        http_error.Refused -> delivery.NotSent(delivery.TransportSecurity)
        http_error.Network | http_error.Unavailable ->
          delivery.NotSent(delivery.ConnectionUnavailable)
        _ -> delivery.NotSent(delivery.AdapterFailure)
      }
    http_error.MaybeSent ->
      case http_error.status(failure) {
        Some(429) -> delivery.Rejected(delivery.Temporary)
        Some(400)
        | Some(401)
        | Some(403)
        | Some(404)
        | Some(405)
        | Some(413)
        | Some(415)
        | Some(422) -> delivery.Rejected(delivery.Permanent)
        _ -> delivery.OutcomeUnknown
      }
  }
}

fn ascii_visible(value: String) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.all(fn(c) {
    let n = string.utf_codepoint_to_int(c)
    n >= 33 && n <= 126
  })
}

fn safe_text(value: String) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.all(fn(c) {
    let n = string.utf_codepoint_to_int(c)
    n >= 32 && n != 127 && { n < 128 || n > 159 } && n != 8232 && n != 8233
  })
}
