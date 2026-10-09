# ADR 0002: Development mailbox inspection

<a id="adr-0002"></a>

## Decision

- Flow tests inspect the same explicitly owned capture used as the application sender.
- Checkpoints distinguish new mail without clearing shared capture state.
- The optional mailbox package supplies an HTTP handler for a caller-owned development server.
- HTML preview retains only formatting tags without attributes and runs inside a sandbox with remote resources disabled.
- Original HTML remains available as escaped source.

## Rationale

- A global mailbox would make concurrent consumers interfere with one another.
- An HTTP dependency in core would couple non-web tests to a server stack.
- Rendering email HTML directly in the application origin would give content authority over application sessions.
- A read-only handler avoids adding mailbox mutation authorization to the development surface.
