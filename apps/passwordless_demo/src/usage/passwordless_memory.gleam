//// Verify an application-native subject with the in-memory store: issue,
//// verify, refusals, revocation and recovery of an unknown outcome.

import correio/passwordless
import correio/passwordless/memory
import correio/passwordless/store
import gleam/erlang/process

/// Correio is generic over the application's subject type.
pub type AccountId {
  AccountId(Int)
}

/// Demonstration only. A deployed application supplies 32 to 4096 random bytes
/// from its own secret store and keeps them stable across restarts.
const demo_key = <<"0123456789abcdef0123456789abcdef":utf8>>

/// Model a lost acknowledgement: the transition commits, but the first
/// verification reports `Unknown` to the caller.
fn losing_first_acknowledgement(
  inner: store.Store(a),
  lost: process.Subject(Nil),
) -> store.Store(a) {
  store.Store(..inner, verify: fn(command) {
    let committed = inner.verify(command)
    case process.receive(lost, 0) {
      Ok(Nil) -> Error(store.Unknown)
      Error(Nil) -> committed
    }
  })
}

pub fn run() -> Nil {
  let assert Ok(runtime) = memory.start(1000)
  let assert Ok(auth) =
    passwordless.new(memory.store(runtime), "example-app", "login", demo_key)
  let assert Ok(auth) = passwordless.with_policy(auth, 60_000, 3, 3_600_000)

  // Issuing does not send email. The application delivers the answer itself.
  let assert Ok(challenge) =
    passwordless.issue(
      auth,
      AccountId(42),
      "alice@example.com",
      passwordless.EmailCode(8),
    )
  let id = passwordless.challenge_id(challenge)
  let answer = passwordless.challenge_answer(challenge)

  // A wrong answer or a changed destination is refused with a typed reason.
  assert_refused(
    passwordless.verify(auth, id, "alice@example.com", "00000000"),
    store.WrongAnswer,
  )
  assert_refused(
    passwordless.verify(auth, id, "mallory@example.com", answer),
    store.BindingMismatch,
  )

  // Confirmed consumption yields opaque evidence. The application checks its
  // own account policy and publishes its own session.
  let assert Ok(evidence) =
    passwordless.verify(auth, id, "alice@example.com", answer)
  assert passwordless.subject(evidence) == AccountId(42)
  assert passwordless.destination(evidence) == "alice@example.com"
  assert passwordless.scope(evidence) == "example-app"
  assert passwordless.purpose(evidence) == "login"
  // Use the verification id as the idempotency identity if publishing a
  // session fails and must be retried with the retained evidence.
  assert passwordless.verification_id(evidence) != ""

  // A challenge is single use.
  assert_refused(
    passwordless.verify(auth, id, "alice@example.com", answer),
    store.Consumed,
  )

  // A magic link can be revoked before it is used.
  let assert Ok(link) =
    passwordless.issue(
      auth,
      AccountId(7),
      "bob@example.com",
      passwordless.MagicLink,
    )
  let link_id = passwordless.challenge_id(link)
  let assert Ok(Nil) = passwordless.revoke(auth, link_id)
  assert_refused(
    passwordless.verify(
      auth,
      link_id,
      "bob@example.com",
      passwordless.challenge_answer(link),
    ),
    store.Revoked,
  )

  // Configuration errors are typed: a short key is never accepted.
  assert passwordless.new(memory.store(runtime), "example-app", "login", <<
      1,
      2,
      3,
    >>)
    |> is_weak_key

  // An unknown outcome carries a recovery handle. Resolve the original
  // operation through the same authority; never repeat it blindly.
  let lost = process.new_subject()
  let assert Ok(recovering) =
    passwordless.new(
      losing_first_acknowledgement(memory.store(runtime), lost),
      "example-app",
      "login",
      demo_key,
    )
  let assert Ok(pending) =
    passwordless.issue(
      recovering,
      AccountId(9),
      "carol@example.com",
      passwordless.MagicLink,
    )
  process.send(lost, Nil)
  let assert Error(passwordless.VerifyUnknown(recovery)) =
    passwordless.verify(
      recovering,
      passwordless.challenge_id(pending),
      "carol@example.com",
      passwordless.challenge_answer(pending),
    )
  let assert Ok(recovered) = passwordless.recover_verify(recovery)
  assert passwordless.subject(recovered) == AccountId(9)

  let assert Ok(Nil) = memory.stop(runtime)
  Nil
}

fn assert_refused(
  result: Result(
    passwordless.Verified(AccountId),
    passwordless.VerifyError(AccountId),
  ),
  reason: store.Refusal,
) -> Nil {
  case result {
    Error(passwordless.Refused(actual)) -> {
      assert actual == reason
      Nil
    }
    _ -> panic as "expected a refusal"
  }
}

fn is_weak_key(
  result: Result(passwordless.Service(AccountId), passwordless.ConfigError),
) -> Bool {
  case result {
    Error(passwordless.WeakKey) -> True
    _ -> False
  }
}
