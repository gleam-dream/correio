# Correio PostgreSQL store

Atomic challenge storage through a caller-owned named Pog pool. Semantics, limits, and recovery rules are specified in the [passwordless design](../../docs/design/design-layer.pdf).

Runnable example: [`passwordless_postgres`](../../apps/passwordless_demo/src/usage/passwordless_postgres.gleam), run against a disposable PostgreSQL by the repository gate.

## Use

- Construct the store with `new(pool, codec)`, where `pool` is a `process.Name(pog.Message)` and `Codec(a)` serializes the application's native subject type. `with_timeout(pool, codec, milliseconds)` sets a 1–60000 ms query timeout; the default is five seconds.
- Call `migrate` explicitly during deployment. Authentication requests never run migrations.
- Call the returned store's `cleanup(limit)` explicitly to delete eligible terminal rows.
- A timeout or missing commit acknowledgement returns `Unknown`. Retain the opaque recovery handle and recover through the same store.

## Test

```sh
nix develop -c scripts/with-postgres.sh sh -c \
  'cd adapters/correio_postgres && gleam test && ./check-ownership.sh'
```
