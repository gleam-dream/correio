# The demo binds challenges to the initiating browser and confirms by POST

<a id="adr-0007"></a>

## Decision

- The default flow binds each challenge to a random cookie held by the browser that requested it.
- A link landing records the answer in that browser's pending state and redirects to a clean confirmation page. Only a form POST with a matching Origin and CSRF token calls verification.
- Cross-device entry is an explicit separate mode in which the receiving browser proves a delivered code through its own command.
- The initiating-browser cookie uses SameSite Lax, and session cookies use SameSite Strict.

## Rationale

- Mail scanners and link previewers open links, so a GET that consumed a challenge would authenticate them.
- A top-level navigation from webmail must carry the binding, which SameSite Lax permits and Strict would drop.
- Binding to the initiating browser stops a forwarded link from authenticating a different browser. Cross-device entry stays available under its own explicit policy.
- The library does not infer browser policy from an email address, so these rules belong to the application example.
