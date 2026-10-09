//// Local-only application consumer. The caller owns the PostgreSQL pool.

import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/passwordless as auth
import correio_mailbox
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import identity.{type AccountId, AccountId}

pub type Request {
  Request(
    method: String,
    target: String,
    headers: List(#(String, String)),
    body: String,
  )
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: String)
}

pub opaque type Demo {
  Demo(runtime: Runtime(State), capture: capture.Capture, port: Int)
}

pub type Runtime(state)

pub type StartError {
  CaptureFailed
  ListenerFailed
}

pub type StopError {
  RuntimeStopFailed
  CaptureStopFailed
}

type Account {
  Account(id: AccountId, email: String, enabled: Bool)
}

type Mode {
  Link
  Code
}

type Verification {
  AwaitingAnswer(Option(String))
  VerificationUnknown(auth.VerifyRecovery(AccountId))
  Confirmed(auth.Verified(AccountId))
}

type Pending {
  Pending(
    account: AccountId,
    id: String,
    destination: String,
    browser: String,
    csrf: String,
    mode: Mode,
    verification: Verification,
    expires_at: Int,
  )
}

type Session {
  Session(principal: identity.Principal, expires_at: Int)
}

type Window {
  Window(start: Int, count: Int)
}

type State {
  State(
    service: auth.Service(AccountId),
    capture: capture.Capture,
    mailbox: Option(correio_mailbox.Mailbox),
    origin: String,
    account: Account,
    pending: Dict(String, Pending),
    sessions: Dict(String, Session),
    publications: Dict(String, String),
    admission: Dict(String, Window),
    fail_publication: Bool,
  )
}

pub fn start(service: auth.Service(AccountId)) -> Result(Demo, StartError) {
  start_configured(service, False)
}

/// Explicit local-development option: expose captured messages at /dev/mailbox.
pub fn start_with_mailbox(
  service: auth.Service(AccountId),
) -> Result(Demo, StartError) {
  start_configured(service, True)
}

fn start_configured(
  service: auth.Service(AccountId),
  expose_mailbox: Bool,
) -> Result(Demo, StartError) {
  use mail <- result.try(
    capture.start(100) |> result.map_error(fn(_) { CaptureFailed }),
  )
  let mailbox = case expose_mailbox {
    True -> {
      let assert Ok(mailbox) = correio_mailbox.new(mail, at: "/dev/mailbox")
      Some(mailbox)
    }
    False -> None
  }
  case
    start_runtime(
      fn(port) {
        State(
          service,
          mail,
          mailbox,
          "http://127.0.0.1:" <> int.to_string(port),
          Account(AccountId(7), "alice@example.com", True),
          dict.new(),
          dict.new(),
          dict.new(),
          dict.new(),
          False,
        )
      },
      handle,
    )
  {
    Ok(#(runtime, port)) -> Ok(Demo(runtime, mail, port))
    Error(_) -> {
      let _ = capture.stop(mail)
      Error(ListenerFailed)
    }
  }
}

pub fn port(demo: Demo) -> Int {
  demo.port
}

pub fn origin(demo: Demo) -> String {
  "http://127.0.0.1:" <> int.to_string(demo.port)
}

/// The same explicitly owned capture injected into the application's sender.
pub fn mail_capture(demo: Demo) -> capture.Capture {
  demo.capture
}

pub fn captured_messages(
  demo: Demo,
) -> Result(List(message.Message), capture.Error) {
  capture.messages(demo.capture)
}

pub fn fail_next_publication(demo: Demo) -> Result(Nil, Nil) {
  runtime_call(demo.runtime, fn(state) {
    #(State(..state, fail_publication: True), Nil)
  })
}

pub fn set_account(
  demo: Demo,
  email: String,
  enabled: Bool,
) -> Result(Nil, Nil) {
  runtime_call(demo.runtime, fn(state) {
    #(State(..state, account: Account(..state.account, email:, enabled:)), Nil)
  })
}

pub fn stop(demo: Demo) -> Result(Nil, StopError) {
  use _ <- result.try(
    stop_runtime(demo.runtime) |> result.map_error(fn(_) { RuntimeStopFailed }),
  )
  capture.stop(demo.capture) |> result.map_error(fn(_) { CaptureStopFailed })
}

fn handle(state: State, request: Request) -> #(State, Response) {
  let path =
    string.split(request.target, "?") |> list.first |> result.unwrap("")
  case state.mailbox {
    Some(mailbox) if path == "/dev/mailbox" -> #(
      state,
      mailbox_response(mailbox, request, path),
    )
    Some(mailbox) ->
      case string.starts_with(path, "/dev/mailbox/") {
        True -> #(state, mailbox_response(mailbox, request, path))
        False -> handle_application(state, request)
      }
    None -> handle_application(state, request)
  }
}

