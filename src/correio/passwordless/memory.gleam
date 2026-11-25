//// Bounded, explicitly owned local challenge store. Restart loses all rows.
////
//// The store process removes rows past retention on its own timer, so an
//// application need not schedule `cleanup`. Capacity still bounds retained
//// rows: rate-limit issuance per destination and origin in the application.

import correio/passwordless/store
import gleam/dict.{type Dict}
import gleam/int
import gleam/result

pub opaque type Runtime(a) {
  Runtime(process: Process(State(a)), clock: fn() -> Int)
}

pub type StartError {
  InvalidCapacity
  StartFailed
}

pub type Process(state)

/// Each index holds one `#(time, id)` entry per row it covers, ordered by
/// time. `expiries` covers rows that were never consumed, by `expires_at`;
/// `retentions` covers every row, by `retain_until`.
type State(a) {
  State(
    rows: Dict(String, store.Row(a)),
    capacity: Int,
    expiries: Index,
    retentions: Index,
  )
}

type Index

const default_cleanup_interval_ms = 60_000

/// Rows one pass of the store's own cleanup removes before it lets waiting
/// commands run.
const cleanup_batch = 1000

/// Capacity is the total retained row count, at most one million.
///
/// A row holds its slot until its retention ends. A full store admits a new
/// challenge by discarding one row past retention or, failing that, the
/// longest-expired challenge that was never consumed. A consumption receipt
/// keeps its slot for its whole retention. The store also removes rows past
/// retention on its own timer, once a minute.
pub fn start(capacity: Int) -> Result(Runtime(a), StartError) {
  start_with_clock(capacity, system_milliseconds)
}

/// Test clock is sampled inside serialized commands, never before admission.
pub fn start_with_clock(
  capacity: Int,
  clock: fn() -> Int,
) -> Result(Runtime(a), StartError) {
  start_with_cleanup_interval(capacity, clock, default_cleanup_interval_ms)
}

/// As `start_with_clock`, with the period of the store's own removal of rows
/// past retention. The period is clamped to 1 millisecond through 1 day.
pub fn start_with_cleanup_interval(
  capacity: Int,
  clock: fn() -> Int,
  interval_ms: Int,
) -> Result(Runtime(a), StartError) {
  case capacity > 0 && capacity <= 1_000_000 {
    False -> Error(InvalidCapacity)
    True ->
      start_process(
        State(dict.new(), capacity, index_new(), index_new()),
        fn(state) {
          let #(state, removed) =
            remove_past_retention(state, clock(), cleanup_batch, 0)
          #(state, removed == cleanup_batch)
        },
        int.clamp(interval_ms, 1, 86_400_000),
      )
      |> result.map(fn(process) { Runtime(process, clock) })
      |> result.map_error(fn(_) { StartFailed })
  }
}

