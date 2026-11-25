import correio/passwordless as auth
import correio/passwordless/memory
import correio/passwordless/store
import gleam/erlang/process.{type Name, type Pid}
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleeunit/should

type Account {
  Account(id: Int)
}

const key = <<"0123456789abcdef0123456789abcdef":utf8>>

const email = "person@example.com"

pub fn native_subject_and_single_use_test() {
  let assert Ok(runtime) = start(20)
  let assert Ok(service) = auth.new(runtime.store, "my-app", "login", key)
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
  stop(runtime)
}

pub fn twenty_four_independent_commands_have_one_winner_test() {
  let assert Ok(runtime) = start(20)
  let assert Ok(service) = auth.new(runtime.store, "my-app", "login", key)
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
  stop(runtime)
}

pub fn expiry_binding_and_bounded_attempts_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(20, fn() { clock_get(clock) })
  let backing = runtime.store
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
  stop(runtime)
}

pub fn unknown_acknowledgement_recovers_original_receipt_after_expiry_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(20, fn() { clock_get(clock) })
  let backing = runtime.store
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
  stop(runtime)
}

pub fn wrong_answer_recovery_does_not_spend_twice_test() {
  let assert Ok(runtime) = start(20)
  let backing = runtime.store
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
  stop(runtime)
}

pub fn issue_recovery_capacity_cleanup_and_stop_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(1, fn() { clock_get(clock) })
  let backing = runtime.store
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
  stop(runtime)
  auth.issue(service, Account(8), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Unavailable)))
}

pub fn revoke_and_new_issue_are_independent_test() {
  let assert Ok(runtime) = start(20)
  let assert Ok(service) = auth.new(runtime.store, "app", "login", key)
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
  stop(runtime)
}

pub fn invalid_configuration_has_no_effect_test() {
  let assert Ok(runtime) = start(1)
  auth.new(runtime.store, "app", "login", <<1>>)
  |> should.equal(Error(auth.WeakKey))
  auth.new(runtime.store, "", "login", key)
  |> should.equal(Error(auth.InvalidBinding))
  let assert Ok(service) = auth.new(runtime.store, "app", "login", key)
  auth.with_policy(service, 0, 2, 10) |> should.equal(Error(auth.InvalidPolicy))
  auth.issue(service, 1, email, auth.EmailCode(5))
  |> should.equal(Error(auth.InvalidIssue(auth.InvalidCodeLength)))
  let assert Ok(_) = auth.issue(service, 1, email, auth.EmailCode(6))
  stop(runtime)
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
  let assert Ok(runtime) = start_with_clock(10, fn() { clock_get(clock) })
  let backing = runtime.store
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
  stop(runtime)
}

pub fn unaligned_signing_key_is_refused_test() {
  let assert Ok(runtime) = start(1)
  let invalid = <<"0123456789abcdef0123456789abcdef":utf8, 1:1>>
  auth.new(runtime.store, "app", "login", invalid)
  |> should.equal(Error(auth.WeakKey))
  stop(runtime)
}

pub fn observed_expiry_cannot_be_reversed_by_clock_rollback_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(10, fn() { clock_get(clock) })
  let assert Ok(service) = auth.new(runtime.store, "app", "login", key)
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
  stop(runtime)
}

pub fn wrong_attempt_receipt_survives_later_consumption_test() {
  let assert Ok(runtime) = start(10)
  let backing = runtime.store
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
  stop(runtime)
}

pub fn full_store_evicts_expired_unconsumed_challenges_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(2, fn() { clock_get(clock) })
  let assert Ok(service) = auth.new(runtime.store, "app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 86_400_000)
  let assert Ok(_) = auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Ok(_) = auth.issue(service, Account(2), email, auth.MagicLink)
  auth.issue(service, Account(3), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Capacity)))
  // Both challenges are past validity and far inside receipt retention.
  clock_set(clock, 1010)
  let assert Ok(_) = auth.issue(service, Account(3), email, auth.MagicLink)
  let assert Ok(_) = auth.issue(service, Account(4), email, auth.MagicLink)
  auth.issue(service, Account(5), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Capacity)))
  stop(runtime)
}

pub fn full_store_keeps_consumption_receipts_inside_retention_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) = start_with_clock(1, fn() { clock_get(clock) })
  let backing = runtime.store
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, verify: fn(command) {
      let result = backing.verify(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> result
      }
    })
  let assert Ok(service) = auth.new(unreliable, "app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 20)
  let assert Ok(challenge) =
    auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  clock_set(clock, 1029)
  auth.issue(service, Account(2), email, auth.MagicLink)
  |> should.equal(Error(auth.IssueFailed(store.Capacity)))
  let assert Ok(verified) = auth.recover_verify(recovery)
  auth.subject(verified) |> should.equal(Account(1))
  // Retention has ended, so the receipt no longer holds its slot.
  clock_set(clock, 1030)
  let assert Ok(_) = auth.issue(service, Account(2), email, auth.MagicLink)
  stop(runtime)
}

