import correio/passwordless as auth
import correio/passwordless/memory
import correio/passwordless/store
import gleam/list
import gleeunit/should

type Account {
  Account(id: Int)
}

const key = <<"0123456789abcdef0123456789abcdef":utf8>>

const email = "person@example.com"

pub fn native_subject_and_single_use_test() {
  let assert Ok(runtime) = memory.start(20)
  let assert Ok(service) =
    auth.new(memory.store(runtime), "my-app", "login", key)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.MagicLink)
  let assert Ok(evidence) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  auth.subject(evidence) |> should.equal(Account(7))
  auth.scope(evidence) |> should.equal("my-app")
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Consumed)))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn twenty_four_independent_commands_have_one_winner_test() {
  let assert Ok(runtime) = memory.start(20)
  let assert Ok(service) =
    auth.new(memory.store(runtime), "my-app", "login", key)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.MagicLink)
  let replies =
    parallel(24, fn() {
      auth.verify(
        service,
        auth.challenge_id(challenge),
        email,
        auth.challenge_answer(challenge),
      )
    })
  replies
  |> list.filter(fn(reply) {
    case reply {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> list.length
  |> should.equal(1)
  replies
  |> list.filter(fn(reply) { reply == Error(auth.Refused(store.Consumed)) })
  |> list.length
  |> should.equal(23)
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn expiry_binding_and_bounded_attempts_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) =
    memory.start_with_clock(20, fn() { clock_get(clock) })
  let backing = memory.store(runtime)
  let assert Ok(service) = auth.new(backing, "my-app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 100)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.EmailCode(6))
  let id = auth.challenge_id(challenge)
  let answer = auth.challenge_answer(challenge)
  let assert Ok(other) = auth.new(backing, "my-app", "reset", key)
  auth.verify(other, id, email, answer)
  |> should.equal(Error(auth.Refused(store.BindingMismatch)))
  auth.verify(service, id, "changed@example.com", answer)
  |> should.equal(Error(auth.Refused(store.BindingMismatch)))
  auth.verify(service, id, email, "incorrect")
  |> should.equal(Error(auth.Refused(store.WrongAnswer)))
  auth.verify(service, id, email, "incorrect")
  |> should.equal(Error(auth.Refused(store.WrongAnswer)))
  auth.verify(service, id, email, answer)
  |> should.equal(Error(auth.Refused(store.Exhausted)))
  let assert Ok(fresh) = auth.issue(service, Account(7), email, auth.MagicLink)
  clock_set(clock, 1010)
  auth.verify(
    service,
    auth.challenge_id(fresh),
    email,
    auth.challenge_answer(fresh),
  )
  |> should.equal(Error(auth.Refused(store.Expired)))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn unknown_acknowledgement_recovers_original_receipt_after_expiry_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) =
    memory.start_with_clock(20, fn() { clock_get(clock) })
  let backing = memory.store(runtime)
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, verify: fn(command) {
      let result = backing.verify(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> result
      }
    })
  let assert Ok(service) = auth.new(unreliable, "my-app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 100)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  clock_set(clock, 1050)
  let assert Ok(evidence) = auth.recover_verify(recovery)
  auth.authenticated_at(evidence) |> should.equal(1000)
  let assert Ok(again) = auth.recover_verify(recovery)
  auth.authenticated_at(again) |> should.equal(1000)
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn wrong_answer_recovery_does_not_spend_twice_test() {
  let assert Ok(runtime) = memory.start(20)
  let backing = memory.store(runtime)
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, verify: fn(command) {
      let result = backing.verify(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> result
      }
    })
  let assert Ok(service) = auth.new(unreliable, "my-app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 1000, 2, 100)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(service, auth.challenge_id(challenge), email, "wrong")
  auth.recover_verify(recovery)
  |> should.equal(Error(auth.Refused(store.WrongAnswer)))
  auth.recover_verify(recovery)
  |> should.equal(Error(auth.Refused(store.WrongAnswer)))
  let assert Ok(_) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn issue_recovery_capacity_cleanup_and_stop_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = memory.start_with_clock(1, fn() { clock_get(clock) })
  let backing = memory.store(runtime)
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, issue: fn(command) {
      let result = backing.issue(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> result
      }
    })
  let assert Ok(service) = auth.new(unreliable, "my-app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 20)
  let assert Error(auth.IssueUnknown(recovery)) =
    auth.issue(service, Account(7), email, auth.MagicLink)
  let assert Ok(first) = auth.recover_issue(recovery)
  let assert Ok(again) = auth.recover_issue(recovery)
  auth.challenge_answer(again) |> should.equal(auth.challenge_answer(first))
  auth.challenge_id(again) |> should.equal(auth.challenge_id(first))
  auth.issue(service, Account(8), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Capacity)))
  clock_set(clock, 1029)
  backing.cleanup(10) |> should.equal(Ok(0))
  clock_set(clock, 1030)
  backing.cleanup(10) |> should.equal(Ok(1))
  let assert Ok(_) = auth.issue(service, Account(8), email, auth.MagicLink)
  memory.stop(runtime) |> should.equal(Ok(Nil))
  auth.issue(service, Account(8), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Unavailable)))
}

