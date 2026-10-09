//// Immutable message construction. Delivery admission applies resource limits.

import correio/address.{type Address}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string

pub type Body {
  Text(String)
  Html(String)
  Alternative(text: String, html: String)
}

pub type Disposition {
  AttachmentFile
  Inline(content_id: String)
}

pub opaque type Attachment {
  Attachment(
    filename: String,
    content_type: String,
    bytes: BitArray,
    disposition: Disposition,
  )
}

pub type AttachmentView {
  AttachmentView(
    filename: String,
    content_type: String,
    bytes: BitArray,
    disposition: Disposition,
  )
}

pub opaque type Message {
  Message(View)
}

/// A read-only projection. Constructing a View cannot construct a Message.
pub type View {
  View(
    from: Address,
    to: List(Address),
    cc: List(Address),
    bcc: List(Address),
    subject: String,
    body: Body,
    reply_to: Option(Address),
    envelope_sender: Address,
    headers: List(#(String, String)),
    attachments: List(Attachment),
  )
}

pub type MessageError {
  InvalidSubject
  EmptyBody
  InvalidHeader
  ReservedHeader
  InvalidAttachment
  InvalidLimits
  TooManyRecipients
  TooManyHeaders
  HeaderTooLarge
  BodyTooLarge
  AttachmentTooLarge
  SubmissionTooLarge
  EncodingFailed
}

pub opaque type Limits {
  Limits(
    recipients: Int,
    headers: Int,
    header_bytes: Int,
    body_bytes: Int,
    attachment_bytes: Int,
    submission_bytes: Int,
  )
}

/// Defaults: 100 recipients, 50 custom headers, 8 KiB header values,
/// 1 MiB body content, 10 MiB per attachment and 25 MiB encoded submission.
pub fn default_limits() -> Limits {
  Limits(100, 50, 8192, 1_048_576, 10_485_760, 26_214_400)
}

pub fn limits(
  recipients: Int,
  headers: Int,
  header_bytes: Int,
  body_bytes: Int,
  attachment_bytes: Int,
  submission_bytes: Int,
) -> Result(Limits, MessageError) {
  case
    list.all(
      [
        recipients,
        headers,
        header_bytes,
        body_bytes,
        attachment_bytes,
        submission_bytes,
      ],
      fn(n) { n > 0 && n <= 1_073_741_824 },
    )
  {
    True ->
      Ok(Limits(
        recipients,
        headers,
        header_bytes,
        body_bytes,
        attachment_bytes,
        submission_bytes,
      ))
    False -> Error(InvalidLimits)
  }
}

pub fn new(
  from from: Address,
  to to: Address,
  subject subject: String,
  body body: Body,
) -> Result(Message, MessageError) {
  case safe_header(subject), body_valid(body) {
    False, _ -> Error(InvalidSubject)
    _, False -> Error(EmptyBody)
    True, True ->
      Ok(Message(View(from, [to], [], [], subject, body, None, from, [], [])))
  }
}

fn body_valid(body: Body) -> Bool {
  case body {
    Text(value) | Html(value) -> value != ""
    Alternative(text, html) -> text != "" && html != ""
  }
}

pub fn view(message: Message) -> View {
  let Message(view) = message
  view
}

pub fn add_to(message: Message, address: Address) -> Message {
  let v = view(message)
  Message(View(..v, to: list.append(v.to, [address])))
}

pub fn add_cc(message: Message, address: Address) -> Message {
  let v = view(message)
  Message(View(..v, cc: list.append(v.cc, [address])))
}

pub fn add_bcc(message: Message, address: Address) -> Message {
  let v = view(message)
  Message(View(..v, bcc: list.append(v.bcc, [address])))
}

pub fn set_reply_to(message: Message, address: Address) -> Message {
  let v = view(message)
  Message(View(..v, reply_to: Some(address)))
}

pub fn set_envelope_sender(message: Message, address: Address) -> Message {
  let v = view(message)
  Message(View(..v, envelope_sender: address))
}

pub fn envelope(message: Message) -> #(Address, List(Address)) {
  let v = view(message)
  let #(recipients, _) =
    list.fold(list.flatten([v.to, v.cc, v.bcc]), #([], set.new()), fn(acc, a) {
      let #(recipients, seen) = acc
      let email = address.email(a)
      case set.contains(seen, email) {
        True -> acc
        False -> #([a, ..recipients], set.insert(seen, email))
      }
    })
  #(v.envelope_sender, list.reverse(recipients))
}

