#let terms = (
  (
    slug: "term-message",
    title: [Message],
    body: [A validated immutable description of email recipients, content, and attachments, independent of a delivery provider.],
  ),
  (
    slug: "term-envelope",
    title: [Envelope],
    body: [The sender and complete recipient set submitted to the transport, including blind recipients that are absent from rendered headers.],
  ),
  (
    slug: "term-delivery-outcome",
    title: [Delivery outcome],
    body: [The closed result of one submission: accepted, not sent, rejected, or unknown. Each variant states what the library observed about transmission, and none establishes inbox delivery.

      _Avoid_: delivery status — implies inbox arrival, which no outcome establishes; delivery evidence — a second name for the same value.],
  ),
  (
    slug: "term-sender",
    title: [Sender],
    body: [A function from one #term("term-message") to one #term("term-delivery-outcome"). The application injects the sender where it needs delivery.],
  ),
  (
    slug: "term-capture",
    title: [Capture],
    body: [An explicitly started bounded runtime that records complete normalized messages without network I/O. A capture is never global.],
  ),
  (
    slug: "term-checkpoint",
    title: [Checkpoint],
    body: [An opaque value binding one #term("term-capture") to a position in its message sequence. Helpers match only messages recorded after the position.],
  ),
  (
    slug: "term-formatting-preview",
    title: [Formatting preview],
    body: [A sandboxed projection of message HTML that preserves only attribute-free formatting tags. It is not a faithful email rendering.],
  ),
)
