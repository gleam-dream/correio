import correio/passwordless as auth
import correio/passwordless/store
import correio_postgres as postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleeunit
import gleeunit/should
import pog

type Account {
  Account(Int)
}

const key = <<"0123456789abcdef0123456789abcdef":utf8>>

const email = "person@example.com"

pub fn main() {
  gleeunit.main()
}

type Pool {
  Pool(pid: process.Pid, data: pog.Connection, name: process.Name(pog.Message))
}

fn connect() -> Pool {
  let name = process.new_name("correio_pg_test")
  let assert Ok(config) = pog.url_config(name, database_url())
  let assert Ok(started) = config |> pog.pool_size(1) |> pog.start
  Pool(started.pid, started.data, name)
}

fn codec() -> postgres.Codec(Account) {
  postgres.Codec(
    fn(account) {
      let Account(id) = account
      int.to_string(id)
    },
    fn(value) { int.parse(value) |> result.map(Account) },
  )
}

fn service(db: Pool) -> auth.Service(Account) {
  let assert Ok(service) =
    auth.new(postgres.new(db.name, codec()), "test", "login", key)
  service
}

pub fn database_sequential_native_codec_binding_and_reuse_test() {
  let db = connect()
  postgres.migrate(db.data) |> should.equal(Ok(Nil))
  let service = service(db)
  let assert Ok(challenge) =
    auth.issue(service, Account(7), email, auth.EmailCode(6))
  auth.verify(
    service,
    auth.challenge_id(challenge),
    "changed@example.com",
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.BindingMismatch)))
  let assert Ok(evidence) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  auth.subject(evidence) |> should.equal(Account(7))
  auth.verify(
    service,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Consumed)))
  stop_pool(db.pid)
}

