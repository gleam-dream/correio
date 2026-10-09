# Correio development mailbox

## Mount

```gleam
import correio/capture
import correio_mailbox

let assert Ok(outbox) = capture.start(100)
let send = capture.sender(outbox)
let assert Ok(mailbox) = correio_mailbox.new(outbox, at: "/dev/mailbox")
// Inject send into your application's delivery dependency.
// In your development router, pass the original Gleam HTTP request:
let response = correio_mailbox.handle(mailbox, request)
```

- Enable the route explicitly in your development environment. Captured mail exposes secrets and blind recipients; the application owns access control and the server.
- `new` validates a non-root mount path with slash-separated ASCII letters, digits, hyphens, and underscores. Empty segments and trailing slashes are refused.
- `handle` accepts `gleam/http/request.Request(body)` and returns `gleam/http/response.Response(String)`. It uses the original request path with its mount prefix. It ignores query parameters and the request body.
- GET lists the latest fifty retained messages. Stable numeric detail URLs identify messages until capture clearing or termination. Clearing never reuses identifiers.
- GET detail shows recipients, envelope, reply-to, custom headers, text, HTML source, and attachment metadata. It never downloads attachments or activates message links.
- Other methods return 405. Unknown paths or removed entries return 404. An unavailable capture returns 503. Every response prevents caching and external framing.
- No HTTP listener starts in this package. Core Correio has no HTTP dependency.

## HTML preview

- The preview is a formatting projection rather than a faithful email rendering. The complete original source remains visible separately.
- Only exact attribute-free `p`, `br`, `strong`, `b`, `em`, `i`, `u`, `s`, `h1`–`h4`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`, `hr`, `table`, `thead`, `tbody`, `tr`, `th`, and `td` tags become markup.
- Other tag text is discarded and all text content is escaped. Existing entity notation remains literal. Attributes, links, images, styles, scripts, forms, frames, and refresh instructions cannot become active content.
- The projected document also runs in an iframe with an empty sandbox and a restrictive content security policy. Its content cannot navigate the parent, submit forms, execute scripts, or fetch resources.
- Copy a sign-in URL from the text or source and open it intentionally. Opening the inbox or a message detail never follows email URLs.

## Try it

```sh
# From the Correio repository root; no database or credentials needed.
nix develop -c sh -c 'cd apps/passwordless_demo && gleam run -m dev'
```

- Open the printed sign-in form, request mail for `alice@example.com`, and open the printed mailbox address in another tab of the same browser.
- The example stores state in memory. Stopping it discards mail, challenges, and sessions.