pub fn revoke_and_new_issue_are_independent_test() {
  let assert Ok(runtime) = memory.start(20)
  let assert Ok(service) = auth.new(memory.store(runtime), "app", "login", key)
  let assert Ok(first) = auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Ok(second) = auth.issue(service, Account(1), email, auth.MagicLink)
  auth.revoke(service, auth.challenge_id(first)) |> should.equal(Ok(Nil))
  auth.verify(
    service,
    auth.challenge_id(first),
    email,
    auth.challenge_answer(first),
  )
  |> should.equal(Error(auth.Refused(store.Revoked)))
  let assert Ok(_) =
    auth.verify(
      service,
      auth.challenge_id(second),
      email,
      auth.challenge_answer(second),
    )
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn invalid_configuration_has_no_effect_test() {
  let assert Ok(runtime) = memory.start(1)
  auth.new(memory.store(runtime), "app", "login", <<1>>)
  |> should.equal(Error(auth.WeakKey))
  auth.new(memory.store(runtime), "", "login", key)
  |> should.equal(Error(auth.InvalidBinding))
  let assert Ok(service) = auth.new(memory.store(runtime), "app", "login", key)
  auth.with_policy(service, 0, 2, 10) |> should.equal(Error(auth.InvalidPolicy))
  auth.issue(service, 1, email, auth.EmailCode(5))
  |> should.equal(Error(auth.InvalidIssue(auth.InvalidCodeLength)))
  let assert Ok(_) = auth.issue(service, 1, email, auth.EmailCode(6))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub type Clock

@external(erlang, "correio_auth_test_ffi", "clock_new")
fn clock_new(now: Int) -> Clock

@external(erlang, "correio_auth_test_ffi", "clock_get")
fn clock_get(clock: Clock) -> Int

@external(erlang, "correio_auth_test_ffi", "clock_set")
fn clock_set(clock: Clock, now: Int) -> Nil

@external(erlang, "correio_auth_test_ffi", "increment")
fn increment(clock: Clock) -> Int

@external(erlang, "correio_auth_test_ffi", "parallel")
fn parallel(count: Int, function: fn() -> a) -> List(a)

pub fn recovery_expires_without_cleanup_and_cannot_reinsert_after_cleanup_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) =
    memory.start_with_clock(10, fn() { clock_get(clock) })
  let backing = memory.store(runtime)
  let unreliable =
    store.Store(
      ..backing,
      issue: fn(command) {
        let _ = backing.issue(command)
        Error(store.Unknown)
      },
      verify: fn(command) {
        let _ = backing.verify(command)
        Error(store.Unknown)
      },
    )
  let assert Ok(service) = auth.new(unreliable, "app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 5, 20)
  let assert Error(auth.IssueUnknown(issue_recovery)) =
    auth.issue(service, 1, email, auth.MagicLink)
  // Obtain the original challenge via a one-time unavailable-ack decorator.
  let captured = clock_new(0)
  let once =
    store.Store(..backing, verify: fn(command) {
      let value = backing.verify(command)
      case increment(captured) == 1 {
        True -> Error(store.Unknown)
        False -> value
      }
    })
  let assert Ok(other) = auth.new(once, "app", "login", key)
  let assert Ok(other) = auth.with_policy(other, 10, 5, 20)
  let assert Ok(challenge) = auth.issue(other, 2, email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(verify_recovery)) =
    auth.verify(
      other,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  clock_set(clock, 1030)
  auth.recover_verify(verify_recovery)
  |> should.equal(Error(auth.Refused(store.Expired)))
  backing.cleanup(10) |> should.equal(Ok(2))
  // Always-unknown adapter still cannot recreate an expired command.
  let assert Error(auth.IssueUnknown(_)) = auth.recover_issue(issue_recovery)
  backing.cleanup(10) |> should.equal(Ok(0))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn unaligned_signing_key_is_refused_test() {
  let assert Ok(runtime) = memory.start(1)
  let invalid = <<"0123456789abcdef0123456789abcdef":utf8, 1:1>>
  auth.new(memory.store(runtime), "app", "login", invalid)
  |> should.equal(Error(auth.WeakKey))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn observed_expiry_cannot_be_reversed_by_clock_rollback_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) =
    memory.start_with_clock(10, fn() { clock_get(clock) })
  let assert Ok(service) = auth.new(memory.store(runtime), "app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 5, 20)
  let assert Ok(challenge) = auth.issue(service, 1, email, auth.MagicLink)
  clock_set(clock, 1010)
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Expired)))
  clock_set(clock, 1000)
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Expired)))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

pub fn wrong_attempt_receipt_survives_later_consumption_test() {
  let assert Ok(runtime) = memory.start(10)
  let backing = memory.store(runtime)
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, verify: fn(command) {
      let reply = backing.verify(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> reply
      }
    })
  let assert Ok(service) = auth.new(unreliable, "app", "login", key)
  let assert Ok(challenge) = auth.issue(service, 1, email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(service, auth.challenge_id(challenge), email, "wrong")
  let assert Ok(_) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  auth.recover_verify(recovery)
  |> should.equal(Error(auth.Refused(store.WrongAnswer)))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}
