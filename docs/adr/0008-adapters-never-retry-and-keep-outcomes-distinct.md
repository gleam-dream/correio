# Adapters never retry and keep delivery outcomes distinct

<a id="adr-0008"></a>

## Decision

- No adapter and no library path retries a submission after possible transmission.
- Accepted, not sent, rejected, and unknown remain separate outcomes. A lost acknowledgement, a malformed successful response, and a server error all report unknown.
- A storage timeout or missing commit acknowledgement returns an unknown result with a recovery handle for the original command instead of a rollback claim.

## Rationale

- A retry after possible transmission can deliver a duplicate email, and the library cannot know whether the application tolerates one.
- A timeout never proves rollback, so a replacement command could consume or issue twice.
- Retry policy needs a duplicate-delivery decision or destination-supported idempotency, which only the application can supply.
