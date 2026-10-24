//// Bounded, explicitly owned local challenge store. Restart loses all rows.

import correio/passwordless/store
import gleam/dict.{type Dict}
import gleam/list
import gleam/result

pub opaque type Runtime(a) {
  Runtime(process: Process(State(a)), clock: fn() -> Int)
}

pub type StartError {
  InvalidCapacity
  StartFailed
}

pub type Process(state)

type State(a) {
  State(rows: Dict(String, store.Row(a)), capacity: Int)
}

/// Capacity is the total retained row count. Cleanup is explicit.
pub fn start(capacity: Int) -> Result(Runtime(a), StartError) {
  start_with_clock(capacity, system_milliseconds)
}

/// Test clock is sampled inside serialized commands, never before admission.
pub fn start_with_clock(
  capacity: Int,
  clock: fn() -> Int,
) -> Result(Runtime(a), StartError) {
  case capacity > 0 && capacity <= 1_000_000 {
    False -> Error(InvalidCapacity)
    True ->
      start_process(State(dict.new(), capacity))
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
            case
              now >= command.expires_at,
              dict.size(state.rows) >= state.capacity
            {
              True, _ -> #(state, Error(store.IssueExpired))
              False, True -> #(state, Error(store.Capacity))
              False, False -> {
                let row = store.issued(command)
                #(
                  State(..state, rows: dict.insert(state.rows, row.id, row)),
                  Ok(row),
                )
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
            #(
              State(..state, rows: dict.insert(state.rows, row.id, next)),
              reply,
            )
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
            #(
              State(..state, rows: dict.insert(state.rows, row.id, next)),
              reply,
            )
          }
        }
      })
    },
    cleanup: fn(limit) {
      case limit > 0 && limit <= 1000 {
        False -> Error(store.Capacity)
        True ->
          call(runtime.process, fn(state) {
            let now = runtime.clock()
            let ids =
              state.rows
              |> dict.to_list
              |> list.filter_map(fn(pair) {
                let #(id, row) = pair
                case row.retain_until <= now {
                  True -> Ok(id)
                  False -> Error(Nil)
                }
              })
              |> list.take(limit)
            let rows = list.fold(ids, state.rows, dict.delete)
            #(State(..state, rows:), list.length(ids))
          })
      }
    },
  )
}

/// Returns only after the process has stopped. Unknown does not prove completion.
pub fn stop(runtime: Runtime(a)) -> Result(Nil, store.Fault) {
  stop_process(runtime.process)
}

@external(erlang, "correio_auth_memory_ffi", "start")
fn start_process(state: state) -> Result(Process(state), Nil)

@external(erlang, "correio_auth_memory_ffi", "call")
fn call(
  process: Process(state),
  function: fn(state) -> #(state, reply),
) -> Result(reply, store.Fault)

@external(erlang, "correio_auth_memory_ffi", "stop")
fn stop_process(process: Process(state)) -> Result(Nil, store.Fault)

@external(erlang, "correio_auth_memory_ffi", "system_milliseconds")
fn system_milliseconds() -> Int
