import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/passwordless as auth
import correio/passwordless/memory
import correio/passwordless/store
import correio/testing
import correio_mailbox
import correio_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import identity.{AccountId}
import passwordless_demo as demo
import pog
import readme_examples

const key = <<"0123456789abcdef0123456789abcdef":utf8>>

type Fixture {
  Fixture(
    demo: demo.Demo,
    pool: process.Pid,
    db: pog.Connection,
    service: auth.Service(identity.AccountId),
  )
}

pub fn main() {
  gleeunit.main()
}

fn start() -> Fixture {
  start_with_store(fn(store) { store })
}

fn start_with_store(
  decorate: fn(store.Store(identity.AccountId)) ->
    store.Store(identity.AccountId),
) -> Fixture {
  start_configured(decorate, False)
}

fn start_configured(
  decorate: fn(store.Store(identity.AccountId)) ->
    store.Store(identity.AccountId),
  expose_mailbox: Bool,
) -> Fixture {
  let name = process.new_name("correio_browser_demo")
  let assert Ok(config) = pog.url_config(name, database_url())
  let assert Ok(pool) = config |> pog.pool_size(4) |> pog.start
  let assert Ok(_) = correio_postgres.migrate(pool.data)
  let codec =
    correio_postgres.Codec(
      fn(account) {
        let AccountId(id) = account
        int.to_string(id)
      },
      fn(raw) { int.parse(raw) |> result.map(AccountId) },
    )
  let assert Ok(service) =
    auth.new(
      decorate(correio_postgres.new(name, codec)),
      "browser-demo",
      "login",
      key,
    )
  let assert Ok(service) = auth.with_policy(service, 120_000, 3, 3_600_000)
  let assert Ok(app) = case expose_mailbox {
    True -> demo.start_with_mailbox(service)
    False -> demo.start(service)
  }
  Fixture(app, pool.pid, pool.data, service)
}

fn stop(fixture: Fixture) {
  demo.stop(fixture.demo) |> should.equal(Ok(Nil))
  stop_pool(fixture.pool)
}

fn header(response: demo.Response, name: String) -> String {
  list.key_find(response.headers, name) |> result.unwrap("")
}

fn set_cookie(response: demo.Response) -> String {
  header(response, "set-cookie")
  |> string.split(";")
  |> list.first
  |> result.unwrap("")
}