fn mailbox_response(
  mailbox: correio_mailbox.Mailbox,
  request: Request,
  path: String,
) -> Response {
  let req =
    http_request.new()
    |> http_request.set_method(
      http.parse_method(request.method) |> result.unwrap(http.Options),
    )
    |> http_request.set_path(path)
  let response = correio_mailbox.handle(mailbox, req)
  Response(response.status, response.headers, response.body)
}

fn handle_application(state: State, request: Request) -> #(State, Response) {
  let now = milliseconds()
  let state = prune(state, now)
  let path =
    string.split(request.target, "?") |> list.first |> result.unwrap("")
  case request.method, path {
    "GET", "/" -> #(
      state,
      response(
        200,
        "<form method=post action=/issue><input name=email><button>Email sign-in link</button></form>",
      ),
    )
    "POST", "/issue" -> issue(state, request, now)
    "GET", "/login" -> landing(state, request)
    "GET", "/confirm" -> confirm_page(state, request)
    "GET", "/code" -> code_page(state, request)
    "POST", "/confirm" -> confirm(state, request, now)
    "GET", "/session" -> session(state, request, now)
    _, _ -> #(state, response(404, "Not found"))
  }
}

fn issue(state: State, request: Request, now: Int) -> #(State, Response) {
  case header(request, "origin") == state.origin {
    False -> #(state, response(403, "Request refused"))
    True -> {
      let fields = parameters(request.body)
      let destination = field(fields, "email")
      let mode = case field(fields, "mode") {
        "code" -> Code
        _ -> Link
      }
      let browser = random_token()
      let #(state, origin_allowed) =
        admit(state, "origin:" <> state.origin, 20, now)
      let #(state, destination_allowed) =
        admit(state, "destination:" <> destination, 3, now)
      let neutral =
        Response(
          202,
          [#("set-cookie", cookie("browser", browser)), ..security_headers()],
          "If this account exists, an email is ready.",
        )
      case
        origin_allowed
        && destination_allowed
        && dict.size(state.pending) < 100
        && string.byte_size(destination) <= 320
        && state.account.enabled
        && state.account.email == destination
      {
        False -> #(state, neutral)
        True ->
          case
            auth.issue(state.service, state.account.id, destination, case mode {
              Link -> auth.MagicLink
              Code -> auth.EmailCode(6)
            })
          {
            Error(_) -> #(state, neutral)
            Ok(challenge) -> {
              let id = auth.challenge_id(challenge)
              let pending =
                Pending(
                  state.account.id,
                  id,
                  destination,
                  browser,
                  random_token(),
                  mode,
                  AwaitingAnswer(None),
                  auth.challenge_expires_at(challenge),
                )
              let body = case mode {
                Link ->
                  state.origin
                  <> "/login?id="
                  <> id
                  <> "&answer="
                  <> auth.challenge_answer(challenge)
                Code ->
                  "Challenge: "
                  <> id
                  <> "\nCode: "
                  <> auth.challenge_answer(challenge)
                  <> "\n"
                  <> state.origin
                  <> "/code?id="
                  <> id
              }
              let assert Ok(from) = address.parse("login@example.com")
              let assert Ok(to) = address.parse(destination)
              let assert Ok(mail) =
                message.new(from, to, "Sign in", message.Text(body))
              case capture.send(state.capture, mail) {
                delivery.Accepted(_) -> #(
                  State(
                    ..state,
                    pending: dict.insert(state.pending, browser, pending),
                  ),
                  neutral,
                )
                _ -> #(state, neutral)
              }
            }
          }
      }
    }
  }
}

fn landing(state: State, request: Request) -> #(State, Response) {
  let browser = cookie_value(request, "browser")
  let fields = target_parameters(request.target)
  case dict.get(state.pending, browser) {
    Ok(pending) if pending.mode == Link ->
      case
        pending.id == field(fields, "id")
        && string.byte_size(field(fields, "answer")) <= 128
      {
        True -> {
          let pending =
            Pending(..pending, verification: case pending.verification {
              AwaitingAnswer(_) -> AwaitingAnswer(Some(field(fields, "answer")))
              phase -> phase
            })
          #(
            State(
              ..state,
              pending: dict.insert(state.pending, browser, pending),
            ),
            Response(
              303,
              [#("location", "/confirm"), ..secret_headers()],
              "Continue to confirmation",
            ),
          )
        }
        False -> #(state, response(403, "Request refused"))
      }
    _ -> #(state, response(403, "Request refused"))
  }
}

