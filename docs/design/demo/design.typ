#import "../.render/designlib.typ": *
#let title = [Browser demo]
#let accent = "teal"
#let body = [
  #section(title: "Foundation", lead: "The browser demo is a local executable example of an application that composes Correio delivery and verification without transferring application authority.", body: [
    #goal(title: "Demonstrate email login with truthful recovery")[Real HTTP requests exercise issue, landing, confirmation, and session publication with native account values, explicit sessions, and recovery from uncertain effects.]
    #no-goal(title: "Serve production traffic")[The single-exchange HTTP listener, in-process rate limits, and ephemeral sessions do not establish scalable serving, a distributed limiter, or durable session storage.]
    #invariant(title: "Opening a link never consumes a challenge", enforcement: "mechanism")[The landing request records the answer in the initiating browser's pending state and redirects. Only an intentional confirmation POST calls verification.]
    #invariant(title: "Evidence methods stay distinct", enforcement: "mechanism")[Correio verification evidence and a Hellhound OIDC identity map to different variants of the application's principal. Correio has no Hellhound runtime dependency.]
    #principle(title: "The application owns browser policy")[Origin, cookies, framing, referrer policy, admission limits, and sessions belong to the application. The library never infers them from an email address.]
  ])

  #pending-ledger(
    pending-entry(
      title: "Browser flow rules beyond the bounds are unchecked",
      kind: "verify",
      since: "2026-10-17",
    )[The admission limits, state bounds, and cookie attributes were compared with the code. The landing, confirmation, cross-device, and recovery rules carried over from retired guides remain unchecked against the code and the browser check.],
  )

  #section(title: "System at a glance", lead: "The demo composes delivery and passwordless verification into one browser journey.", visual: diagram(
    altitude: "L3", viewpoint: "runtime", title: "Browser demo composition",
    nodes: (
      (id: "browser", label: "Browser", kind: "external-system"),
      (id: "app", label: "Demo application", sub: "accounts, cookies, sessions", kind: "component", tint: "teal"),
      (id: "mail", label: "Delivery", kind: "bounded-context", tint: "blue"),
      (id: "auth", label: "Passwordless", kind: "bounded-context", tint: "violet"),
      (id: "hellhound", label: "Hellhound identity", kind: "external-system"),
    ),
    edges: (
      (from: "browser", to: "app", relation: "call", label: "issue, land, confirm"),
      (from: "app", to: "mail", relation: "call", label: "deliver link or code"),
      (from: "app", to: "auth", relation: "call", label: "issue and verify"),
      (from: "hellhound", to: "app", relation: "dataflow", label: "OIDC identity"),
    ), caption: [The application maps both authentication methods into its own principal type.]), body: [
    #points([A login journey issues a challenge, submits its message, confirms an intentional user action, consumes the challenge, and publishes an application session. A failure between these boundaries does not roll back an already accepted email or consumed challenge.], [The demo uses a compiled Hellhound identity projection recipe. The application, not Correio, constructs its #term("term-principal") values.])
  ])

  #section(title: "Browser flow", lead: "The initiating browser requests a challenge, lands on a clean confirmation page, and confirms with a form POST.", body: [
    #answers(title: "Separate consumer",
      responsibility: [Demonstrate email login with native account values, explicit sessions, and truthful recovery.],
      interface: [HTTP issue, landing, confirmation, and session routes; typed mail and challenge configuration; a compiled Hellhound identity projection recipe.],
      interactions: [Local SMTP and HTTP peers capture real exchanges; a disposable PostgreSQL persists challenges; the application owns account lookup and session storage.],
      invariants: [Landing GET does not consume a challenge. Confirmation requires POST and application origin protection. Unknown accounts receive the same public issue response. Correio evidence and Hellhound OIDC identity remain distinct authentication methods.],
      failure: [Provider refusal, expiry, wrong answer, storage outage, and failed session publication have explicit application responses. No error page exposes an answer or credential.],
    )
    #points([The issue route requires the configured origin and returns the same status, body, and cookie shape for known and unknown accounts. The application matches destinations exactly and rechecks the enabled account and its current destination at confirmation.], [The default flow binds the challenge to a random #term("term-initiating-browser-binding"). The link uses the configured origin and never derives callback destinations from the Host header or return-to values.], [The landing route records the answer only in that browser's pending server state and redirects to a confirmation page that contains no answer. The confirmation POST requires the browser cookie, a matching Origin, and a random CSRF token before calling verification (#term("term-intentional-confirmation")). #adr(7)], [Responses prevent caching. The secret-bearing landing redirect uses no-referrer and removes secrets from the address bar before any third-party resource renders. Clean pages use same-origin referrer policy so form posts retain their Origin. A restrictive content security policy excludes third-party content and framing.])
    #points([An explicit mode selects #term("term-cross-device-entry"). The receiving browser gets its own cookie and CSRF token, and the user supplies the delivered code on POST. It cannot inherit confirmed evidence or a recovery handle from another browser.], [An uncertain verification acknowledgement retains its original command in the initiating browser's pending state. A later confirmation recovers that command before publishing a session. A definitive wrong-answer receipt permits a later fresh answer and never spends the old attempt twice.], [#term("term-session-publication") rotates the session identifier and uses the challenge's #term("term-verification-identity") for idempotent retries. A publication failure retains confirmed evidence for the same browser, and the retry never verifies the consumed answer again. Session expiry uses the original authentication time.])
    #points([The initiating-browser cookie uses SameSite Lax so a top-level navigation from webmail carries the binding. Session cookies use SameSite Strict. Both cookies are HttpOnly.], [The loopback HTTP fixture omits the Secure attribute because it serves plaintext. A deployed application serves HTTPS and sets Secure.])
    #behavior(title: "Link inspection does not authenticate", area: "Browser confirmation", level: "interface")[#given[A valid login link has been delivered.] #when[A browser or mail scanner opens it.] #then[The application presents an intentional confirmation action.] #then[The challenge remains unconsumed until confirmation.]]
    #behavior(title: "Unknown accounts are indistinguishable", area: "Account privacy", level: "interface")[#given[A visitor requests a sign-in link.] #when[The address belongs to no enabled account.] #then[The visitor receives the same response as for a known account.] #then[No message is sent.]]
    #behavior(title: "Another browser cannot reuse confirmed evidence", area: "Cross-browser safety", level: "interface")[#given[One browser holds confirmed verification evidence.] #when[A different browser submits the same link or code.] #then[The second browser must prove the answer through its own command.] #then[It inherits no evidence and no recovery handle.]]
  ])

  #section(title: "Bounds and ownership", lead: "The demo bounds its local state and states what it does not demonstrate.", body: [
    #points([The application admits at most three issue requests per destination and twenty per configured origin each minute. It retains at most one hundred pending browser flows and one thousand rate-limit keys, and prunes expired state on request.], [Per-destination and per-origin admission limits belong to the application or a shared edge authority. The library's per-challenge attempt budget is necessary and does not substitute for them.], [The HTTP fixture accepts one exchange at a time and bounds its backlog, request line, headers, body size, and socket waits. Browser and session state is local and ephemeral; production applications supply shared account, session, admission, and durable publication authorities.], [The caller owns the named PostgreSQL pool. Starting the application starts its capture and HTTP runtimes, and stopping it waits for both shutdown boundaries. A memory-backed development entry point needs no database or credentials and can add the read-only mailbox route explicitly.])
  ])
]
