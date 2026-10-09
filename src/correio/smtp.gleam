//// One bounded SMTP exchange per send. No connection pool or automatic retry.
//// SMTP aborts before DATA if any recipient is refused; it never partially
//// delivers a transaction. Accepted means every admitted envelope recipient.

import correio/address
import correio/delivery.{type Outcome}
import correio/message.{type Limits, type Message}
import correio/mime
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type ConfigError {
  InvalidHost
  InvalidPort
  InvalidDeadline
  InvalidCredentials
  InvalidTrustRoots
  PlaintextCredentialsForbidden
}

pub type Security {
  StartTlsRequired
  ImplicitTls
  LocalTestPlaintext
}

pub opaque type Config {
  Config(
    host: String,
    port: Int,
    security: Security,
    credentials: Option(#(String, String)),
    deadline_ms: Int,
    trust_roots: Option(BitArray),
    limits: Limits,
  )
}

pub fn starttls(host: String, port: Int) -> Result(Config, ConfigError) {
  configure(host, port, StartTlsRequired)
}

pub fn implicit_tls(host: String, port: Int) -> Result(Config, ConfigError) {
  configure(host, port, ImplicitTls)
}

/// Plaintext is restricted to the literal loopback addresses and localhost.
/// Credentials cannot be added to this configuration.
pub fn local_test(host: String, port: Int) -> Result(Config, ConfigError) {
  configure(host, port, LocalTestPlaintext)
}

fn configure(
  host: String,
  port: Int,
  security: Security,
) -> Result(Config, ConfigError) {
  case valid_host(host), port > 0 && port <= 65_535, security {
    False, _, _ -> Error(InvalidHost)
    _, False, _ -> Error(InvalidPort)
    True, True, LocalTestPlaintext ->
      case list.contains(["localhost", "127.0.0.1", "::1"], host) {
        True ->
          Ok(Config(
            host,
            port,
            security,
            None,
            10_000,
            None,
            message.default_limits(),
          ))
        False -> Error(InvalidHost)
      }
    True, True, _ ->
      Ok(Config(
        host,
        port,
        security,
        None,
        10_000,
        None,
        message.default_limits(),
      ))
  }
}

pub fn credentials(
  config: Config,
  username: String,
  password: String,
) -> Result(Config, ConfigError) {
  let valid =
    username != ""
    && password != ""
    && string.byte_size(username) <= 4096
    && string.byte_size(password) <= 4096
    && !string.contains(username, "\u{0000}")
    && !string.contains(password, "\u{0000}")
  case config.security, valid {
    LocalTestPlaintext, _ -> Error(PlaintextCredentialsForbidden)
    _, False -> Error(InvalidCredentials)
    _, True -> Ok(Config(..config, credentials: Some(#(username, password))))
  }
}

/// Deadline includes connection, TLS, authentication and message exchange.
/// Values range from 1 ms through 120 seconds.
pub fn deadline(
  config: Config,
  milliseconds: Int,
) -> Result(Config, ConfigError) {
  case milliseconds > 0 && milliseconds <= 120_000 {
    True -> Ok(Config(..config, deadline_ms: milliseconds))
    False -> Error(InvalidDeadline)
  }
}

/// Replace system roots with explicit PEM certificate authorities. Peer and
/// hostname verification remain mandatory. Certificates are parsed immediately.
pub fn trust_roots(
  config: Config,
  pem: BitArray,
) -> Result(Config, ConfigError) {
  case valid_roots(pem) {
    True -> Ok(Config(..config, trust_roots: Some(pem)))
    False -> Error(InvalidTrustRoots)
  }
}

pub fn limits(config: Config, limits: Limits) -> Config {
  Config(..config, limits: limits)
}

pub fn send(config: Config, message: Message) -> Outcome {
  case mime.render_with_limits(message, config.limits) {
    Error(error) -> delivery.NotSent(delivery.InvalidMessage(error))
    Ok(raw) -> {
      let #(sender, recipients) = message.envelope(message)
      case
        submit(
          config.host,
          config.port,
          config.security,
          config.credentials,
          config.deadline_ms,
          config.trust_roots,
          address.email(sender),
          list.map(recipients, address.email),
          raw,
        )
      {
        Accepted -> delivery.Accepted(delivery.Receipt(None, recipients))
        BeforeSend(error) -> delivery.NotSent(error)
        Refused(rejection) -> delivery.Rejected(rejection)
        Uncertain -> delivery.OutcomeUnknown
      }
    }
  }
}

pub fn sender(config: Config) -> delivery.Sender {
  fn(message) { send(config, message) }
}

type Submission {
  Accepted
  BeforeSend(delivery.Failure)
  Refused(delivery.Rejection)
  Uncertain
}

@external(erlang, "correio_smtp_ffi", "submit")
fn submit(
  host: String,
  port: Int,
  security: Security,
  credentials: Option(#(String, String)),
  deadline_ms: Int,
  roots: Option(BitArray),
  from: String,
  to: List(String),
  raw: BitArray,
) -> Submission

@external(erlang, "correio_smtp_ffi", "valid_host")
fn valid_host(value: String) -> Bool

@external(erlang, "correio_smtp_ffi", "valid_roots")
fn valid_roots(value: BitArray) -> Bool