fn confirm_page(state: State, request: Request) -> #(State, Response) {
  case dict.get(state.pending, cookie_value(request, "browser")) {
    Ok(pending) -> #(
      state,
      response(
        200,
        "<form method=post action=/confirm><input type=hidden name=csrf value="
          <> pending.csrf
          <> "><button>Sign in</button></form>",
      ),
    )
    Error(_) -> #(state, response(403, "Request refused"))
  }
}

fn code_page(state: State, request: Request) -> #(State, Response) {
  let id = target_parameters(request.target) |> field("id")
  let found =
    state.pending
    |> dict.values
    |> list.find(fn(pending) { pending.id == id && pending.mode == Code })
  case found, dict.size(state.pending) < 100 {
    Ok(pending), True -> {
      let browser = random_token()
      let pending =
        Pending(
          ..pending,
          browser:,
          csrf: random_token(),
          verification: AwaitingAnswer(None),
        )
      let state =
        State(..state, pending: dict.insert(state.pending, browser, pending))
      let #(state, page) =
        confirm_page(
          state,
          Request("GET", "/confirm", [#("cookie", "browser=" <> browser)], ""),
        )
      #(
        state,
        Response(
          ..page,
          headers: [#("set-cookie", cookie("browser", browser)), ..page.headers],
          body: "<form method=post action=/confirm><input type=hidden name=csrf value="
            <> pending.csrf
            <> "><input name=answer><button>Sign in with code</button></form>",
        ),
      )
    }
    _, _ -> #(state, response(403, "Request refused"))
  }
}

fn confirm(state: State, request: Request, now: Int) -> #(State, Response) {
  let browser = cookie_value(request, "browser")
  let fields = parameters(request.body)
  case dict.get(state.pending, browser) {
    Ok(pending) ->
      case
        header(request, "origin") == state.origin
        && field(fields, "csrf") == pending.csrf
        && pending.account == state.account.id
        && state.account.enabled
        && pending.destination == state.account.email
      {
        False -> #(state, response(403, "Request refused"))
        True ->
          case pending.verification {
            Confirmed(evidence) ->
              publish(state, pending, evidence, request, now)
            VerificationUnknown(recovery) ->
              verification_result(
                state,
                pending,
                request,
                now,
                auth.recover_verify(recovery),
              )
            AwaitingAnswer(link_answer) -> {
              let answer = case pending.mode {
                Code -> field(fields, "answer")
                Link -> option.unwrap(link_answer, "")
              }
              verification_result(
                state,
                pending,
                request,
                now,
                auth.verify(
                  state.service,
                  pending.id,
                  state.account.email,
                  answer,
                ),
              )
            }
          }
      }
    Error(_) -> #(state, response(403, "Request refused"))
  }
}

fn verification_result(
  state: State,
  pending: Pending,
  request: Request,
  now: Int,
  outcome: Result(auth.Verified(AccountId), auth.VerifyError(AccountId)),
) -> #(State, Response) {
  case outcome {
    Ok(evidence) -> publish(state, pending, evidence, request, now)
    Error(auth.Refused(_)) -> {
      let pending = Pending(..pending, verification: AwaitingAnswer(None))
      #(
        State(
          ..state,
          pending: dict.insert(state.pending, pending.browser, pending),
        ),
        response(403, "Challenge refused"),
      )
    }
    Error(auth.VerifyFailed(_)) -> #(
      state,
      response(503, "Verification unavailable; retry confirmation"),
    )
    Error(auth.VerifyUnknown(recovery)) -> {
      let pending =
        Pending(..pending, verification: VerificationUnknown(recovery))
      #(
        State(
          ..state,
          pending: dict.insert(state.pending, pending.browser, pending),
        ),
        response(503, "Verification pending; retry confirmation"),
      )
    }
  }
}

