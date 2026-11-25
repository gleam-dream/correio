//// Bounded local challenge store that runs as a child of the application's
//// supervisor. Restart loses all rows.
////
//// The store process removes rows past retention on its own timer, so an
//// application need not schedule `cleanup`. Capacity still bounds retained
//// rows: rate-limit issuance per destination and origin in the application.

import correio/passwordless/store
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

/// The messages of a store process. Only this module sends them; the type
/// tags the process name that `supervised` registers and `store` reaches.
pub type Message(a)

/// A store configuration whose capacity has been checked.
pub opaque type Config(a) {
  Config(
    name: Name(Message(a)),
    capacity: Int,
    clock: fn() -> Int,
    cleanup_interval_ms: Int,
  )
}

pub type InvalidCapacity {
  InvalidCapacity
}

/// Each index holds one `#(time, id)` entry per row it covers, ordered by
/// time. `expiries` covers rows that were never consumed, by `expires_at`;
/// `retentions` covers every row, by `retain_until`. `incarnation` is created
/// when the process starts, so a restarted store refuses every issue command
/// stamped before its restart.
type State(a) {
  State(
    incarnation: String,
    clock: fn() -> Int,
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

/// A store registered under `name` that retains at most `capacity` rows, at
/// most one million.
///
/// A row holds its slot until its retention ends. A full store admits a new
/// challenge by discarding one row past retention or, failing that, the
/// longest-expired challenge that was never consumed. A consumption receipt
/// keeps its slot for its whole retention. The store also removes rows past
/// retention on its own timer, once a minute.
///
/// Create the name once at application start, never from request input, and
/// pass it to both `supervised` and `store`.
pub fn new(
  name: Name(Message(a)),
  capacity: Int,
) -> Result(Config(a), InvalidCapacity) {
  case capacity > 0 && capacity <= 1_000_000 {
    True ->
      Ok(Config(
        name,
        capacity,
        system_milliseconds,
        default_cleanup_interval_ms,
      ))
    False -> Error(InvalidCapacity)
  }
}

/// Replaces the millisecond clock. The store samples it inside serialized
/// commands and its own cleanup, never before admission.
pub fn with_clock(config: Config(a), clock: fn() -> Int) -> Config(a) {
  Config(..config, clock:)
}

/// Sets the period of the store's own removal of rows past retention. The
/// period is clamped to 1 millisecond through 1 day.
pub fn with_cleanup_interval(config: Config(a), interval_ms: Int) -> Config(a) {
  Config(..config, cleanup_interval_ms: int.clamp(interval_ms, 1, 86_400_000))
}

/// The store as a child of the application's supervisor, registered under the
/// configured name. The supervisor owns its lifetime: the store is linked to
/// the supervisor and to no other process, so it outlives the process that
/// built the configuration and stops only with its supervisor. A store that
/// fails is restarted empty under the same name, and every `store.Store` built
/// with `store` reaches the replacement. A command in progress when the store
/// fails returns `Unknown`; a command sent while no store is registered
/// returns `Unavailable`. The replacement starts a new incarnation, so an
/// issue recovery handle from before the restart is refused as `IssueExpired`
/// and cannot insert its challenge again.
pub fn supervised(config: Config(a)) -> ChildSpecification(store.Store(a)) {
  supervision.worker(fn() {
    let state =
      State(
        new_incarnation(),
        config.clock,
        dict.new(),
        config.capacity,
        index_new(),
        index_new(),
      )
    start_process(
      config.name,
      state,
      fn(state: State(a)) {
        let #(state, removed) =
          remove_past_retention(state, state.clock(), cleanup_batch, 0)
        #(state, removed == cleanup_batch)
      },
      config.cleanup_interval_ms,
    )
    |> result.map(fn(pid) { actor.Started(pid, store(config.name)) })
    |> result.map_error(actor.InitExited)
  })
}

/// The store registered under `name`. Each command reaches whichever process
/// holds the name when the command is sent.
pub fn store(name: Name(Message(a))) -> store.Store(a) {
  store.Store(
    now: fn() {
      call(name, fn(state: State(a)) {
        #(state, store.Instant(state.clock(), state.incarnation))
      })
    },
    issue: fn(command) {
      call(name, fn(state: State(a)) {
        let now = state.clock()
        case
          command.incarnation == state.incarnation,
          dict.get(state.rows, command.id)
        {
          // Stamped before a restart: the row it may have written is lost.
          False, _ -> #(state, Error(store.IssueExpired))
          True, Ok(row) ->
            case store.same_issue(row, command), now < row.retain_until {
              False, _ -> #(state, Error(store.IdentityCollision))
              True, False -> #(state, Error(store.IssueExpired))
              True, True -> #(state, Ok(row))
            }
          True, Error(_) ->
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
      call(name, fn(state: State(a)) {
        case dict.get(state.rows, command.id) {
          Error(_) -> #(state, Error(store.Missing))
          Ok(row) -> {
            let #(next, reply) = store.verify_row(row, command, state.clock())
            #(update(state, next), reply)
          }
        }
      })
    },
    revoke: fn(command) {
      call(name, fn(state: State(a)) {
        case dict.get(state.rows, command.id) {
          Error(_) -> #(state, Error(store.Missing))
          Ok(row) -> {
            let #(next, reply) = store.revoke_row(row, command, state.clock())
            #(update(state, next), reply)
          }
        }
      })
    },
    cleanup: fn(limit) {
      case limit > 0 && limit <= 1000 {
        False -> Error(store.Capacity)
        True ->
          call(name, fn(state: State(a)) {
            remove_past_retention(state, state.clock(), limit, 0)
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

@external(erlang, "correio_auth_memory_ffi", "start")
fn start_process(
  name: Name(Message(a)),
  state: state,
  cleanup: fn(state) -> #(state, Bool),
  interval_ms: Int,
) -> Result(Pid, process.ExitReason)

@external(erlang, "correio_auth_memory_ffi", "call")
fn call(
  name: Name(Message(a)),
  function: fn(State(a)) -> #(State(a), reply),
) -> Result(reply, store.Fault)

@external(erlang, "correio_auth_memory_ffi", "incarnation")
fn new_incarnation() -> String

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
