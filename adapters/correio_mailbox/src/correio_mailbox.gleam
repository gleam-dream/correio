//// Read-only development mailbox. The caller owns capture, HTTP server, and
//// access control. Mount only in an explicitly enabled development environment.

import correio/address
import correio/capture
import correio/message
import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

pub opaque type Mailbox {
  Mailbox(capture: capture.Capture, path: String)
}

pub type ConfigurationError {
  InvalidMountPath
}

/// Mount paths contain slash-separated ASCII letters, digits, hyphens, or
/// underscores. Root, empty segments, and trailing slashes are refused.
pub fn new(
  capture: capture.Capture,
  at path: String,
) -> Result(Mailbox, ConfigurationError) {
  case string.split(path, "/") {
    ["", first, ..rest] -> {
      case list.all([first, ..rest], valid_segment) {
        True -> Ok(Mailbox(capture, path))
        False -> Error(InvalidMountPath)
      }
    }
    _ -> Error(InvalidMountPath)
  }
}

fn valid_segment(segment: String) -> Bool {
  segment != ""
  && string.byte_size(segment) <= 64
  && list.all(string.to_graphemes(segment), fn(char) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      char,
    )
  })
}

/// Pass the original request path, including the configured mount prefix.
/// Bodies and query parameters are ignored. Only GET can inspect the capture.
pub fn handle(mailbox: Mailbox, request: Request(body)) -> Response(String) {
  let path = request.path
  case path == mailbox.path || string.starts_with(path, mailbox.path <> "/") {
    False -> page(404, "Not found")
    True ->
      case request.method {
        http.Get ->
          case capture.entries(mailbox.capture) {
            Error(_) -> page(503, "Capture unavailable")
            Ok(entries) ->
              case path == mailbox.path || path == mailbox.path <> "/" {
                True -> page(200, inbox(mailbox.path, entries))
                False -> {
                  let id =
                    string.drop_start(path, string.length(mailbox.path) + 1)
                  case int.parse(id) {
                    Ok(id) ->
                      case list.find(entries, fn(entry) { entry.id == id }) {
                        Ok(entry) -> page(200, detail(mailbox.path, entry))
                        Error(_) -> page(404, "Message not found")
                      }
                    Error(_) -> page(404, "Message not found")
                  }
                }
              }
          }
        _ ->
          page(405, "Read-only mailbox") |> response.set_header("allow", "GET")
      }
  }
}

fn page(status: Int, body: String) -> Response(String) {
  response.new(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("x-frame-options", "DENY")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; style-src 'unsafe-inline'; frame-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  )
  |> response.set_body(
    "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Correio development mailbox</title><style>body{font:16px system-ui;max-width:1050px;margin:40px auto;padding:0 24px;color:#172235;background:#f8fafc}a{color:#2348a0}li{margin:14px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:white;padding:18px;border:1px solid #ccd5e0}dt{font-weight:bold;margin-top:12px}dd{margin:4px 0;overflow-wrap:anywhere}iframe{width:100%;height:340px;background:white;border:1px solid #ccd5e0}.notice{color:#53627a}</style></head><body><h1>Correio development mailbox</h1><p class=notice>Local captured mail contains development secrets.</p>"
    <> body
    <> "</body></html>",
  )
}

fn inbox(path: String, entries: List(capture.Entry)) -> String {
  let recent = entries |> list.reverse |> list.take(50)
  "<a href=\""
  <> path
  <> "\">Refresh</a><p>Showing "
  <> int.to_string(list.length(recent))
  <> " of "
  <> int.to_string(list.length(entries))
  <> " retained messages.</p><ol>"
  <> {
    recent
    |> list.map(fn(entry) {
      let mail = message.view(entry.message)
      "<li data-message-id=\""
      <> int.to_string(entry.id)
      <> "\"><a href=\""
      <> path
      <> "/"
      <> int.to_string(entry.id)
      <> "\">"
      <> escape(mail.subject)
      <> "</a><br>To: "
      <> addresses(mail.to)
      <> "</li>"
    })
    |> string.join("")
  }
  <> "</ol>"
}

