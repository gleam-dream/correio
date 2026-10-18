#let terms = (
  (
    slug: "term-challenge",
    title: [Challenge],
    body: [A bounded opportunity to prove possession of a secret delivered to a particular address for one subject, scope, and purpose.],
  ),
  (
    slug: "term-consumption",
    title: [Consumption],
    body: [The atomic transition that grants one verification command the challenge's authentication evidence after checking its secret, attempt budget, and expiry.],
  ),
  (
    slug: "term-verification-evidence",
    title: [Verification evidence],
    body: [Opaque evidence of confirmed challenge consumption carrying the original application subject, destination, purpose, scope, and authentication time. It is not an OIDC identity or a permission grant.],
  ),
  (
    slug: "term-verification-identity",
    title: [Verification identity],
    body: [The stable identity of one confirmed consumption. An application uses it as the idempotency identity of its own session publication.],
  ),
  (
    slug: "term-recovery",
    title: [Recovery],
    body: [An opaque retained command that resolves an uncertain storage acknowledgement without issuing another challenge or granting another consumption.],
  ),
  (
    slug: "term-retention",
    title: [Retention],
    body: [The interval during which terminal challenge records preserve replay refusal and recovery receipts after their authentication opportunity ends.],
  ),
  (
    slug: "term-attempt-budget",
    title: [Attempt budget],
    body: [The bounded number of wrong answers an active #term("term-challenge") accepts before it is exhausted.],
  ),
  (
    slug: "term-challenge-store",
    title: [Challenge store],
    body: [A typed port whose operations atomically serialize issue, verification, recovery, and revocation, including time sampling and attempt accounting. A generic compare-and-set does not satisfy it.],
  ),
)
