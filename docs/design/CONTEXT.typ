#let terms = (
  (slug: "term-message", title: [Message], body: [A validated immutable description of email recipients, content, and attachments, independent of a delivery provider.]),
  (slug: "term-envelope", title: [Envelope], body: [The sender and complete recipient set submitted to the transport, including blind recipients that are absent from rendered headers.]),
  (slug: "term-delivery-evidence", title: [Delivery evidence], body: [The observed distinction between provider acceptance, definite refusal or non-transmission, and possible transmission without a confirmed outcome. It does not establish inbox delivery.]),
  (slug: "term-challenge", title: [Challenge], body: [A bounded opportunity to prove possession of a secret delivered to a particular address for one subject, scope, and purpose.]),
  (slug: "term-consumption", title: [Consumption], body: [The atomic transition that grants one verification command the challenge's authentication evidence after checking its secret, attempt budget, and expiry.]),
  (slug: "term-verification-evidence", title: [Verification evidence], body: [Opaque evidence of confirmed challenge consumption carrying the original application subject, destination, purpose, scope, and authentication time. It is not an OIDC identity or a permission grant.]),
  (slug: "term-recovery", title: [Recovery], body: [An opaque retained command that resolves an uncertain storage acknowledgement without issuing another challenge or granting another consumption.]),
  (slug: "term-retention", title: [Retention], body: [The interval during which terminal challenge records preserve replay refusal and recovery receipts after their authentication opportunity ends.]),
  (slug: "term-oracle", title: [Oracle], body: [A pinned external implementation used to judge an explicitly named subset of observable behavior.]),
)