fn detail(path: String, entry: capture.Entry) -> String {
  let mail = message.view(entry.message)
  let #(sender, recipients) = message.envelope(entry.message)
  "<a href=\""
  <> path
  <> "\">Inbox</a><h2>"
  <> escape(mail.subject)
  <> "</h2><dl>"
  <> field("From", addresses([mail.from]))
  <> field("To", addresses(mail.to))
  <> field("Cc", addresses(mail.cc))
  <> field("Bcc", addresses(mail.bcc))
  <> field("Reply-to", case mail.reply_to {
    None -> "—"
    Some(value) -> addresses([value])
  })
  <> field("Envelope sender", addresses([sender]))
  <> field("Envelope recipients", addresses(recipients))
  <> {
    mail.headers
    |> list.map(fn(header) { field(escape(header.0), escape(header.1)) })
    |> string.join("")
  }
  <> "</dl>"
  <> body(mail.body)
  <> "<h3>Attachments</h3><ul>"
  <> {
    mail.attachments
    |> list.map(fn(attachment) {
      let item = message.attachment_view(attachment)
      "<li>"
      <> escape(item.filename)
      <> " · "
      <> escape(item.content_type)
      <> " · "
      <> int.to_string(bit_array.byte_size(item.bytes))
      <> " bytes · "
      <> case item.disposition {
        message.AttachmentFile -> "attachment"
        message.Inline(id) -> "inline: " <> escape(id)
      }
      <> "</li>"
    })
    |> string.join("")
  }
  <> "</ul>"
}

fn field(label: String, value: String) -> String {
  "<dt>" <> label <> "</dt><dd>" <> value <> "</dd>"
}

fn addresses(values: List(address.Address)) -> String {
  values
  |> list.map(fn(value) {
    escape(case address.name(value) {
      None -> address.email(value)
      Some(name) -> name <> " <" <> address.email(value) <> ">"
    })
  })
  |> string.join(", ")
}

fn body(body: message.Body) -> String {
  case body {
    message.Text(text) -> text_body(text)
    message.Html(html) -> html_body(html)
    message.Alternative(text, html) -> text_body(text) <> html_body(html)
  }
}

fn text_body(text: String) -> String {
  "<h3>Plain text</h3><pre id=plain-text>" <> escape(text) <> "</pre>"
}

fn html_body(html: String) -> String {
  let preview =
    "<!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; base-uri 'none'; form-action 'none'\">"
    <> formatting_preview(html)
  "<h3>Formatting preview</h3><p>Formatting only. Links, images, styles, and active content are omitted. Copy URLs from the source to open them intentionally.</p><iframe title=\"Email formatting preview\" sandbox=\"\" referrerpolicy=\"no-referrer\" srcdoc=\""
  <> escape(preview)
  <> "\"></iframe><h3>Original HTML source</h3><pre id=html-source>"
  <> escape(html)
  <> "</pre>"
}

// This is a small formatting projection, not an HTML parser or sanitizer.
// Only exact attribute-free tag names below become markup. Every other byte
// is escaped text or discarded tag text, so browser parser repairs cannot
// manufacture attributes, scripts, URLs, or refresh navigation.
fn formatting_preview(html: String) -> String {
  case string.split(html, "<") {
    [] -> ""
    [first, ..parts] ->
      escape(first)
      <> {
        parts
        |> list.map(fn(part) {
          case string.split_once(part, ">") {
            Error(_) -> escape("<" <> part)
            Ok(#(tag, text)) -> {
              let tag = string.lowercase(string.trim(tag))
              let name = case string.starts_with(tag, "/") {
                True -> string.drop_start(tag, 1)
                False -> tag
              }
              let safe =
                list.contains(
                  [
                    "p",
                    "br",
                    "strong",
                    "b",
                    "em",
                    "i",
                    "u",
                    "s",
                    "h1",
                    "h2",
                    "h3",
                    "h4",
                    "ul",
                    "ol",
                    "li",
                    "blockquote",
                    "pre",
                    "code",
                    "hr",
                    "table",
                    "thead",
                    "tbody",
                    "tr",
                    "th",
                    "td",
                  ],
                  name,
                )
              {
                case safe {
                  True -> "<" <> tag <> ">"
                  False -> ""
                }
              }
              <> escape(text)
            }
          }
        })
        |> string.join("")
      }
  }
}

fn escape(value: String) -> String {
  value
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}
