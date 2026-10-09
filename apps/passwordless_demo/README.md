# Passwordless browser consumer

## Scope

- This package is a local executable example, not a deployed authentication application.
- Real HTTP requests on an ephemeral loopback listener exercise Correio against disposable PostgreSQL.
- The application owns its native `AccountId`, account policy, admission limits, browser state, sessions, and session publication.
- `identity.gleam` maps Correio email evidence and Warden OIDC identity into distinct application principal variants. The example does not fabricate an OIDC identity.
- `readme_examples.gleam` compiles the root README examples. Tests execute its memory flow and never contact its illustrative SMTP hostname.

## Run

```sh
# From the Correio repository root.
nix develop -c scripts/with-postgres.sh sh -c 'cd apps/passwordless_demo && gleam test'
```

## Manual development flow

```sh
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```

- This entry point uses memory storage, explicitly enables the development mailbox, and prints both local URLs. It needs no PostgreSQL or provider credentials.
- Request a link for `alice@example.com`. Open the mailbox in another tab, copy the plain-text URL, and open it in the same browser. Confirm the form to publish a session.
- `mail_capture(app)` exposes the exact capture used by the sender. Tests take `capture.checkpoint` before triggering HTTP requests and use `testing.await` with a recipient predicate afterward.
- Stop with Ctrl-C. All local mail, challenges, and sessions disappear.

## Browser behavior

- `POST /issue` requires the configured origin and returns the same status, body, and cookie shape for known and unknown accounts.
- The local account is `alice@example.com`. The application uses exact destination matching and rechecks the enabled account and its current destination at confirmation.
- The default issue flow binds its challenge to a random initiating-browser cookie. Its link uses the configured origin regardless of the request's Host header.
- `GET /login` records the answer only in that browser's pending server state and redirects to `/confirm`. It does not verify or consume the challenge.
- `/confirm` contains no answer. Its POST requires the browser cookie, matching Origin, and random CSRF token before calling Correio.
- Responses prevent caching. The secret-bearing landing redirect uses no-referrer; clean pages use same-origin so browser form POSTs retain their Origin header. A restrictive content security policy excludes third-party content and framing.
- An uncertain verification acknowledgement retains its original command in the same browser. A later confirmation resolves that command before publishing a session. A definitive wrong-answer receipt permits a later fresh answer; it never spends the old attempt twice.
- Session publication rotates the session identifier and uses the challenge's stable verification identity for idempotent retries. A simulated publication failure retains confirmed evidence for the same browser; the retry does not verify the consumed answer again.
- `mode=code` explicitly selects cross-device entry. `/code` gives the receiving browser its own cookie and CSRF token; the user supplies the delivered code on POST.
- `start` keeps capture retrieval in-process. `start_with_mailbox` explicitly adds the read-only `/dev/mailbox` development route. Account mutation remains an in-process test API.

## Bounds and ownership

- The application admits at most three issue requests per destination and twenty per configured origin per minute. This local demonstration is not a distributed rate limiter.
- It retains at most one hundred pending browser flows and one thousand rate-limit keys. Expired state is pruned on request. Session publication uses the original authentication time for session expiry.
- The HTTP fixture accepts one exchange at a time. It bounds backlog, request line, headers, body size, and socket waits. It does not demonstrate scalable HTTP serving.
- The caller owns the named PostgreSQL pool. `start` owns capture and HTTP runtimes; `stop` waits for both shutdown boundaries.
- Cookies use HttpOnly. The initiating-browser cookie uses SameSite=Lax so top-level links from webmail retain the browser binding. Session cookies use SameSite=Strict. Origin and CSRF checks protect confirmation POSTs.
- Secure is omitted only because this loopback test server uses plaintext HTTP; a deployed application must serve HTTPS and set Secure.
- Browser and session state is intentionally local and ephemeral. Production applications supply their own shared account, session, admission, and durable publication authorities.

## Real browser evidence

```sh
nix develop -c scripts/browser-e2e
```

- The retained native, browser, and benchmark harness targets Linux. The library itself targets Erlang.
- The mandatory native gate also runs this command. Chromium and Node come from the pinned Nix development environment; a missing browser fails the check.
- Chromium submits the issue form, opens a link from a separate `localhost` webmail origin into the `127.0.0.1` application, follows the clean confirmation redirect, submits the rendered CSRF form, and checks the authenticated session and rotated cookie.
- A database assertion between preview and POST proves that browser navigation did not consume the challenge.
- The runner uses Node's built-in browser-debugging WebSocket client. It explicitly enables the mailbox, opens its inbox and message detail, and proves that hostile scripts, forms, images, frames, and refresh markup do not execute or request a sign-in URL. Full source remains inspectable. The original authentication navigation still uses a separate webmail origin.
- The Chromium check covers real cookie navigation policy. Separate HTTP tests exercise negative origin, CSRF, account, attempt-recovery, cross-browser evidence-copying, and runtime shutdown cases.
