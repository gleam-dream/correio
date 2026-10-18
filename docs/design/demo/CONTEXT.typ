#let terms = (
  (
    slug: "term-principal",
    title: [Principal],
    body: [The application's own type for an authenticated actor. Its variants keep #term("term-verification-evidence") and an OIDC identity as distinct authentication methods.],
  ),
  (
    slug: "term-initiating-browser-binding",
    title: [Initiating-browser binding],
    body: [A random cookie value that ties a challenge to the browser that requested it. Confirmation requires the same value.],
  ),
  (
    slug: "term-intentional-confirmation",
    title: [Intentional confirmation],
    body: [A POST submitted by the user from a rendered form after the landing page. Opening a link never counts as confirmation.],
  ),
  (
    slug: "term-cross-device-entry",
    title: [Cross-device entry],
    body: [A flow in which the user types a delivered code into a browser other than the requesting one. The receiving browser proves the code through its own command.],
  ),
  (
    slug: "term-session-publication",
    title: [Session publication],
    body: [The application's effect that rotates and stores a session after confirmed verification. It is separate from, and not rolled back by, consumption.],
  ),
)
