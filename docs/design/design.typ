#import ".render/designlib.typ": *
#let title = [Correio]
#let accent = "slate"
#let index_only = true
#let body = [
  #section(title: "Foundation", lead: "Correio supplies email delivery and independent passwordless verification for Gleam applications on Erlang. This chapter holds only what spans contexts.", body: [
    #no-goal(title: "Own accounts or application sessions")[Registration, account linking, business permissions, browser cookies, account discovery responses, and session publication remain application responsibilities.]
    #no-goal(title: "Operate an inbound mailbox or identity provider")[IMAP, POP, inbound mail processing, OAuth authorization-server behavior, WebAuthn, and authenticator TOTP are outside this package's contract.]
    #invariant(title: "Ordinary diagnostics exclude secrets", enforcement: "mechanism")[Descriptions and observations exclude provider credentials, challenge answers, message bodies, arbitrary application subjects, and raw foreign errors. Explicit delivery and VM inspection are outside that boundary.]
    #invariant(title: "Delivery and verification share no authority", enforcement: "convention")[Verification never sends email and delivery never consumes a challenge. Neither context imports the other, and no shared transaction spans them.]
    #principle(title: "Keep ownership visible")[Constructors validate without starting processes. Runtime handles have explicit start and stop boundaries; injected pools and stores remain caller-owned.]
    #principle(title: "Preserve application-native values")[Typed subjects and provider extensions compose through public contracts without importing implementation modules.]
  ])

  #pending-ledger(
    pending-entry(
      title: "Hellhound consumption-time expiry boundary",
      kind: "ruling",
      since: "2026-10-09",
      adr: [#adr(1)],
    )[Hellhound's verified identity requires an ID token, and its design leaves a consumption-time expiry boundary unresolved. Whether email evidence should share that boundary is an open owner decision.],
  )

  #section(title: "System at a glance", lead: "Message delivery and challenge verification have independent lifetimes. The application composes them.", visual: diagram(
    altitude: "L2", viewpoint: "context-ownership", title: "Email and authentication contexts",
    nodes: (
      (id: "app", label: "Application", sub: "accounts and sessions", kind: "external-system"),
      (id: "demo", label: "Browser demo", kind: "bounded-context", tint: "teal"),
      (id: "mail", label: "Delivery", kind: "bounded-context", tint: "blue"),
      (id: "auth", label: "Passwordless", kind: "bounded-context", tint: "violet"),
      (id: "evidence", label: "Evidence", kind: "bounded-context", tint: "amber"),
      (id: "provider", label: "SMTP or HTTP provider", kind: "external-system"),
      (id: "store", label: "Challenge store", kind: "database"),
    ),
    edges: (
      (from: "app", to: "mail", relation: "call", label: "deliver"),
      (from: "app", to: "auth", relation: "call", label: "issue and verify"),
      (from: "demo", to: "mail", relation: "dependency", label: "composes"),
      (from: "demo", to: "auth", relation: "dependency", label: "composes"),
      (from: "mail", to: "provider", relation: "call", label: "submit"),
      (from: "auth", to: "store", relation: "call", label: "atomic transition"),
      (from: "auth", to: "app", relation: "dataflow", label: "verified subject"),
      (from: "evidence", to: "mail", relation: "dependency", label: "judges"),
      (from: "evidence", to: "auth", relation: "dependency", label: "judges"),
    ), caption: [No email delivery is triggered implicitly by verification. The application decides how to compose a challenge into a message and how to publish an authenticated session.]), body: [
    #components(
      component(name: "Delivery", mission: "Construct validated messages, submit them through a transport, and inspect captured mail in tests.", tint: "blue", answers: answers-data(
        responsibility: [Message values, MIME, SMTP, provider adapters, capture, and the development mailbox. See #ctx("delivery").],
        interface: [Public Gleam modules and optional Postmark and mailbox packages.],
        failure: [Accepted, not sent, rejected, and unknown outcomes stay distinct.],
      )),
      component(name: "Passwordless", mission: "Issue and verify challenges with one atomic consumption over an injected store.", tint: "violet", answers: answers-data(
        responsibility: [Challenge generation, verification, revocation, recovery, and the memory and PostgreSQL stores. See #ctx("passwordless").],
        interface: [A validated service, opaque values, and a typed store port.],
        failure: [Refusal and uncertain mutation stay distinct infrastructure outcomes.],
      )),
      component(name: "Browser demo", mission: "Compose both contexts into a local browser login journey.", tint: "teal", answers: answers-data(
        responsibility: [Origin, cookie, confirmation, and session policy for one example application. See #ctx("demo").],
        interface: [Local HTTP routes and a Hellhound identity projection recipe.],
        failure: [Provider refusal, expiry, storage outage, and publication failure have explicit responses.],
      )),
      component(name: "Evidence", mission: "Judge the other contexts with pinned oracles, fault tests, and benchmarks.", tint: "amber", answers: answers-data(
        responsibility: [Oracle comparisons, scripted peers, benchmarks, and CI. See #ctx("evidence").],
        interface: [Gate commands that report separately.],
        failure: [Each check states what it does not establish.],
      )),
    )
    #points([The message model is an immutable value model. The challenge is an identity-bearing aggregate with a bounded lifecycle. Their shared package does not create shared transaction authority.], [An OIDC identity and email verification evidence remain distinct inputs to an application's principal mapping. Correio never fabricates an issuer or OAuth token. #adr(1)], [No runtime dependency exists on Hellhound, Grind, Phoenix, Swoosh, or AshAuthentication. Oracles remain test-only.])
  ])
]