fn post(
  app: demo.Demo,
  target: String,
  cookie: String,
  body: String,
) -> demo.Response {
  request(
    demo.port(app),
    "POST",
    target,
    [#("origin", demo.origin(app)), #("cookie", cookie)],
    body,
  )
}

fn get(app: demo.Demo, target: String, cookie: String) -> demo.Response {
  request(demo.port(app), "GET", target, [#("cookie", cookie)], "")
}

fn last_mail(app: demo.Demo) -> String {
  let assert Ok(messages) = demo.captured_messages(app)
  let assert Ok(mail) = messages |> list.reverse |> list.first
  case message.view(mail).body {
    message.Text(body) | message.Alternative(body, _) -> body
    message.Html(body) -> body
  }
}

fn csrf(page: demo.Response) -> String {
  let assert [_, after] = string.split(page.body, "name=csrf value=")
  let assert [value, ..] = string.split(after, ">")
  value
}

fn link(app: demo.Demo) -> #(String, String) {
  let issued = post(app, "/issue", "", "email=alice@example.com")
  issued.status |> should.equal(202)
  header(issued, "set-cookie")
  |> string.contains("HttpOnly; SameSite=Lax")
  |> should.be_true
  let browser = set_cookie(issued)
  let target = last_mail(app) |> string.replace(demo.origin(app), "")
  #(browser, target)
}

fn pending_id(target: String) -> String {
  let assert [_, rest] = string.split(target, "id=")
  let assert [id, ..] = string.split(rest, "&")
  id
}

pub fn http_link_get_never_consumes_and_post_rotates_session_test() {
  let fixture = start()
  let app = fixture.demo
  let #(browser, target) = link(app)
  // Host is attacker.invalid on every actual wire request; links use configured origin.
  last_mail(app) |> string.starts_with(demo.origin(app)) |> should.be_true
  get(app, target, "").status |> should.equal(403)
  let landing = get(app, target, browser)
  landing.status |> should.equal(303)
  header(landing, "location") |> should.equal("/confirm")
  header(landing, "referrer-policy") |> should.equal("no-referrer")
  let assert Ok(rows) =
    pog.query("select status from ecarta_challenges where id=$1")
    |> pog.parameter(pog.text(pending_id(target)))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(fixture.db)
  rows.rows |> should.equal(["active"])
  let page = get(app, "/confirm", browser)
  page.body |> string.contains("answer=") |> should.be_false
  let token = csrf(page)
  request(
    demo.port(app),
    "POST",
    "/confirm",
    [#("origin", "https://attacker.invalid"), #("cookie", browser)],
    "csrf=" <> token,
  ).status
  |> should.equal(403)
  post(app, "/confirm", browser, "csrf=wrong").status |> should.equal(403)
  let signed_in =
    post(
      app,
      "/confirm",
      browser <> "; session=fixed-attacker-value",
      "csrf=" <> token,
    )
  signed_in.status |> should.equal(200)
  let session = set_cookie(signed_in)
  session |> should.not_equal("session=fixed-attacker-value")
  header(signed_in, "set-cookie")
  |> string.contains("HttpOnly; SameSite=Strict")
  |> should.be_true
  get(app, "/session", session).status |> should.equal(200)
  get(app, "/session", "session=fixed-attacker-value").status
  |> should.equal(401)
  let assert [_, answer] = string.split(target, "&answer=")
  auth.verify(fixture.service, pending_id(target), "alice@example.com", answer)
  |> should.equal(Error(auth.Refused(store.Consumed)))
  stop(fixture)
}

pub fn http_unknown_account_and_admission_are_neutral_test() {
  let fixture = start()
  let app = fixture.demo
  let known = post(app, "/issue", "", "email=alice@example.com")
  let unknown = post(app, "/issue", "", "email=nobody@example.com")
  known.status |> should.equal(unknown.status)
  known.body |> should.equal(unknown.body)
  set_cookie(unknown) |> string.starts_with("browser=") |> should.be_true
  list.repeat(Nil, 5)
  |> list.each(fn(_) {
    post(app, "/issue", "", "email=alice@example.com").status
    |> should.equal(202)
  })
  let assert Ok(mails) = demo.captured_messages(app)
  list.length(mails) |> should.equal(3)
  stop(fixture)
}

pub fn http_session_publication_recovers_without_second_verification_test() {
  let fixture = start()
  let app = fixture.demo
  let #(browser, target) = link(app)
  get(app, target, browser).status |> should.equal(303)
  let token = csrf(get(app, "/confirm", browser))
  demo.fail_next_publication(app) |> should.equal(Ok(Nil))
  post(app, "/confirm", browser, "csrf=" <> token).status |> should.equal(503)
  post(app, "/confirm", "browser=other", "csrf=" <> token).status
  |> should.equal(403)
  let retry = post(app, "/confirm", browser, "csrf=" <> token)
  retry.status |> should.equal(200)
  let again = post(app, "/confirm", browser, "csrf=" <> token)
  set_cookie(again) |> should.equal(set_cookie(retry))
  get(app, "/session", set_cookie(retry)).status |> should.equal(200)
  stop(fixture)
}

pub fn http_cross_device_code_and_changed_account_policy_test() {
  let fixture = start()
  let app = fixture.demo
  post(app, "/issue", "", "email=alice@example.com&mode=code").status
  |> should.equal(202)
  let assert [id_line, code_line, url] = string.split(last_mail(app), "\n")
  let id = string.replace(id_line, "Challenge: ", "")
  let answer = string.replace(code_line, "Code: ", "")
  let page = get(app, string.replace(url, demo.origin(app), ""), "")
  page.status |> should.equal(200)
  post(
    app,
    "/confirm",
    set_cookie(page),
    "csrf=" <> csrf(page) <> "&answer=" <> answer,
  ).status
  |> should.equal(200)
  auth.verify(fixture.service, id, "alice@example.com", answer)
  |> should.equal(Error(auth.Refused(store.Consumed)))
  let #(browser, target) = link(app)
  get(app, target, browser).status |> should.equal(303)
  let token = csrf(get(app, "/confirm", browser))
  demo.set_account(app, "changed@example.com", True) |> should.equal(Ok(Nil))
  post(app, "/confirm", browser, "csrf=" <> token).status |> should.equal(403)
  demo.set_account(app, "alice@example.com", False) |> should.equal(Ok(Nil))
  post(app, "/confirm", browser, "csrf=" <> token).status |> should.equal(403)
  stop(fixture)
}

pub fn readme_memory_example_is_executable_test() {
  let #(runtime, service) = readme_examples.service(key)
  let assert Ok(challenge) =
    auth.issue(
      service,
      readme_examples.AccountId(42),
      "native@example.com",
      auth.EmailCode(8),
    )
  let assert Ok(evidence) =
    auth.verify(
      service,
      auth.challenge_id(challenge),
      "native@example.com",
      auth.challenge_answer(challenge),
    )
  auth.subject(evidence) |> should.equal(readme_examples.AccountId(42))
  memory.stop(runtime) |> should.equal(Ok(Nil))
}

@external(erlang, "correio_demo_test_ffi", "database_url")
fn database_url() -> String

@external(erlang, "correio_demo_test_ffi", "stop_pool")
fn stop_pool(pid: process.Pid) -> Nil

@external(erlang, "correio_demo_test_ffi", "request")
fn request(
  port: Int,
  method: String,
  target: String,
  headers: List(#(String, String)),
  body: String,
) -> demo.Response

pub fn http_code_identifier_cannot_copy_verified_browser_authority_test() {
  let fixture = start()
  let app = fixture.demo
  post(app, "/issue", "", "email=alice@example.com&mode=code").status
  |> should.equal(202)
  let assert [_, code_line, url] = string.split(last_mail(app), "\n")
  let answer = string.replace(code_line, "Code: ", "")
  let target = string.replace(url, demo.origin(app), "")
  let first = get(app, target, "")
  // Exercise the dangerous state: consumption succeeded but publication failed.
  demo.fail_next_publication(app) |> should.equal(Ok(Nil))
  post(
    app,
    "/confirm",
    set_cookie(first),
    "csrf=" <> csrf(first) <> "&answer=" <> answer,
  ).status
  |> should.equal(503)
  let attacker = get(app, target, "")
  attacker.status |> should.equal(200)
  post(
    app,
    "/confirm",
    set_cookie(attacker),
    "csrf=" <> csrf(attacker) <> "&answer=",
  ).status
  |> should.equal(403)
  get(app, "/session", set_cookie(attacker)).status |> should.equal(401)
  post(app, "/confirm", set_cookie(first), "csrf=" <> csrf(first)).status
  |> should.equal(200)
  // Publication does not turn the public challenge identifier into authority.
  let second_attacker = get(app, target, "")
  post(
    app,
    "/confirm",
    set_cookie(second_attacker),
    "csrf=" <> csrf(second_attacker) <> "&answer=wrong",
  ).status
  |> should.equal(403)
  get(app, "/session", set_cookie(second_attacker)).status |> should.equal(401)
  stop(fixture)
}

pub fn http_uncertain_verification_recovers_original_command_for_same_browser_test() {
  let count = new_counter()
  let fixture =
    start_with_store(fn(backing) {
      store.Store(..backing, verify: fn(command) {
        let reply = backing.verify(command)
        case increment(count) == 1 {
          True -> Error(store.Unknown)
          False -> reply
        }
      })
    })
  let app = fixture.demo
  let #(browser, target) = link(app)
  get(app, target, browser).status |> should.equal(303)
  let token = csrf(get(app, "/confirm", browser))
  post(app, "/confirm", browser, "csrf=" <> token).status |> should.equal(503)
  post(app, "/confirm", "browser=unrelated", "csrf=" <> token).status
  |> should.equal(403)
  let recovered = post(app, "/confirm", browser, "csrf=" <> token)
  recovered.status |> should.equal(200)
  get(app, "/session", set_cookie(recovered)).status |> should.equal(200)
  stop(fixture)
}

pub type Counter

@external(erlang, "correio_demo_test_ffi", "new_counter")
fn new_counter() -> Counter

@external(erlang, "correio_demo_test_ffi", "increment")
fn increment(counter: Counter) -> Int

pub fn stop_completes_during_partial_http_request_test() {
  let fixture = start()
  let port = demo.port(fixture.demo)
  let socket = partial_request(port)
  demo.stop(fixture.demo) |> should.equal(Ok(Nil))
  socket_closed(socket) |> should.be_true
  port_closed(port) |> should.be_true
  stop_pool(fixture.pool)
}

pub fn owner_exit_closes_http_listener_test() {
  let subject = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(memory) = memory.start(10)
      let assert Ok(service) =
        auth.new(memory.store(memory), "owner-test", "login", key)
      let assert Ok(app) = demo.start(service)
      process.send(subject, demo.port(app))
      process.receive_forever(process.new_subject())
    })
  let assert Ok(port) = process.receive(subject, 1000)
  process.kill(owner)
  await_closed_port(port, 100) |> should.be_true
}

fn await_closed_port(port: Int, remaining: Int) -> Bool {
  case port_closed(port), remaining {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      await_closed_port(port, remaining - 1)
    }
  }
}

pub type Socket

@external(erlang, "correio_demo_test_ffi", "partial_request")
fn partial_request(port: Int) -> Socket

@external(erlang, "correio_demo_test_ffi", "socket_closed")
fn socket_closed(socket: Socket) -> Bool

@external(erlang, "correio_demo_test_ffi", "port_closed")
fn port_closed(port: Int) -> Bool

pub fn run_real_browser() {
  let fixture = start_configured(fn(store) { store }, True)
  let app = fixture.demo
  browser_run(
    demo.origin(app),
    fn() {
      let link = last_mail(app)
      let assert Ok(from) = address.parse("mailbox@example.com")
      let assert Ok(to) = address.parse("alice@example.com")
      let html =
        "<h2>Sign in safely</h2><p>Inspect the source and copy the link.</p><script>parent.mailboxPwned=true;fetch('/mailbox-trap')</script><meta http-equiv=refresh content=\"0;url="
        <> link
        <> "\"><img src='/mailbox-trap'><iframe src='"
        <> link
        <> "'></iframe><form action='"
        <> link
        <> "'><input autofocus onfocus=parent.mailboxPwned=true></form><a href='"
        <> link
        <> "'>Sign in</a>"
      let assert Ok(mail) =
        message.new(
          from,
          to,
          "Mailbox safety fixture",
          message.Alternative(link, html),
        )
      let assert delivery.Accepted(_) =
        capture.send(demo.mail_capture(app), mail)
      link
    },
    fn() {
      let id = pending_id(last_mail(app))
      let assert Ok(rows) =
        pog.query("select status from ecarta_challenges where id=$1")
        |> pog.parameter(pog.text(id))
        |> pog.returning(decode.at([0], decode.string))
        |> pog.execute(fixture.db)
      rows.rows == ["active"]
    },
  )
  |> should.equal(Ok(Nil))
  stop(fixture)
}

@external(erlang, "correio_demo_test_ffi", "browser_run")
fn browser_run(
  origin: String,
  link: fn() -> String,
  preview: fn() -> Bool,
) -> Result(Nil, Nil)

pub fn http_wrong_code_unknown_receipt_does_not_pin_future_answers_test() {
  let count = new_counter()
  let fixture =
    start_with_store(fn(backing) {
      store.Store(..backing, verify: fn(command) {
        let reply = backing.verify(command)
        case increment(count) == 1 {
          True -> Error(store.Unknown)
          False -> reply
        }
      })
    })
  let app = fixture.demo
  post(app, "/issue", "", "email=alice@example.com&mode=code").status
  |> should.equal(202)
  let assert [_, code_line, url] = string.split(last_mail(app), "\n")
  let answer = string.replace(code_line, "Code: ", "")
  let page = get(app, string.replace(url, demo.origin(app), ""), "")
  let cookie = set_cookie(page)
  let csrf = "csrf=" <> csrf(page)
  post(app, "/confirm", cookie, csrf <> "&answer=wrong").status
  |> should.equal(503)
  // The first retry resolves the old command and reports its original refusal.
  post(app, "/confirm", cookie, csrf <> "&answer=" <> answer).status
  |> should.equal(403)
  // A later intentional submission creates a fresh command and can succeed.
  post(app, "/confirm", cookie, csrf <> "&answer=" <> answer).status
  |> should.equal(200)
  stop(fixture)
}

pub fn optional_mailbox_and_flow_helper_use_the_same_capture_test() {
  let normal = start()
  get(normal.demo, "/dev/mailbox", "").status |> should.equal(404)
  stop(normal)
  let fixture = start_configured(fn(store) { store }, True)
  let app = fixture.demo
  let assert Ok(reader) = address.parse("alice@EXAMPLE.COM")
  let assert Ok(checkpoint) = capture.checkpoint(demo.mail_capture(app))
  post(app, "/issue", "", "email=alice@example.com").status |> should.equal(202)
  let assert Ok(mail) =
    testing.await(checkpoint, matching: testing.to(reader), timeout_ms: 100)
  message.view(mail).subject |> string.contains("Sign") |> should.be_true
  let inbox = get(app, "/dev/mailbox", "")
  inbox.status |> should.equal(200)
  inbox.body |> string.contains("/dev/mailbox/1") |> should.be_true
  let detail = get(app, "/dev/mailbox/1", "")
  detail.status |> should.equal(200)
  detail.body |> string.contains("alice@example.com") |> should.be_true
  post(app, "/dev/mailbox/1", "", "").status |> should.equal(405)
  let target = last_mail(app)
  let assert [_, answer] = string.split(target, "&answer=")
  // Inspecting both UI pages did not consume the challenge.
  let assert Ok(_) =
    auth.verify(
      fixture.service,
      pending_id(target),
      "alice@example.com",
      answer,
    )
  stop(fixture)
}

pub fn custom_mailbox_mount_and_capture_replacement_are_application_owned_test() {
  let assert Ok(outbox) = capture.start(1)
  let assert Ok(ui) = correio_mailbox.new(outbox, at: "/tools/mail")
  let assert Ok(from) = address.parse("sender@example.com")
  let assert Ok(to) = address.parse("reader@example.com")
  let assert Ok(mail) =
    message.new(from, to, "Custom mount", message.Text("local mail"))
  let assert delivery.Accepted(_) = capture.send(outbox, mail)
  let request = http_request.new() |> http_request.set_path("/tools/mail/1")
  correio_mailbox.handle(ui, request).status |> should.equal(200)
  capture.stop(outbox) |> should.equal(Ok(Nil))
  correio_mailbox.handle(ui, request).status |> should.equal(503)
  // The application replaces failed capture and handler together.
  let assert Ok(replacement) = capture.start(1)
  let assert Ok(replacement_ui) =
    correio_mailbox.new(replacement, at: "/tools/mail")
  let assert delivery.Accepted(_) = capture.send(replacement, mail)
  correio_mailbox.handle(replacement_ui, request).status |> should.equal(200)
  capture.stop(replacement) |> should.equal(Ok(Nil))
}