/// Custom field bodies preserve structured ASCII syntax. Unicode custom field
/// bodies and physical lines longer than 998 bytes are refused. Unicode subject
/// and display-name encoding remains available through their dedicated APIs.
pub fn header(
  message: Message,
  name: String,
  value: String,
) -> Result(Message, MessageError) {
  let reserved = [
    "from",
    "to",
    "cc",
    "bcc",
    "sender",
    "reply-to",
    "subject",
    "date",
    "message-id",
    "mime-version",
    "return-path",
    "received",
    "dkim-signature",
    "authentication-results",
  ]
  case
    list.contains(reserved, string.lowercase(name))
    || string.starts_with(string.lowercase(name), "content-")
    || string.starts_with(string.lowercase(name), "resent-")
  {
    True -> Error(ReservedHeader)
    False ->
      case valid_header_name(name) && valid_custom_header(name, value) {
        False -> Error(InvalidHeader)
        True -> {
          let v = view(message)
          Ok(Message(
            View(..v, headers: list.append(v.headers, [#(name, value)])),
          ))
        }
      }
  }
}

pub fn attachment(
  filename: String,
  content_type: String,
  bytes: BitArray,
  disposition: Disposition,
) -> Result(Attachment, MessageError) {
  let valid_disposition = case disposition {
    AttachmentFile -> True
    Inline(cid) -> valid_content_id(cid)
  }
  case
    filename != ""
    && safe_header(filename)
    && valid_content_type(content_type)
    && valid_disposition
    && bit_array.bit_size(bytes) % 8 == 0
  {
    True ->
      Ok(Attachment(
        filename,
        string.lowercase(content_type),
        bytes,
        disposition,
      ))
    False -> Error(InvalidAttachment)
  }
}

pub fn attachment_view(attachment: Attachment) -> AttachmentView {
  AttachmentView(
    attachment.filename,
    attachment.content_type,
    attachment.bytes,
    attachment.disposition,
  )
}

pub fn attach(message: Message, attachment: Attachment) -> Message {
  let v = view(message)
  Message(View(..v, attachments: list.append(v.attachments, [attachment])))
}

pub fn validate(message: Message, limits: Limits) -> Result(Nil, MessageError) {
  let v = view(message)
  let addresses =
    list.flatten([
      v.to,
      v.cc,
      v.bcc,
      [v.from, v.envelope_sender],
      option_to_list(v.reply_to),
    ])
  let names =
    list.map(addresses, fn(a) {
      case address.name(a) {
        None -> ""
        Some(n) -> n
      }
    })
  let header_values =
    list.flatten([
      [v.subject],
      names,
      list.flat_map(v.headers, fn(h) { [h.0, h.1] }),
      list.map(v.attachments, fn(a) { a.filename }),
    ])
  let body_bytes = case v.body {
    Text(t) | Html(t) -> string.byte_size(t)
    Alternative(t, h) -> string.byte_size(t) + string.byte_size(h)
  }
  let attachment_bytes =
    list.fold(v.attachments, 0, fn(total, a) {
      total + bit_array.byte_size(a.bytes)
    })
  let recipient_count =
    list.length(v.to) + list.length(v.cc) + list.length(v.bcc)
  let header_count = list.length(v.headers)
  // Reserve an upper bound for base64, encoded words, parameter escaping,
  // boundaries and fixed MIME headers before allocating the serialized body.
  let metadata_bytes =
    list.fold(header_values, 0, fn(n, v) { n + string.byte_size(v) })
  let encoded_bound =
    2000
    + 2
    * { attachment_bytes + body_bytes }
    + 8
    * metadata_bytes
    + 1000
    * list.length(v.attachments)
    + 400
    * list.length(addresses)
    + 100
    * header_count
  case True {
    _ if recipient_count > limits.recipients -> Error(TooManyRecipients)
    _ if header_count > limits.headers -> Error(TooManyHeaders)
    _ if body_bytes > limits.body_bytes -> Error(BodyTooLarge)
    _ if encoded_bound > limits.submission_bytes -> Error(SubmissionTooLarge)
    _ ->
      case
        list.any(header_values, fn(h) {
          string.byte_size(h) > limits.header_bytes
        }),
        list.any(v.attachments, fn(a) {
          bit_array.byte_size(a.bytes) > limits.attachment_bytes
        })
      {
        True, _ -> Error(HeaderTooLarge)
        _, True -> Error(AttachmentTooLarge)
        False, False -> Ok(Nil)
      }
  }
}

fn option_to_list(value: Option(a)) -> List(a) {
  case value {
    Some(v) -> [v]
    None -> []
  }
}

pub fn maximum_submission_bytes(limits: Limits) -> Int {
  limits.submission_bytes
}

@external(erlang, "correio_mail_ffi", "safe_header")
fn safe_header(value: String) -> Bool

@external(erlang, "correio_mail_ffi", "valid_header_name")
fn valid_header_name(value: String) -> Bool

@external(erlang, "correio_mail_ffi", "valid_custom_header")
fn valid_custom_header(name: String, value: String) -> Bool

@external(erlang, "correio_mail_ffi", "valid_content_type")
fn valid_content_type(value: String) -> Bool

@external(erlang, "correio_mail_ffi", "valid_content_id")
fn valid_content_id(value: String) -> Bool
