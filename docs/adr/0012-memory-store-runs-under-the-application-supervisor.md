<a id="adr-0012"></a>

# ADR-0012: The memory store runs only under the application's supervisor

Status: accepted
Date: 2026-11-25

## Decision

The in-memory challenge store starts only as a child specification
(`memory.supervised`) that the application adds to its own supervisor. It is
registered under a process name the application creates once at start-up, and
`memory.store(name)` builds the store port from that name. There is no
unsupervised start and no stop function: the supervisor owns the store's
lifetime. The store links to its supervisor only and neither links to nor
monitors any application process.

The core package depends on `gleam_otp` and `gleam_erlang` for the child
specification and the name.

## Rationale

- A store started by an ordinary process stopped when that process exited, and
  a store that failed left every caller holding a handle to a dead process. No
  supervisor could restart it.
- Linking the store to the process that started it reported a failure but
  still tied the store to an arbitrary process, and kept the caller
  responsible for rebuilding the service.
- A name lets one store port survive restarts: each command reaches whichever
  process holds the name. A restarted store is empty, which the memory store's
  contract already allows ("restart loses all rows"), and an empty store refuses
  the earlier challenges as missing instead of accepting them.
- Supervision is the standard OTP lifetime for a long-lived process, so the
  store composes with the application's own restart strategy.

## Consequences

- Breaking: `memory.start`, `memory.start_with_clock`,
  `memory.start_with_cleanup_interval`, `memory.stop`, `memory.Runtime`, and
  `memory.StartError` are removed. Applications create a name, check capacity
  with `memory.new`, add `memory.supervised(config)` to a supervisor, and build
  the port with `memory.store(name)`.
- Capacity is checked before any process starts, so an invalid capacity never
  reaches the supervisor.
- A command sent while no process holds the name returns `Unavailable`; a
  command in progress when the store fails returns `Unknown`. An issue,
  verify, or revoke mutation that ends `Unknown` carries a recovery handle,
  which then resolves against the restarted, empty store. A failed clock read
  at the start of an issue ends `Unknown` without a handle, because no issue
  command exists yet.
- The capture process is unchanged and keeps its explicit start and stop.