pub fn store(runtime: Runtime(a)) -> store.Store(a) {
  store.Store(
    now: fn() { call(runtime.process, fn(state) { #(state, runtime.clock()) }) },
    issue: fn(command) {
      call(runtime.process, fn(state) {
        let now = runtime.clock()
        case dict.get(state.rows, command.id) {
          Ok(row) ->
            case store.same_issue(row, command), now < row.retain_until {
              False, _ -> #(state, Error(store.IdentityCollision))
              True, False -> #(state, Error(store.IssueExpired))
              True, True -> #(state, Ok(row))
            }
          Error(_) ->
            case now >= command.expires_at {
              True -> #(state, Error(store.IssueExpired))
              False -> {
                let state = make_room(state, now)
                case dict.size(state.rows) >= state.capacity {
                  True -> #(state, Error(store.Capacity))
                  False -> {
                    let row = store.issued(command)
                    #(insert(state, row), Ok(row))
                  }
                }
              }
            }
        }
      })
      |> result.flatten
    },
    verify: fn(command) {
      call(runtime.process, fn(state) {
        case dict.get(state.rows, command.id) {
          Error(_) -> #(state, Error(store.Missing))
          Ok(row) -> {
            let #(next, reply) = store.verify_row(row, command, runtime.clock())
            #(update(state, next), reply)
          }
        }
      })
    },
    revoke: fn(command) {
      call(runtime.process, fn(state) {
        case dict.get(state.rows, command.id) {
          Error(_) -> #(state, Error(store.Missing))
          Ok(row) -> {
            let #(next, reply) = store.revoke_row(row, command, runtime.clock())
            #(update(state, next), reply)
          }
        }
      })
    },
    cleanup: fn(limit) {
      case limit > 0 && limit <= 1000 {
        False -> Error(store.Capacity)
        True ->
          call(runtime.process, fn(state) {
            remove_past_retention(state, runtime.clock(), limit, 0)
          })
      }
    },
  )
}

fn insert(state: State(a), row: store.Row(a)) -> State(a) {
  State(
    ..state,
    rows: dict.insert(state.rows, row.id, row),
    expiries: index_insert(state.expiries, row.expires_at, row.id),
    retentions: index_insert(state.retentions, row.retain_until, row.id),
  )
}

fn remove(state: State(a), row: store.Row(a)) -> State(a) {
  State(
    ..state,
    rows: dict.delete(state.rows, row.id),
    expiries: index_delete(state.expiries, row.expires_at, row.id),
    retentions: index_delete(state.retentions, row.retain_until, row.id),
  )
}

/// Stores a transition of an existing row. A consumed row leaves `expiries`,
/// so a full store cannot discard its receipt before retention ends.
fn update(state: State(a), row: store.Row(a)) -> State(a) {
  let expiries = case row.status {
    store.Spent(_, _) -> index_delete(state.expiries, row.expires_at, row.id)
    store.Active | store.Withdrawn | store.TimedOut -> state.expiries
  }
  State(..state, rows: dict.insert(state.rows, row.id, row), expiries:)
}

/// The row of the earliest entry of an index, when that entry is due.
fn due(state: State(a), index: Index, now: Int) -> Result(store.Row(a), Nil) {
  case index_first(index) {
    Ok(#(at, id)) if at <= now -> dict.get(state.rows, id)
    Ok(_) | Error(_) -> Error(Nil)
  }
}

fn remove_past_retention(
  state: State(a),
  now: Int,
  limit: Int,
  removed: Int,
) -> #(State(a), Int) {
  case removed < limit, due(state, state.retentions, now) {
    True, Ok(row) ->
      remove_past_retention(remove(state, row), now, limit, removed + 1)
    _, _ -> #(state, removed)
  }
}

/// Frees one slot in a full store when a row no longer needs it.
fn make_room(state: State(a), now: Int) -> State(a) {
  case dict.size(state.rows) >= state.capacity {
    False -> state
    True ->
      case due(state, state.retentions, now) {
        Ok(row) -> remove(state, row)
        Error(_) ->
          case due(state, state.expiries, now) {
            Ok(row) -> remove(state, row)
            Error(_) -> state
          }
      }
  }
}

/// Returns only after the process has stopped. Unknown does not prove completion.
pub fn stop(runtime: Runtime(a)) -> Result(Nil, store.Fault) {
  stop_process(runtime.process)
}

@external(erlang, "correio_auth_memory_ffi", "start")
fn start_process(
  state: state,
  cleanup: fn(state) -> #(state, Bool),
  interval_ms: Int,
) -> Result(Process(state), Nil)

@external(erlang, "correio_auth_memory_ffi", "call")
fn call(
  process: Process(state),
  function: fn(state) -> #(state, reply),
) -> Result(reply, store.Fault)

@external(erlang, "correio_auth_memory_ffi", "stop")
fn stop_process(process: Process(state)) -> Result(Nil, store.Fault)

@external(erlang, "correio_auth_memory_ffi", "system_milliseconds")
fn system_milliseconds() -> Int

@external(erlang, "correio_auth_memory_ffi", "index_new")
fn index_new() -> Index

@external(erlang, "correio_auth_memory_ffi", "index_insert")
fn index_insert(index: Index, at: Int, id: String) -> Index

@external(erlang, "correio_auth_memory_ffi", "index_delete")
fn index_delete(index: Index, at: Int, id: String) -> Index

@external(erlang, "correio_auth_memory_ffi", "index_first")
fn index_first(index: Index) -> Result(#(Int, String), Nil)