fn publish(
  state: State,
  pending: Pending,
  evidence: auth.Verified(AccountId),
  request: Request,
  _now: Int,
) -> #(State, Response) {
  let pending = Pending(..pending, verification: Confirmed(evidence))
  let state =
    State(
      ..state,
      pending: dict.insert(state.pending, pending.browser, pending),
    )
  case state.fail_publication {
    True -> #(
      State(..state, fail_publication: False),
      response(503, "Session publication pending; retry confirmation"),
    )
    False -> {
      let publication = auth.verification_id(evidence)
      let session_id =
        dict.get(state.publications, publication)
        |> result.unwrap(random_token())
      let sessions =
        state.sessions
        |> dict.delete(cookie_value(request, "session"))
        |> dict.insert(
          session_id,
          Session(
            identity.from_email(evidence),
            auth.authenticated_at(evidence) + 600_000,
          ),
        )
      let state =
        State(
          ..state,
          sessions:,
          publications: dict.insert(state.publications, publication, session_id),
        )
      #(
        state,
        Response(
          200,
          [#("set-cookie", cookie("session", session_id)), ..security_headers()],
          "Signed in",
        ),
      )
    }
  }
}

fn session(state: State, request: Request, now: Int) -> #(State, Response) {
  case dict.get(state.sessions, cookie_value(request, "session")) {
    Ok(session) if session.expires_at > now -> #(
      state,
      response(200, "Authenticated native account"),
    )
    _ -> #(state, response(401, "No session"))
  }
}

fn admit(state: State, key: String, limit: Int, now: Int) -> #(State, Bool) {
  case dict.get(state.admission, key) {
    Ok(window) if window.start + 60_000 > now -> #(
      State(
        ..state,
        admission: dict.insert(
          state.admission,
          key,
          Window(..window, count: window.count + 1),
        ),
      ),
      window.count < limit,
    )
    _ ->
      case dict.size(state.admission) < 1000 {
        True -> #(
          State(
            ..state,
            admission: dict.insert(state.admission, key, Window(now, 1)),
          ),
          True,
        )
        False -> #(state, False)
      }
  }
}

fn prune(state: State, now: Int) -> State {
  let sessions =
    dict.filter(state.sessions, fn(_, value) { value.expires_at > now })
  State(
    ..state,
    pending: dict.filter(state.pending, fn(_, value) {
      value.expires_at + 60_000 > now
    }),
    sessions:,
    publications: dict.filter(state.publications, fn(_, session) {
      dict.has_key(sessions, session)
    }),
    admission: dict.filter(state.admission, fn(_, window) {
      window.start + 60_000 > now
    }),
  )
}

fn response(status: Int, body: String) -> Response {
  Response(status, security_headers(), body)
}

fn security_headers() -> List(#(String, String)) {
  [
    #("cache-control", "no-store"),
    #("referrer-policy", "same-origin"),
    #(
      "content-security-policy",
      "default-src 'none'; form-action 'self'; frame-ancestors 'none'",
    ),
    #("content-type", "text/html; charset=utf-8"),
  ]
}

fn cookie(name: String, value: String) -> String {
  let policy = case name {
    "browser" -> "Lax"
    _ -> "Strict"
  }
  name <> "=" <> value <> "; Path=/; HttpOnly; SameSite=" <> policy
}

fn header(request: Request, name: String) -> String {
  request.headers |> list.key_find(name) |> result.unwrap("")
}

fn cookie_value(request: Request, name: String) -> String {
  header(request, "cookie")
  |> string.split(";")
  |> list.find_map(fn(item) {
    case string.split(string.trim(item), "=") {
      [key, value] if key == name -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

fn parameters(value: String) -> List(#(String, String)) {
  uri.parse_query(value) |> result.unwrap([])
}

fn field(fields: List(#(String, String)), name: String) -> String {
  list.key_find(fields, name) |> result.unwrap("")
}

fn target_parameters(target: String) -> List(#(String, String)) {
  case string.split(target, "?") {
    [_, query] -> parameters(query)
    _ -> []
  }
}

@external(erlang, "correio_demo_ffi", "random_token")
fn random_token() -> String

@external(erlang, "correio_demo_ffi", "milliseconds")
fn milliseconds() -> Int

@external(erlang, "correio_demo_ffi", "start")
fn start_runtime(
  initial: fn(Int) -> state,
  handler: fn(state, Request) -> #(state, Response),
) -> Result(#(Runtime(state), Int), Nil)

@external(erlang, "correio_demo_ffi", "call")
fn runtime_call(
  runtime: Runtime(state),
  function: fn(state) -> #(state, a),
) -> Result(a, Nil)

@external(erlang, "correio_demo_ffi", "stop")
fn stop_runtime(runtime: Runtime(state)) -> Result(Nil, Nil)

fn secret_headers() -> List(#(String, String)) {
  security_headers() |> list.key_set("referrer-policy", "no-referrer")
}
