# Correio PostgreSQL store

- `correio_postgres` implements atomic challenge storage through a caller-owned named Pog pool.
- The adapter requires `process.Name(pog.Message)`. An enclosing transaction's `pog.Connection` cannot be passed to its constructor because the adapter owns its own transaction boundary.
- `Codec(a)` serializes the application's native subject type. Decoding incompatible persisted values returns `IncompatibleData`.
- Call `migrate` explicitly during deployment. The initial schema uses the fixed `ecarta_challenges` table and an indexed retention deadline. Migration does not run during authentication requests.
- `new(pool, codec)` uses a five-second query timeout. `with_timeout(pool, codec, milliseconds)` accepts 1–60000 milliseconds.
- Each verification locks its row, reads the database clock after acquiring the lock, applies one transition, and commits before returning evidence.
- Timestamps are integer Unix milliseconds. Issue commands retain immutable absolute expiry and retention timestamps during recovery.
- The store retains terminal rows through their configured retention. Call the returned store's `cleanup(limit)` explicitly; each call deletes at most 1–1000 eligible rows and skips locked rows.
- Pool capacity, admission pressure, supervision, pool shutdown, database availability, and database clock discipline remain application responsibilities.
- A timeout or missing COMMIT acknowledgement can return `Unknown`. Retain the operation's opaque recovery handle and recover through the same authoritative store.
- The test suite exercises 24 distinct PostgreSQL connections, concurrent wrong answers, expiry during a row-lock wait, codec refusal, cleanup, and a wire proxy that drops a confirmed COMMIT acknowledgement.

```sh
nix develop -c scripts/with-postgres.sh sh -c \
  'cd adapters/correio_postgres && gleam test && ./check-ownership.sh'
```