pub fn store_removes_rows_past_retention_without_a_cleanup_call_test() {
  let clock = clock_new(1000)
  let assert Ok(runtime) =
    start_with_cleanup_interval(10, fn() { clock_sample(clock) }, 1)
  let backing = runtime.store
  let assert Ok(service) = auth.new(backing, "app", "login", key)
  let assert Ok(service) = auth.with_policy(service, 10, 2, 20)
  let assert Ok(_) = auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Ok(_) = auth.issue(service, Account(2), email, auth.MagicLink)
  clock_set(clock, 1030)
  // The store samples its clock only inside a command or its own cleanup, and
  // no command runs here, so this sample is the store's own cleanup.
  await_sample(1030) |> should.equal(Ok(Nil))
  backing.cleanup(10) |> should.equal(Ok(0))
  stop(runtime)
}

@external(erlang, "correio_auth_test_ffi", "clock_sample")
fn clock_sample(clock: Clock) -> Int

@external(erlang, "correio_auth_test_ffi", "await_sample")
fn await_sample(value: Int) -> Result(Nil, Nil)

pub fn invalid_capacity_is_refused_before_a_process_starts_test() {
  let name = process.new_name("correio_test_store")
  memory.new(name, 0) |> should.equal(Error(memory.InvalidCapacity))
  memory.new(name, 1_000_001) |> should.equal(Error(memory.InvalidCapacity))
  process.named(name) |> should.equal(Error(Nil))
}

pub fn failed_store_restarts_empty_under_its_name_test() {
  let assert Ok(runtime) = start(10)
  let assert Ok(service) = auth.new(runtime.store, "app", "login", key)
  let assert Ok(challenge) =
    auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Ok(failed) = process.named(runtime.name)
  process.kill(failed)
  let assert Ok(restarted) = await_restart(runtime.name, failed)
  { restarted != failed } |> should.be_true
  // The same store value reaches the replacement, which holds no rows.
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Missing)))
  let assert Ok(_) = auth.issue(service, Account(2), email, auth.MagicLink)
  stop(runtime)
}

/// An issue recovery handle is bound to the store process that produced its
/// command. After a restart it cannot insert the challenge again, even before
/// the challenge's original expiry, so a consumed challenge stays unusable.
pub fn issue_recovery_cannot_recreate_a_challenge_after_restart_test() {
  let assert Ok(runtime) = start(10)
  let backing = runtime.store
  let loss = clock_new(0)
  let unreliable =
    store.Store(..backing, issue: fn(command) {
      let result = backing.issue(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> result
      }
    })
  let assert Ok(service) = auth.new(unreliable, "app", "login", key)
  let assert Error(auth.IssueUnknown(recovery)) =
    auth.issue(service, Account(1), email, auth.MagicLink)
  let assert Ok(challenge) = auth.recover_issue(recovery)
  let assert Ok(_) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  let assert Ok(failed) = process.named(runtime.name)
  process.kill(failed)
  let assert Ok(_) = await_restart(runtime.name, failed)
  auth.recover_issue(recovery)
  |> should.equal(Error(auth.IssueFailed(store.IssueExpired)))
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Missing)))
  // A fresh issue reaches the restarted store.
  let assert Ok(_) = auth.issue(service, Account(2), email, auth.MagicLink)
  stop(runtime)
}

pub fn store_failure_leaves_its_callers_running_test() {
  let assert Ok(runtime) =
    start_configured(10, fn(config) {
      memory.with_clock(config, fn() { panic })
    })
  // The command fails inside the store, and this process keeps running.
  runtime.store.now() |> should.equal(Error(store.Unknown))
  stop(runtime)
}

pub fn store_stops_with_its_supervisor_test() {
  let assert Ok(runtime) = start(10)
  runtime.store.now() |> should.be_ok
  stop(runtime)
  runtime.store.now() |> should.equal(Error(store.Unavailable))
}

/// A memory store under its own static supervisor, as an application starts it.
pub type Running(a) {
  Running(supervisor: Pid, name: Name(memory.Message(a)), store: store.Store(a))
}

fn start_configured(
  capacity: Int,
  configure: fn(memory.Config(a)) -> memory.Config(a),
) -> Result(Running(a), Nil) {
  let name = process.new_name("correio_test_store")
  use config <- result.try(
    memory.new(name, capacity) |> result.replace_error(Nil),
  )
  use started <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(memory.supervised(configure(config)))
    |> supervisor.start
    |> result.replace_error(Nil),
  )
  Ok(Running(started.pid, name, memory.store(name)))
}

fn start(capacity: Int) -> Result(Running(a), Nil) {
  start_configured(capacity, fn(config) { config })
}

fn start_with_clock(
  capacity: Int,
  clock: fn() -> Int,
) -> Result(Running(a), Nil) {
  start_configured(capacity, memory.with_clock(_, clock))
}

fn start_with_cleanup_interval(
  capacity: Int,
  clock: fn() -> Int,
  interval_ms: Int,
) -> Result(Running(a), Nil) {
  start_configured(capacity, fn(config) {
    config
    |> memory.with_clock(clock)
    |> memory.with_cleanup_interval(interval_ms)
  })
}

fn stop(running: Running(a)) -> Nil {
  stop_supervisor(running.supervisor)
}

@external(erlang, "correio_auth_test_ffi", "stop_supervisor")
fn stop_supervisor(supervisor: Pid) -> Nil

@external(erlang, "correio_auth_test_ffi", "await_restart")
fn await_restart(name: Name(message), failed: Pid) -> Result(Pid, Nil)
