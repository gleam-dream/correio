//// Independent passwordless evidence. Applications own delivery and sessions.

import correio/passwordless/store
import gleam/result
import gleam/string

pub opaque type Service(a) {
  Service(
    store: store.Store(a),
    scope: String,
    purpose: String,
    key: BitArray,
    ttl_ms: Int,
    attempts: Int,
    retention_ms: Int,
  )
}

pub type ConfigError {
  InvalidBinding
  WeakKey
  InvalidPolicy
  InvalidCodeLength
}

pub type Method {
  MagicLink
  EmailCode(digits: Int)
}

pub opaque type Challenge(a) {
  Challenge(row: store.Row(a), answer: String)
}

pub opaque type Verified(a) {
  Verified(receipt: store.Receipt(a))
}

pub opaque type IssueRecovery(a) {
  IssueRecovery(service: Service(a), command: store.Issue(a), answer: String)
}

pub opaque type VerifyRecovery(a) {
  VerifyRecovery(service: Service(a), command: store.Verify)
}

pub opaque type RevokeRecovery(a) {
  RevokeRecovery(service: Service(a), command: store.Revoke)
}

pub type IssueError(a) {
  InvalidIssue(ConfigError)
  IssueFailed(store.Fault)
  IssueUnknown(IssueRecovery(a))
}

pub type VerifyError(a) {
  Refused(store.Refusal)
  VerifyFailed(store.Fault)
  VerifyUnknown(VerifyRecovery(a))
}

pub type RevokeError(a) {
  RevokeRefused(store.Refusal)
  RevokeFailed(store.Fault)
  RevokeUnknown(RevokeRecovery(a))
}

/// The key must contain at least 32 cryptographically random bytes. Keep it
/// stable across service instances that share a store and its retained rows.
pub fn new(
  store: store.Store(a),
  scope: String,
  purpose: String,
  key: BitArray,
) -> Result(Service(a), ConfigError) {
  case
    valid_binding(scope) && valid_binding(purpose),
    bit_size(key) >= 256 && bit_size(key) <= 32_768 && bit_size(key) % 8 == 0
  {
    False, _ -> Error(InvalidBinding)
    _, False -> Error(WeakKey)
    True, True ->
      Ok(Service(store, scope, purpose, key, 600_000, 5, 86_400_000))
  }
}

/// Milliseconds. TTL is bounded at 24h, attempts at 100, retention at 30 days.
pub fn with_policy(
  service: Service(a),
  ttl_ms: Int,
  max_attempts: Int,
  retention_ms: Int,
) -> Result(Service(a), ConfigError) {
  case
    ttl_ms > 0
    && ttl_ms <= 86_400_000
    && max_attempts > 0
    && max_attempts <= 100
    && retention_ms > 0
    && retention_ms <= 2_592_000_000
  {
    True ->
      Ok(Service(..service, ttl_ms:, attempts: max_attempts, retention_ms:))
    False -> Error(InvalidPolicy)
  }
}

pub fn issue(
  service: Service(a),
  subject: a,
  destination: String,
  method: Method,
) -> Result(Challenge(a), IssueError(a)) {
  use _ <- result.try(case valid_binding(destination) {
    True -> Ok(Nil)
    False -> Error(InvalidIssue(InvalidBinding))
  })
  use answer <- result.try(case method {
    MagicLink -> Ok(random_token())
    EmailCode(digits) if digits >= 6 && digits <= 10 -> Ok(random_code(digits))
    EmailCode(_) -> Error(InvalidIssue(InvalidCodeLength))
  })
  use now <- result.try(service.store.now() |> result.map_error(IssueFailed))
  let id = random_token()
  let command =
    store.Issue(
      id,
      subject,
      service.scope,
      service.purpose,
      destination,
      verifier(service, id, destination, answer),
      now + service.ttl_ms,
      now + service.ttl_ms + service.retention_ms,
      service.attempts,
    )
  recover_issue(IssueRecovery(service, command, answer))
}

pub fn recover_issue(
  recovery: IssueRecovery(a),
) -> Result(Challenge(a), IssueError(a)) {
  case recovery.service.store.issue(recovery.command) {
    Ok(row) -> Ok(Challenge(row, recovery.answer))
    Error(store.Unknown) -> Error(IssueUnknown(recovery))
    Error(error) -> Error(IssueFailed(error))
  }
}

/// Destination must be the current trusted application-selected value. Exact
/// comparison is intentional; this module does not normalize email addresses.
pub fn verify(
  service: Service(a),
  id: String,
  destination: String,
  answer: String,
) -> Result(Verified(a), VerifyError(a)) {
  case
    valid_id(id)
    && valid_binding(destination)
    && string.byte_size(answer) <= 128
  {
    False -> Error(Refused(store.Malformed))
    True ->
      recover_verify(VerifyRecovery(
        service,
        store.Verify(
          id,
          random_token(),
          service.scope,
          service.purpose,
          destination,
          verifier(service, id, destination, answer),
        ),
      ))
  }
}