pub fn database_twenty_four_real_connections_have_one_winner_test() {
  let admin = connect()
  postgres.migrate(admin.data) |> should.equal(Ok(Nil))
  let assert Ok(challenge) =
    auth.issue(service(admin), Account(7), email, auth.MagicLink)
  let pools = list.repeat(Nil, 24) |> list.map(fn(_) { connect() })
  let backend_ids =
    list.map(pools, fn(pool) {
      let assert Ok(rows) =
        pog.query("select pg_backend_pid()")
        |> pog.returning(decode.at([0], decode.int))
        |> pog.execute(pool.data)
      let assert [id] = rows.rows
      id
    })
  backend_ids |> list.unique |> list.length |> should.equal(24)
  let replies =
    parallel(pools, fn(pool) {
      auth.verify(
        service(pool),
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
  list.each(pools, fn(pool) { stop_pool(pool.pid) })
  stop_pool(admin.pid)
}

pub fn database_wrong_attempt_race_and_recovery_test() {
  let admin = connect()
  postgres.migrate(admin.data) |> should.equal(Ok(Nil))
  let assert Ok(svc) = service(admin) |> auth.with_policy(10_000, 5, 20_000)
  let assert Ok(challenge) = auth.issue(svc, Account(7), email, auth.MagicLink)
  let pools = list.repeat(Nil, 12) |> list.map(fn(_) { connect() })
  let replies =
    parallel(pools, fn(pool) {
      auth.verify(
        service(pool),
        auth.challenge_id(challenge),
        email,
        "incorrect",
      )
    })
  replies
  |> list.filter(fn(reply) { reply == Error(auth.Refused(store.WrongAnswer)) })
  |> list.length
  |> should.equal(5)
  replies
  |> list.filter(fn(reply) { reply == Error(auth.Refused(store.Exhausted)) })
  |> list.length
  |> should.equal(7)
  auth.verify(
    svc,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Exhausted)))
  let backing = postgres.new(admin.name, codec())
  let loss = counter()
  let ambiguous =
    store.Store(..backing, verify: fn(command) {
      let reply = backing.verify(command)
      case increment(loss) == 1 {
        True -> Error(store.Unknown)
        False -> reply
      }
    })
  let assert Ok(svc) = auth.new(ambiguous, "test", "login", key)
  let assert Ok(fresh) = auth.issue(svc, Account(8), email, auth.MagicLink)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(
      svc,
      auth.challenge_id(fresh),
      email,
      auth.challenge_answer(fresh),
    )
  let assert Ok(evidence) = auth.recover_verify(recovery)
  let assert Ok(repeated) = auth.recover_verify(recovery)
  auth.authenticated_at(repeated)
  |> should.equal(auth.authenticated_at(evidence))
  list.each(pools, fn(pool) { stop_pool(pool.pid) })
  stop_pool(admin.pid)
}

pub fn database_expiry_is_sampled_after_actual_row_lock_wait_test() {
  let admin = connect()
  let locker = connect()
  let verifier = connect()
  postgres.migrate(admin.data) |> should.equal(Ok(Nil))
  let assert Ok(svc) = service(admin) |> auth.with_policy(1000, 5, 20_000)
  let assert Ok(challenge) = auth.issue(svc, Account(7), email, auth.MagicLink)
  let locked = process.new_subject()
  let completed = process.new_subject()
  let _ =
    process.spawn(fn() {
      let release = process.new_subject()
      let assert Ok(Nil) =
        pog.transaction(locker.data, fn(connection) {
          let assert Ok(_) =
            pog.query("select id from ecarta_challenges where id=$1 for update")
            |> pog.parameter(pog.text(auth.challenge_id(challenge)))
            |> pog.execute(connection)
          process.send(locked, release)
          let assert Ok(Nil) = process.receive(release, 5000)
          Ok(Nil)
        })
      process.send(completed, Nil)
    })
  let assert Ok(release) = process.receive(locked, 5000)
  let reply = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        reply,
        auth.verify(
          service(verifier),
          auth.challenge_id(challenge),
          email,
          auth.challenge_answer(challenge),
        ),
      )
    })
  wait_for_lock(admin.data, 100) |> should.be_true
  let assert Ok(_) =
    pog.query(
      "select pg_sleep(greatest(0, ($1 - floor(extract(epoch from clock_timestamp()) * 1000)::bigint)::double precision / 1000) + 0.02)::text",
    )
    |> pog.parameter(pog.int(auth.challenge_expires_at(challenge)))
    |> pog.execute(admin.data)
  process.send(release, Nil)
  let assert Ok(outcome) = process.receive(reply, 5000)
  outcome |> should.equal(Error(auth.Refused(store.Expired)))
  process.receive(completed, 5000) |> should.equal(Ok(Nil))
  stop_pool(verifier.pid)
  stop_pool(locker.pid)
  stop_pool(admin.pid)
}

fn wait_for_lock(db: pog.Connection, remaining: Int) -> Bool {
  let assert Ok(rows) =
    pog.query(
      "select exists(select 1 from pg_stat_activity where wait_event_type='Lock' and query like 'select id,subject,%ecarta_challenges%')",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(db)
  case rows.rows, remaining {
    [True], _ -> True
    _, 0 -> False
    _, _ -> {
      process.sleep(10)
      wait_for_lock(db, remaining - 1)
    }
  }
}

pub fn database_codec_mismatch_and_cleanup_test() {
  let db = connect()
  postgres.migrate(db.data) |> should.equal(Ok(Nil))
  let assert Ok(challenge) =
    auth.issue(service(db), Account(7), email, auth.MagicLink)
  let incompatible =
    postgres.new(db.name, postgres.Codec(fn(v) { v }, fn(_) { Error(Nil) }))
  let assert Ok(other) = auth.new(incompatible, "test", "login", key)
  auth.verify(
    other,
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.VerifyFailed(store.IncompatibleData)))
  let assert Ok(_) =
    pog.query(
      "update ecarta_challenges set expires_at_ms=1, retain_until_ms=2 where id=$1",
    )
    |> pog.parameter(pog.text(auth.challenge_id(challenge)))
    |> pog.execute(db.data)
  postgres.new(db.name, codec()).cleanup(1) |> should.equal(Ok(1))
  stop_pool(db.pid)
}

