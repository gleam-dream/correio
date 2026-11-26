# Correio PostgreSQL store

[![CI](https://github.com/gleam-dream/correio/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/correio/actions/workflows/ci.yml)
[![correio on Hex](https://img.shields.io/hexpm/v/correio?label=Hex%3A%20correio)](https://hex.pm/packages/correio)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

> Upgrading from 0.1? See the [migration guide](https://github.com/gleam-dream/correio/blob/main/docs/MIGRATION.md#5-postgresql-definite-failures-are-faults). This adapter requires Correio 0.2.

Atomic challenge storage through a caller-owned named Pog pool. Semantics, limits, and recovery rules are specified in the [passwordless design](../../docs/design/design-layer.pdf).

Runnable example: [`passwordless_postgres`](../../apps/passwordless_demo/src/usage/passwordless_postgres.gleam), run against a disposable PostgreSQL by the repository gate.

## Installation

Add Correio and Pog from Hex and the PostgreSQL adapter from its Git subdirectory:

```toml
[dependencies]
correio = ">= 0.2.0 and < 0.3.0"
pog = ">= 4.0.0 and < 5.0.0"
correio_postgres = { git = "https://github.com/gleam-dream/correio.git", ref = "main", path = "adapters/correio_postgres" }
```

Commit `gleam.toml` and `manifest.toml` to retain the resolved versions and Git commit.

## Use

- Construct the store with `new(pool, codec)`, where `pool` is a `process.Name(pog.Message)` and `Codec(a)` serializes the application's native subject type. `with_timeout(pool, codec, milliseconds)` sets a 1–60000 ms query timeout; the default is five seconds.
- Call `migrate` explicitly during deployment. Authentication requests never run migrations.
- Call the returned store's `cleanup(limit)` explicitly to delete eligible terminal rows.
- A timeout or missing commit acknowledgement returns `Unknown`. Retain the opaque recovery handle and recover through the same store.
- A pool with no available connection returns `Unavailable`: no statement ran, so there is nothing to recover. A statement the server refused inside a transaction that it then rolled back returns `IncompatibleData` (a missing table, a constraint or data error) or `Unavailable` (lock, resource, and cancellation errors).

## Test

```sh
nix develop -c scripts/with-postgres.sh sh -c \
  'cd adapters/correio_postgres && gleam test && ./check-ownership.sh'
```