pub fn recover_verify(
  recovery: VerifyRecovery(a),
) -> Result(Verified(a), VerifyError(a)) {
  case recovery.service.store.verify(recovery.command) {
    Ok(Ok(receipt)) -> Ok(Verified(receipt))
    Ok(Error(reason)) -> Error(Refused(reason))
    Error(store.Unknown) -> Error(VerifyUnknown(recovery))
    Error(error) -> Error(VerifyFailed(error))
  }
}

pub fn revoke(service: Service(a), id: String) -> Result(Nil, RevokeError(a)) {
  case valid_id(id) {
    False -> Error(RevokeRefused(store.Malformed))
    True ->
      recover_revoke(RevokeRecovery(
        service,
        store.Revoke(id, service.scope, service.purpose),
      ))
  }
}

pub fn recover_revoke(
  recovery: RevokeRecovery(a),
) -> Result(Nil, RevokeError(a)) {
  case recovery.service.store.revoke(recovery.command) {
    Ok(result) -> result |> result.map_error(RevokeRefused)
    Error(store.Unknown) -> Error(RevokeUnknown(recovery))
    Error(error) -> Error(RevokeFailed(error))
  }
}

pub fn challenge_id(challenge: Challenge(a)) -> String {
  challenge.row.id
}

/// Secret projection for explicit delivery only. Do not log this value.
pub fn challenge_answer(challenge: Challenge(a)) -> String {
  challenge.answer
}

pub fn challenge_expires_at(challenge: Challenge(a)) -> Int {
  challenge.row.expires_at
}

pub fn subject(evidence: Verified(a)) -> a {
  evidence.receipt.row.subject
}

pub fn destination(evidence: Verified(a)) -> String {
  evidence.receipt.row.destination
}

pub fn scope(evidence: Verified(a)) -> String {
  evidence.receipt.row.scope
}

pub fn purpose(evidence: Verified(a)) -> String {
  evidence.receipt.row.purpose
}

pub fn authenticated_at(evidence: Verified(a)) -> Int {
  evidence.receipt.authenticated_at
}

pub fn verification_id(evidence: Verified(a)) -> String {
  evidence.receipt.row.id
}

fn valid_binding(value: String) -> Bool {
  string.byte_size(value) > 0
  && string.byte_size(value) <= 320
  && !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

@external(erlang, "correio_auth_ffi", "valid_id")
fn valid_id(value: String) -> Bool

fn verifier(
  service: Service(a),
  id: String,
  destination: String,
  answer: String,
) -> String {
  // Stable verifier domain: package renaming must preserve outstanding answers.
  keyed_verifier(service.key, [
    "ecarta-passwordless-v1",
    service.scope,
    service.purpose,
    id,
    destination,
    answer,
  ])
}

@external(erlang, "correio_auth_ffi", "random_token")
fn random_token() -> String

@external(erlang, "correio_auth_ffi", "random_code")
fn random_code(digits: Int) -> String

@external(erlang, "correio_auth_ffi", "keyed_verifier")
fn keyed_verifier(key: BitArray, fields: List(String)) -> String

@external(erlang, "erlang", "bit_size")
fn bit_size(value: BitArray) -> Int

/// Use these descriptions for ordinary logs. Runtime inspection of opaque values
/// can reveal keys, answers, subjects, and recovery commands.
pub fn describe_issue_error(error: IssueError(a)) -> String {
  case error {
    InvalidIssue(_) -> "invalid challenge configuration"
    IssueFailed(reason) -> describe_fault(reason)
    IssueUnknown(_) ->
      "challenge issuance outcome unknown; retain recovery handle"
  }
}

pub fn describe_verify_error(error: VerifyError(a)) -> String {
  case error {
    Refused(reason) -> describe_refusal(reason)
    VerifyFailed(reason) -> describe_fault(reason)
    VerifyUnknown(_) -> "verification outcome unknown; retain recovery handle"
  }
}

pub fn describe_revoke_error(error: RevokeError(a)) -> String {
  case error {
    RevokeRefused(reason) -> describe_refusal(reason)
    RevokeFailed(reason) -> describe_fault(reason)
    RevokeUnknown(_) -> "revocation outcome unknown; retain recovery handle"
  }
}

fn describe_fault(fault: store.Fault) -> String {
  case fault {
    store.Unavailable -> "challenge storage unavailable"
    store.Unknown -> "challenge storage outcome unknown"
    store.Capacity -> "challenge storage capacity reached"
    store.IncompatibleData -> "incompatible challenge storage data"
    store.IssueExpired -> "challenge issuance expired"
    store.IdentityCollision -> "challenge identity collision"
  }
}

fn describe_refusal(refusal: store.Refusal) -> String {
  case refusal {
    store.Missing -> "challenge missing"
    store.Expired -> "challenge expired"
    store.Revoked -> "challenge revoked"
    store.Exhausted -> "challenge attempts exhausted"
    store.Consumed -> "challenge already consumed"
    store.WrongAnswer -> "challenge answer incorrect"
    store.BindingMismatch -> "challenge binding mismatch"
    store.Malformed -> "challenge input malformed"
  }
}