pub type Counter

@external(erlang, "correio_postgres_test_ffi", "database_url")
fn database_url() -> String

@external(erlang, "correio_postgres_test_ffi", "stop_pool")
fn stop_pool(pid: process.Pid) -> Nil

@external(erlang, "correio_postgres_test_ffi", "parallel")
fn parallel(inputs: List(a), function: fn(a) -> b) -> List(b)

@external(erlang, "correio_postgres_test_ffi", "counter")
fn counter() -> Counter

@external(erlang, "correio_postgres_test_ffi", "increment")
fn increment(counter: Counter) -> Int

pub fn committed_verification_recovers_after_wire_acknowledgement_loss_test() {
  let proxy = proxy_start()
  let name = process.new_name("correio_fault_peer")
  let assert Ok(config) = pog.url_config(name, proxy_url(proxy))
  let assert Ok(started) = config |> pog.pool_size(1) |> pog.start
  let db = Pool(started.pid, started.data, name)
  postgres.migrate(db.data) |> should.equal(Ok(Nil))
  let svc = service(db)
  let assert Ok(challenge) = auth.issue(svc, Account(7), email, auth.MagicLink)
  proxy_arm(proxy)
  let assert Error(auth.VerifyUnknown(recovery)) =
    auth.verify(
      svc,
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  proxy_confirmed(proxy) |> should.be_true
  // The peer stays alive and permits the pool's replacement connection.
  let evidence = recover_after_reconnect(recovery, 100)
  auth.subject(evidence) |> should.equal(Account(7))
  let again = recover_after_reconnect(recovery, 100)
  auth.authenticated_at(again) |> should.equal(auth.authenticated_at(evidence))
  let independent = connect()
  auth.verify(
    service(independent),
    auth.challenge_id(challenge),
    email,
    auth.challenge_answer(challenge),
  )
  |> should.equal(Error(auth.Refused(store.Consumed)))
  stop_pool(independent.pid)
  stop_pool(db.pid)
  proxy_stop(proxy)
}

fn recover_after_reconnect(
  recovery: auth.VerifyRecovery(Account),
  attempts: Int,
) -> auth.Verified(Account) {
  case auth.recover_verify(recovery), attempts {
    Ok(evidence), _ -> evidence
    Error(_), n if n > 0 -> {
      process.sleep(20)
      recover_after_reconnect(recovery, n - 1)
    }
    Error(error), _ -> panic as auth.describe_verify_error(error)
  }
}

pub type Proxy

@external(erlang, "correio_postgres_test_ffi", "proxy_start")
fn proxy_start() -> Proxy

@external(erlang, "correio_postgres_test_ffi", "proxy_url")
fn proxy_url(proxy: Proxy) -> String

@external(erlang, "correio_postgres_test_ffi", "proxy_arm")
fn proxy_arm(proxy: Proxy) -> Nil

@external(erlang, "correio_postgres_test_ffi", "proxy_confirmed")
fn proxy_confirmed(proxy: Proxy) -> Bool

@external(erlang, "correio_postgres_test_ffi", "proxy_stop")
fn proxy_stop(proxy: Proxy) -> Nil

pub fn challenge_survives_pool_restart_and_stopped_pool_is_typed_test() {
  let first = connect()
  postgres.migrate(first.data) |> should.equal(Ok(Nil))
  let assert Ok(challenge) =
    auth.issue(service(first), Account(9), email, auth.MagicLink)
  let backing = postgres.new(first.name, codec())
  stop_pool(first.pid)
  backing.cleanup(10) |> should.be_error
  postgres.migrate(first.data) |> should.be_error
  let restarted = connect()
  let assert Ok(evidence) =
    auth.verify(
      service(restarted),
      auth.challenge_id(challenge),
      email,
      auth.challenge_answer(challenge),
    )
  auth.subject(evidence) |> should.equal(Account(9))
  stop_pool(restarted.pid)
}
