//// Trusted adapter protocol. Applications normally use passwordless.Service.
//// Implementations must serialize each command, sample milliseconds since Unix
//// epoch after acquiring serialization, and return Unknown for ambiguous writes.

import gleam/list

pub type Fault {
  Unavailable
  Unknown
  Capacity
  IncompatibleData
  IssueExpired
  IdentityCollision
}

pub type Refusal {
  Missing
  Expired
  Revoked
  Exhausted
  Consumed
  WrongAnswer
  BindingMismatch
  Malformed
}

pub type Status {
  Active
  Spent(command: String, authenticated_at: Int)
  Withdrawn
  TimedOut
}

pub type Row(a) {
  Row(
    id: String,
    subject: a,
    scope: String,
    purpose: String,
    destination: String,
    verifier: String,
    expires_at: Int,
    retain_until: Int,
    attempts: Int,
    status: Status,
    failed_commands: List(String),
  )
}

pub type Issue(a) {
  Issue(
    id: String,
    subject: a,
    scope: String,
    purpose: String,
    destination: String,
    verifier: String,
    expires_at: Int,
    retain_until: Int,
    attempts: Int,
  )
}

pub type Verify {
  Verify(
    id: String,
    command: String,
    scope: String,
    purpose: String,
    destination: String,
    verifier: String,
  )
}

pub type Revoke {
  Revoke(id: String, scope: String, purpose: String)
}

pub type Receipt(a) {
  Receipt(row: Row(a), authenticated_at: Int)
}

pub type Store(a) {
  Store(
    now: fn() -> Result(Int, Fault),
    issue: fn(Issue(a)) -> Result(Row(a), Fault),
    verify: fn(Verify) -> Result(Result(Receipt(a), Refusal), Fault),
    revoke: fn(Revoke) -> Result(Result(Nil, Refusal), Fault),
    cleanup: fn(Int) -> Result(Int, Fault),
  )
}

pub fn issued(command: Issue(a)) -> Row(a) {
  Row(
    command.id,
    command.subject,
    command.scope,
    command.purpose,
    command.destination,
    command.verifier,
    command.expires_at,
    command.retain_until,
    command.attempts,
    Active,
    [],
  )
}

/// Apply only while holding row authority. Time must be read after the lock.
pub fn verify_row(
  row: Row(a),
  command: Verify,
  now: Int,
) -> #(Row(a), Result(Receipt(a), Refusal)) {
  case
    row.scope == command.scope
    && row.purpose == command.purpose
    && row.destination == command.destination
  {
    False -> #(row, Error(BindingMismatch))
    True ->
      case now >= row.retain_until {
        True -> #(Row(..row, status: TimedOut), Error(Expired))
        False ->
          case list.contains(row.failed_commands, command.command) {
            True -> #(row, Error(WrongAnswer))
            False ->
              case row.status {
                Spent(id, at) if id == command.command ->
                  case constant_equal(row.verifier, command.verifier) {
                    True -> #(row, Ok(Receipt(row, at)))
                    False -> #(row, Error(BindingMismatch))
                  }
                Spent(_, _) -> #(row, Error(Consumed))
                TimedOut -> #(row, Error(Expired))
                Withdrawn -> #(row, Error(Revoked))
                Active -> verify_active(row, command, now)
              }
          }
      }
  }
}

fn verify_active(
  row: Row(a),
  command: Verify,
  now: Int,
) -> #(Row(a), Result(Receipt(a), Refusal)) {
  case list.contains(row.failed_commands, command.command) {
    True -> #(row, Error(WrongAnswer))
    False ->
      case now >= row.expires_at, row.attempts <= 0 {
        True, _ -> #(Row(..row, status: TimedOut), Error(Expired))
        _, True -> #(row, Error(Exhausted))
        False, False ->
          case constant_equal(row.verifier, command.verifier) {
            True -> {
              let next = Row(..row, status: Spent(command.command, now))
              #(next, Ok(Receipt(next, now)))
            }
            False -> #(
              Row(..row, attempts: row.attempts - 1, failed_commands: [
                command.command,
                ..row.failed_commands
              ]),
              Error(WrongAnswer),
            )
          }
      }
  }
}

pub fn revoke_row(
  row: Row(a),
  command: Revoke,
  now: Int,
) -> #(Row(a), Result(Nil, Refusal)) {
  case row.scope == command.scope && row.purpose == command.purpose {
    False -> #(row, Error(BindingMismatch))
    True ->
      case row.status {
        Spent(_, _) -> #(row, Error(Consumed))
        TimedOut -> #(row, Error(Expired))
        Withdrawn ->
          case now >= row.retain_until {
            True -> #(Row(..row, status: TimedOut), Error(Expired))
            False -> #(row, Ok(Nil))
          }
        Active ->
          case now >= row.expires_at {
            True -> #(Row(..row, status: TimedOut), Error(Expired))
            False -> #(Row(..row, status: Withdrawn), Ok(Nil))
          }
      }
  }
}

@external(erlang, "correio_auth_ffi", "constant_equal")
fn constant_equal(a: String, b: String) -> Bool

/// Issue replay must match its immutable command, including native subject.
pub fn same_issue(row: Row(a), command: Issue(a)) -> Bool {
  row.id == command.id
  && row.subject == command.subject
  && row.scope == command.scope
  && row.purpose == command.purpose
  && row.destination == command.destination
  && row.verifier == command.verifier
  && row.expires_at == command.expires_at
  && row.retain_until == command.retain_until
  && row.attempts + list.length(row.failed_commands) == command.attempts
}
