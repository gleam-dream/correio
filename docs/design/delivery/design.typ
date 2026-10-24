#import "../.render/designlib.typ": *
#let title = [Delivery]
#let accent = "blue"
#let body = [
  #section(title: "Foundation", lead: "Delivery constructs one validated message, submits it through a selected transport, and reports what the transport observed.", body: [
    #goal(title: "Compose transactional email without provider coupling")[A caller constructs one validated message and selects a transport while retaining provider-specific capabilities and delivery outcomes.]
    #goal(title: "Inspect captured mail while testing a flow")[A test or developer reads the exact messages an application sent, without a provider, a global mailbox, or an automatic link activation.]
    #no-goal(title: "Schedule, store, or reconcile deliveries")[Delivery scheduling, durable outboxes, bounce processing, provider reconciliation, and inbound mail remain application integrations.]
    #invariant(title: "Possible transmission cannot become proven non-delivery", enforcement: "mechanism")[An uncertain transport outcome remains uncertain. Neither an adapter nor the library retries after possible transmission.]
    #invariant(title: "Admission precedes submission", enforcement: "mechanism")[A message that violates a structural, capability, or size requirement is refused before any provider request occurs.]
    #principle(title: "Report what was observed, never inbox delivery")[Every outcome states what the library observed. No outcome claims that a message reached an inbox.]
  ])

  #pending-ledger(
    pending-entry(
      title: "Qualify the Postmark adapter against a live account",
      kind: "ruling",
      since: "2026-10-17",
    )[Local scripted peers exercise the adapter. Whether to run an owner-credentialed live acceptance check is an open owner decision.],
    pending-entry(
      title: "Behavior rules beyond numeric bounds are unchecked",
      kind: "verify",
      since: "2026-10-17",
    )[The message, Postmark, mailbox, and capture bounds were compared with the code. The address and MIME rules, the SMTP and Postmark exchange behavior, and the mailbox preview rules carried over from retired guides remain unchecked against the code.],
  )

  #section(title: "System at a glance", lead: "A message flows from the application through one sender to a provider. Capture replaces the provider in tests.", visual: diagram(
    altitude: "L3", viewpoint: "runtime", title: "Delivery components",
    nodes: (
      (id: "app", label: "Application", sub: "templates and policy", kind: "external-system"),
      (id: "msg", label: "Message model", sub: "address, message, mime", kind: "component", tint: "blue"),
      (id: "smtp", label: "SMTP sender", kind: "component", tint: "blue"),
      (id: "postmark", label: "Postmark adapter", kind: "component", tint: "blue"),
      (id: "capture", label: "Capture", kind: "component", tint: "blue"),
      (id: "mailbox", label: "Development mailbox", kind: "component", tint: "blue"),
      (id: "provider", label: "SMTP or HTTP provider", kind: "external-system"),
    ),
    edges: (
      (from: "app", to: "msg", relation: "call", label: "construct"),
      (from: "app", to: "smtp", relation: "call", label: "send"),
      (from: "app", to: "postmark", relation: "call", label: "send"),
      (from: "app", to: "capture", relation: "call", label: "send in tests"),
      (from: "smtp", to: "provider", relation: "call", label: "submit"),
      (from: "postmark", to: "provider", relation: "call", label: "submit"),
      (from: "mailbox", to: "capture", relation: "call", label: "read"),
    ), caption: [Each sender is a function from a message to an outcome. The mailbox only reads a capture.]), body: [
    #md-table(3, (
      [Package or module], [Owned contract], [Effect owner],
      [correio/address, message, mime], [Immutable construction, admission, and serialization], [No network or database effects],
      [correio/smtp], [Typed SMTP sender and delivery outcome], [One bounded SMTP exchange per submission],
      [correio/capture and testing], [Recorded messages, checkpoints, and flow helpers], [Explicitly started capture runtime],
      [adapters/correio_postmark], [Postmark request and response semantics], [Caller-owned HTTP Gun client],
      [adapters/correio_mailbox], [Read-only development inspection], [Caller-owned capture and HTTP server],
    ))
  ])

  #section(title: "Message model", lead: "A validated message describes content and recipients. It performs no I/O.", body: [
    #answers(title: "Immutable email",
      responsibility: [Construct a #term("term-message") and its #term("term-envelope") without performing I/O.],
      interface: [Validated address and header constructors; a small message constructor; composable text, HTML, recipient, reply-to, header, and attachment operations.],
      interactions: [Serializers consume the same message through public projections. Applications own templates and localization.],
      invariants: [At least one recipient and one body alternative exist at delivery admission. Sender and address fields reject line breaks and control characters. Reserved structural headers cannot be overridden through arbitrary headers. Blind recipients are present in the envelope and absent from MIME headers.],
      failure: [Invalid addresses, headers, missing content, unsupported adapter capability, and size limits are typed refusals before network submission.],
    )
    #points([Addresses support ASCII dot-atom local parts and domain names. Local-part case is preserved and domain case is normalized. Unicode display names are supported through MIME encoding.], [Quoted local parts, address literals, and SMTPUTF8 mailboxes are refused. An adapter and encoding contract would have to support them first.], [Plain text and HTML can coexist as multipart alternatives. Attachments carry bytes, content type, filename, and attachment or inline disposition; inline content has a content identifier. The envelope sender may differ from the visible From address.], [MIME supports text, HTML, alternatives, inline resources, and binary attachments. Attachment media types under message or multipart are refused because they require additional encoding semantics.], [MIME uses CRLF, encoded Unicode headers, correctly escaped display names, stable multipart nesting, and a transfer encoding suitable for arbitrary attachment bytes. Generated date, message identifier, and multipart boundaries are independently normalized for comparisons.], [Custom header values preserve ASCII syntax, including structured unsubscribe headers. Non-ASCII custom values and physical header lines over 998 bytes are refused. Custom headers cannot override envelope, structural, authentication, or MIME headers; subjects and display names retain Unicode support.])
    #md-table(3, (
      [Value object], [Parts and refinement], [Relationship],
      [Address], [ASCII dot-atom mailbox, normalized domain, optional Unicode display name], [A message has one sender and one or more recipients],
      [Body], [Text, HTML, or both nonempty alternatives], [A message has one body value],
      [Attachment], [Filename, media type, bytes, and file or inline disposition], [A message has zero or more attachments; inline disposition has one content identifier],
      [Envelope], [Sender and unique mailbox recipients, including blind recipients], [Display names do not change recipient identity],
    ))
    #subsection(title: "Delivery entities")[
      #entity(title: "Message", description: [One immutable email value: sender, recipients by role, subject, body, headers, and attachments. It derives one envelope and performs no I/O.], kind: "aggregate", owner: "Message model", lifecycle: "immutable", domain: "Delivery", tint: "blue")[
        #attribute(name: "Participants", type: "Addresses by role", provenance: "authored")[the sender, the To, Cc, and Bcc recipients, the optional reply-to address, and the envelope sender the application states]
        #attribute(name: "Content", type: "Subject and body alternatives", provenance: "authored")[the subject and the text, HTML, or alternative body the application states]
        #attribute(name: "Custom headers", type: "Name and value pairs", provenance: "authored")[ASCII header values that cannot override structural headers]
        #attribute(name: "Envelope", type: "Sender and unique mailbox recipients", provenance: "derived")[computed from the participants, and including the blind recipients that the serialized headers omit]
        #relates(cardinality: "1 : 0..n")[holds zero or more *Attachment* values]
        #relates(cardinality: "1 : 1")[derives one *Envelope*]
      ]
      #entity(title: "Delivery outcome", description: [The closed result of one submission, stating what the library observed about transmission.], kind: "event", owner: "Transport and evidence", lifecycle: "immutable", domain: "Delivery", tint: "blue")[
        #attribute(name: "Variant", type: "Delivery outcome kind", provenance: "observed")[accepted, not sent, rejected, or unknown, decided by the provider response or the transport fault]
        #attribute(name: "Receipt", type: "Optional provider identifier and accepted recipients", provenance: "observed")[present only when the provider accepted the submission]
        #attribute(name: "Reason", type: "Failure class or rejection class", provenance: "observed")[a failure class for a not-sent outcome, and temporary or permanent for a rejected outcome]
        #relates(cardinality: "n : 1")[reports on one submission of one *Message*]
      ]
      #entity(title: "Capture", description: [An explicitly started, bounded runtime that records complete messages for inspection while testing. It performs no network I/O.], kind: "entity", owner: "Development mailbox and flow tests", lifecycle: "stateful", domain: "Delivery", tint: "blue")[
        #attribute(name: "Capacity", type: "Count of retained messages from 1 to 10,000", provenance: "authored")[the bound the application sets when it starts the capture]
        #attribute(name: "Retained entries", type: "Entries with increasing identifiers", provenance: "observed")[appended as the application's capture sender runs, and never renumbered after a clear]
        #relates(cardinality: "1 : 0..n")[retains zero or more *Message* values as entries]
        #relates(cardinality: "1 : 0..n")[is read through *Checkpoint* values that each bind it]
      ]
    ]
    #points([Defaults admit 100 recipients, 50 custom headers, 8 KiB per header value, 1 MiB of combined body content, 10 MiB per attachment, and 25 MiB of submission preparation. Configuration can lower or explicitly raise these bounds.], [A conservative encoded-size estimate runs before serialization and the exact encoded size is checked afterward. A message can therefore be refused even when its exact wire size would fit.], [A provider capability that a message needs but an adapter lacks fails explicitly rather than silently dropping the field.])
    #behavior(title: "Blind recipients stay private", area: "Message construction", level: "boundary")[#given[A message includes blind recipients.] #when[The application prepares it for delivery.] #then[The delivery envelope includes those recipients.] #then[The serialized message excludes the blind-recipient header.]]
    #behavior(title: "Invalid content is refused before submission", area: "Message admission", level: "boundary")[#given[A message violates a structural or configured size requirement.] #when[The application requests delivery.] #then[Delivery returns a typed refusal.] #then[No provider request occurs.]]
  ])

  #section(title: "Transport and evidence", lead: "A transport submits one admitted message and returns observed evidence. A provider acceptance is not inbox delivery.", body: [
    #answers(title: "Delivery operation",
      responsibility: [Submit one admitted message and report its #term("term-delivery-outcome").],
      interface: [A #term("term-sender") accepting one message; SMTP, HTTP-provider, and capture implementations carry validated configuration and provider-specific options.],
      interactions: [The caller owns HTTP pools and scheduling. SMTP owns only its admitted exchange. Capture state has explicit ownership and bounded capacity.],
      invariants: [A provider acceptance receipt is not inbox delivery. Possible submission is not retried internally. #adr(8) Per-operation deadlines and input bounds limit retained work.],
      failure: [Accepted, not sent, rejected, and unknown outcomes are distinguishable, and a construction refusal is a not-sent outcome. Unsupported features fail before submission.],
    )
    #state-type(id: "delivery-outcome-kind", title: "Delivery outcome kind", variants: (
      (id: "accepted", description: [The provider accepted the submission.]),
      (id: "not-sent", description: [Submission did not occur.]),
      (id: "rejected", description: [The provider refused the submission.]),
      (id: "outcome-unknown", description: [Submission may have occurred.]),
    ))
    #points([SMTP requires certificate-chain and hostname verification with STARTTLS-required or implicit TLS configuration. Plaintext exists only behind an explicitly named loopback test constructor. Authentication cannot silently downgrade to unauthenticated delivery.], [SMTP response codes govern acceptance and rejection. Envelope recipients include To, Cc, and Bcc; any recipient refusal aborts before DATA, so no message content is partially submitted. A lost reply after DATA remains unknown.], [SMTP credentials attach to a TLS configuration. A deadline, trust roots, and size limits bound each exchange.], [HTTP provider calls use HTTPS, bounded response bodies, explicit destination policy, and caller-owned HTTP Gun lifetime. A provider-specific idempotency key is meaningful only under that provider's documented semantics. Generic message identifiers do not establish deduplication.], [Retrying an unknown outcome requires an explicit duplicate-delivery policy or destination-supported idempotency. Scheduling, durable outbox storage, bounce webhooks, and reconciliation are application integrations.], [A message description redacts content by default. Message projections intentionally expose content to the application.])
    #subsection(title: "Postmark adapter")[
      #points([The adapter submits through the fixed Postmark email endpoint with typed options for message stream, tag, metadata, and open and link tracking. The application owns the HTTP Gun client and its shutdown.], [Acceptance requires a provider error code of zero and a nonempty bounded message identifier. A successful HTTP status alone is insufficient. A lost acknowledgement, malformed successful response, or server error remains unknown.], [An exchange deadline ranges from 1 millisecond to 120 seconds. The collected response bound ranges from 1 byte to 1 MiB and defaults to 64 KiB. An observed documented rejection remains a rejection even when its body exceeds the bound.], [Adapter admission independently measures sender and subject in bytes. The encoded request must fit 10,000,000 bytes, and core message limits and the caller's request limits also apply.], [A distinct envelope sender fails before submission with an unsupported-capability refusal, because Postmark controls its return path.], [Production requests use HTTPS with an explicit host and TLS destination policy. A local test constructor selects a loopback URL, and the caller's client must also allow loopback destinations. Policies intersect with the caller's policies and never widen them.], [A redaction helper adds the Postmark server-token header to an HTTP Gun redaction policy. The default policy lacks that header, and recordings retain message bodies and addresses unless the application also redacts bodies. Ordinary adapter diagnostics contain no provider response, token, address, or message body.])
    ]
    #behavior(title: "Lost submission acknowledgement stays uncertain", area: "Delivery recovery", level: "boundary")[#given[A provider may have accepted a submitted message.] #when[Its acknowledgement is unavailable.] #then[Delivery reports an unknown outcome.] #then[The library makes no replacement submission.]]
    #behavior(title: "Untrusted transport is refused", area: "Transport security", level: "boundary")[#given[A configured secure transport cannot authenticate its peer.] #when[The application requests delivery.] #then[The exchange fails without transmitting message content or credentials over an unauthenticated connection.]]
    #behavior(title: "A provider response without confirmation is not acceptance", area: "Provider acceptance", level: "boundary")[#given[A provider reply signals transport-level success without confirming acceptance and identifying the message.] #when[The adapter interprets the response.] #then[Delivery reports an unknown outcome.]]
  ])

  #section(title: "Development mailbox and flow tests", lead: "A capture records the messages an application sends. Helpers and a read-only mailbox inspect it without side effects.", body: [
    #answers(title: "Explicit development inspection",
      responsibility: [Inspect locally captured mail while testing an application flow.],
      interface: [Capture entries expose increasing identifiers and complete messages. A #term("term-checkpoint") binds one capture and its current position. Testing helpers select matching messages after a checkpoint with a bounded wait. The optional mailbox package handles Gleam HTTP requests at an application-selected mount path.],
      interactions: [The application injects the capture sender into its delivery path and mounts the handler in its development server. The application owns server lifetime and access policy. Core capture has no HTTP dependency. #adr(2)],
      invariants: [Inspection never sends mail or consumes a challenge. Clearing messages does not rewind identifiers or checkpoints. Helpers cannot match mail before their checkpoint. The read-only mailbox never activates message links automatically.],
      failure: [Capture unavailability, capture deadline, invalid wait duration, and no matching message before timeout remain distinct typed results. Missing mailbox entries return not found; unavailable capture returns service unavailable.],
    )
    #points([Entry identifiers are unique within one capture lifetime. Checkpoints retain their capture binding. Entries remain bounded by capacity and disappear on clear or termination.], [Testing predicates run in the caller process and the helper returns the earliest retained match after its checkpoint without consuming it. Recipient matching uses normalized envelope mailboxes, including Cc and blind recipients.], [A zero wait performs one inspection under the capture query bound of one second without polling. Positive waits accept deadlines through 60 seconds on a monotonic clock. Application predicate execution time and runtime scheduling remain caller-owned.], [Parallel tests give each flow its own capture or match an application correlation field in a custom predicate. A checkpoint alone does not distinguish concurrent messages sent to the same recipient.])
    #subsection(title: "Mailbox handler")[
      #points([The mount path is a non-root sequence of slash-separated ASCII letters, digits, hyphens, and underscores. Empty segments and trailing slashes are refused. The handler maps a Gleam HTTP request to a response, ignores query parameters and the request body, and starts no listener.], [A GET on the mount lists the latest fifty retained messages. A GET on a stable numeric detail path shows recipients, envelope, reply-to, custom headers, text, escaped HTML source, and attachment metadata. Attachments are never downloaded.], [Other methods return 405, unknown or removed entries return 404, and an unavailable capture returns 503. Every response prohibits caching and external framing.], [The preview preserves only the exact attribute-free tags p, br, strong, b, em, i, u, s, h1 through h4, ul, ol, li, blockquote, pre, code, hr, table, thead, tbody, tr, th, and td. Other tag text is discarded and all text content is escaped. Attributes, links, images, styles, scripts, forms, frames, and refresh instructions cannot become active content.], [The preview runs in an iframe with an empty sandbox and a restrictive content security policy. It cannot navigate the parent, submit forms, execute scripts, or fetch remote resources.], [Captured messages contain development secrets and blind recipients. The application mounts the handler only in an explicitly enabled development environment and owns its access control.])
    ]
    #behavior(title: "A flow sees only its new messages", area: "Development testing", level: "boundary")[#given[A capture contains earlier messages and a test records a checkpoint.] #when[The flow sends a matching message and the helper inspects after that checkpoint.] #then[The helper returns the new matching message.] #then[Earlier messages cannot satisfy the match, including after a clear.]]
    #behavior(title: "Waiting terminates explicitly", area: "Development testing", level: "boundary")[#given[A test waits for a matching message after a checkpoint.] #when[The deadline elapses or the capture stops.] #then[The helper returns a typed timeout or capture failure without including message content in the error.]]
    #behavior(title: "Mailbox inspection has no authentication effect", area: "Development mailbox", level: "interface")[#given[A captured message contains a sign-in secret and untrusted HTML.] #when[A developer opens its mailbox detail page.] #then[The developer can inspect the message.] #then[No sign-in URL is requested automatically and no message script, form, or remote resource executes.]]
  ])
]
