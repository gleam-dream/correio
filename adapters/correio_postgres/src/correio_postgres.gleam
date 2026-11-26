//// The ecarta_challenges table name is retained for stored challenge compatibility.
//// Durable semantic store. The caller owns the pool and application subject codec.
//// Times are Unix milliseconds. SQL identifiers are fixed; values are parameters.

import correio/passwordless/store
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pog

pub type Codec(a) {
  Codec(encode: fn(a) -> String, decode: fn(String) -> Result(a, Nil))
}

pub type ConfigError {
  InvalidTimeout
}

pub fn new(pool: process.Name(pog.Message), codec: Codec(a)) -> store.Store(a) {
  configured(pog.named_connection(pool), codec, 5000)
}

/// Query deadlines bound lock waits and exchanges. A statement that times out
/// inside a transaction whose rollback the server acknowledged is
/// `Unavailable`. A timeout that leaves a commit uncertain is `Unknown`.
pub fn with_timeout(
  pool: process.Name(pog.Message),
  codec: Codec(a),
  timeout_ms: Int,
) -> Result(store.Store(a), ConfigError) {
  case timeout_ms > 0 && timeout_ms <= 60_000 {
    True -> Ok(configured(pog.named_connection(pool), codec, timeout_ms))
    False -> Error(InvalidTimeout)
  }
}

fn configured(
  db: pog.Connection,
  codec: Codec(a),
  timeout: Int,
) -> store.Store(a) {
  store.Store(
    now: fn() {
      protect(fn() {
        now(db, timeout)
        |> result.map(store.Instant(_, incarnation))
      })
    },
    issue: fn(command) {
      transaction(db, timeout, fn(connection) {
        issue(connection, codec, timeout, command)
      })
    },
    verify: fn(command) {
      transaction(db, timeout, fn(connection) {
        use found <- result.try(find_locked(
          connection,
          codec,
          timeout,
          command.id,
        ))
        case found {
          None -> Ok(Error(store.Missing))
          Some(row) -> {
            use time <- result.try(now(connection, timeout))
            let #(next, reply) = store.verify_row(row, command, time)
            use _ <- result.try(save_transition(connection, timeout, row, next))
            Ok(reply)
          }
        }
      })
    },
    revoke: fn(command) {
      transaction(db, timeout, fn(connection) {
        use found <- result.try(find_locked(
          connection,
          codec,
          timeout,
          command.id,
        ))
        case found {
          None -> Ok(Error(store.Missing))
          Some(row) -> {
            use time <- result.try(now(connection, timeout))
            let #(next, reply) = store.revoke_row(row, command, time)
            use _ <- result.try(save_transition(connection, timeout, row, next))
            Ok(reply)
          }
        }
      })
    },
    cleanup: fn(limit) {
      protect(fn() {
        case limit > 0 && limit <= 1000 {
          False -> Error(store.Capacity)
          True ->
            pog.query(
              "with expired as (select id from ecarta_challenges
          where retain_until_ms <= floor(extract(epoch from clock_timestamp()) * 1000)::bigint
          order by retain_until_ms limit $1 for update skip locked)
          delete from ecarta_challenges c using expired e where c.id = e.id",
            )
            |> pog.parameter(pog.int(limit))
            |> pog.timeout(timeout)
            |> pog.execute(db)
            |> result.map(fn(rows) { rows.count })
            |> result.map_error(write_fault)
        }
      })
    },
  )
}

/// Idempotent initial schema. Run explicitly during deployment, never per request.
pub fn migrate(db: pog.Connection) -> Result(Nil, store.Fault) {
  protect(fn() { migrate_schema(db) })
}

fn migrate_schema(db: pog.Connection) -> Result(Nil, store.Fault) {
  use _ <- result.try(
    pog.query(
      "create table if not exists ecarta_challenges (
    id text primary key check (length(id) = 43),
    subject text not null,
    scope text not null check (octet_length(scope) between 1 and 320),
    purpose text not null check (octet_length(purpose) between 1 and 320),
    destination text not null check (octet_length(destination) between 1 and 320),
    verifier text not null check (length(verifier) = 64),
    expires_at_ms bigint not null,
    retain_until_ms bigint not null check (retain_until_ms > expires_at_ms),
    attempts integer not null check (attempts between 0 and 100),
    status text not null check (status in ('active', 'spent', 'withdrawn', 'expired')),
    consumed_command text,
    authenticated_at_ms bigint,
    failed_commands text[] not null default '{}',
    check (cardinality(failed_commands) + attempts between 1 and 100),
    check ((status = 'spent' and consumed_command is not null and length(consumed_command) = 43 and authenticated_at_ms is not null and authenticated_at_ms < expires_at_ms)
      or (status <> 'spent' and consumed_command is null and authenticated_at_ms is null))
  )",
    )
    |> pog.execute(db)
    |> result.map_error(write_fault),
  )
  pog.query(
    "create index if not exists ecarta_challenges_retention on ecarta_challenges (retain_until_ms)",
  )
  |> pog.execute(db)
  |> result.map(fn(_) { Nil })
  |> result.map_error(write_fault)
}

/// PostgreSQL rows outlive every application and database restart, so the
/// store has one incarnation. The insert itself refuses a command whose
/// challenge has expired, and a consumed row stays until its retention ends.
const incarnation = "postgresql"

fn now(db: pog.Connection, timeout: Int) -> Result(Int, store.Fault) {
  use rows <- result.try(
    pog.query(
      "select floor(extract(epoch from clock_timestamp()) * 1000)::bigint",
    )
    |> pog.timeout(timeout)
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db)
    |> result.map_error(uncommitted_fault),
  )
  case rows.rows {
    [time] -> Ok(time)
    _ -> Error(store.IncompatibleData)
  }
}

fn issue(
  db: pog.Connection,
  codec: Codec(a),
  timeout: Int,
  command: store.Issue(a),
) -> Result(store.Row(a), store.Fault) {
  use _ <- result.try(
    pog.query(
      "insert into ecarta_challenges
    (id, subject, scope, purpose, destination, verifier, expires_at_ms, retain_until_ms, attempts, status)
    select $1,$2,$3,$4,$5,$6,$7,$8,$9,'active'
    where floor(extract(epoch from clock_timestamp()) * 1000)::bigint < $7
    on conflict (id) do nothing",
    )
    |> pog.parameter(pog.text(command.id))
    |> pog.parameter(pog.text(codec.encode(command.subject)))
    |> pog.parameter(pog.text(command.scope))
    |> pog.parameter(pog.text(command.purpose))
    |> pog.parameter(pog.text(command.destination))
    |> pog.parameter(pog.text(command.verifier))
    |> pog.parameter(pog.int(command.expires_at))
    |> pog.parameter(pog.int(command.retain_until))
    |> pog.parameter(pog.int(command.attempts))
    |> pog.timeout(timeout)
    |> pog.execute(db)
    |> result.map_error(uncommitted_fault),
  )
  use found <- result.try(find_locked(db, codec, timeout, command.id))
  use time <- result.try(now(db, timeout))
  case found {
    None -> Error(store.IssueExpired)
    Some(row) ->
      case store.same_issue(row, command), time < row.retain_until {
        False, _ -> Error(store.IdentityCollision)
        True, False -> Error(store.IssueExpired)
        True, True -> Ok(row)
      }
  }
}

fn find_locked(
  db: pog.Connection,
  codec: Codec(a),
  timeout: Int,
  id: String,
) -> Result(option.Option(store.Row(a)), store.Fault) {
  use rows <- result.try(
    pog.query(
      "select id,subject,scope,purpose,destination,verifier,expires_at_ms,retain_until_ms,attempts,status,consumed_command,authenticated_at_ms,failed_commands
    from ecarta_challenges where id=$1 for update",
    )
    |> pog.parameter(pog.text(id))
    |> pog.timeout(timeout)
    |> pog.returning(row_decoder(codec))
    |> pog.execute(db)
    |> result.map_error(uncommitted_fault),
  )
  case rows.rows {
    [] -> Ok(None)
    [Ok(row)] -> Ok(Some(row))
    _ -> Error(store.IncompatibleData)
  }
}

fn row_decoder(codec: Codec(a)) -> decode.Decoder(Result(store.Row(a), Nil)) {
  use id <- decode.field(0, decode.string)
  use encoded <- decode.field(1, decode.string)
  use scope <- decode.field(2, decode.string)
  use purpose <- decode.field(3, decode.string)
  use destination <- decode.field(4, decode.string)
  use verifier <- decode.field(5, decode.string)
  use expires <- decode.field(6, decode.int)
  use retention <- decode.field(7, decode.int)
  use attempts <- decode.field(8, decode.int)
  use status <- decode.field(9, decode.string)
  use consumed <- decode.field(10, decode.optional(decode.string))
  use authenticated <- decode.field(11, decode.optional(decode.int))
  use failed <- decode.field(12, decode.list(decode.string))
  let state = case status, consumed, authenticated {
    "active", None, None -> Ok(store.Active)
    "withdrawn", None, None -> Ok(store.Withdrawn)
    "expired", None, None -> Ok(store.TimedOut)
    "spent", Some(command), Some(time) if time < expires ->
      Ok(store.Spent(command, time))
    _, _, _ -> Error(Nil)
  }
  case
    codec.decode(encoded),
    state,
    attempts >= 0
    && attempts + list.length(failed) <= 100
    && retention > expires
  {
    Ok(subject), Ok(status), True ->
      decode.success(
        Ok(store.Row(
          id,
          subject,
          scope,
          purpose,
          destination,
          verifier,
          expires,
          retention,
          attempts,
          status,
          failed,
        )),
      )
    _, _, _ -> decode.success(Error(Nil))
  }
}

fn save_transition(
  db: pog.Connection,
  timeout: Int,
  previous: store.Row(a),
  row: store.Row(a),
) -> Result(Nil, store.Fault) {
  case previous == row {
    True -> Ok(Nil)
    False -> {
      let #(status, command, time) = case row.status {
        store.Active -> #("active", None, None)
        store.Withdrawn -> #("withdrawn", None, None)
        store.TimedOut -> #("expired", None, None)
        store.Spent(command, time) -> #("spent", Some(command), Some(time))
      }
      pog.query(
        "update ecarta_challenges set attempts=$2, status=$3, consumed_command=$4, authenticated_at_ms=$5, failed_commands=$6 where id=$1",
      )
      |> pog.parameter(pog.text(row.id))
      |> pog.parameter(pog.int(row.attempts))
      |> pog.parameter(pog.text(status))
      |> pog.parameter(pog.nullable(pog.text, command))
      |> pog.parameter(pog.nullable(pog.int, time))
      |> pog.parameter(pog.array(pog.text, row.failed_commands))
      |> pog.timeout(timeout)
      |> pog.execute(db)
      |> result.map(fn(_) { Nil })
      |> result.map_error(uncommitted_fault)
    }
  }
}

/// Statements inside the callback report `uncommitted_fault`. Pog returns
/// `TransactionRolledBack` only after the server acknowledged the rollback,
/// so such a fault is definite. `TransactionQueryError` carries a failed
/// checkout, begin, commit, or rollback; only a failed checkout proves that
/// nothing ran.
///
/// Pog applies no deadline to statements on a transaction's connection, so the
/// transaction first sets a transaction-local `statement_timeout`. The server
/// then cancels a statement, including a row-lock wait, that outlasts the
/// timeout and rolls the transaction back.
fn transaction(
  db: pog.Connection,
  timeout: Int,
  function: fn(pog.Connection) -> Result(a, store.Fault),
) -> Result(a, store.Fault) {
  protect(fn() {
    case
      pog.transaction(db, fn(connection) {
        use _ <- result.try(
          pog.query("select set_config('statement_timeout', $1, true)")
          |> pog.parameter(pog.text(int.to_string(timeout)))
          |> pog.timeout(timeout)
          |> pog.execute(connection)
          |> result.map_error(uncommitted_fault),
        )
        function(connection)
      })
    {
      Ok(value) -> Ok(value)
      Error(pog.TransactionRolledBack(error)) -> Error(error)
      Error(pog.TransactionQueryError(pog.ConnectionUnavailable)) ->
        Error(store.Unavailable)
      Error(pog.TransactionQueryError(_)) -> Error(store.Unknown)
    }
  })
}

/// Fault of a statement that commits nothing by itself: a read, or a write
/// inside a transaction. A lost reply is `Unavailable` here because the
/// acknowledged rollback or commit, not this statement, decides what is stored.
fn uncommitted_fault(error: pog.QueryError) -> store.Fault {
  refused(error)
}

/// Fault of a statement that commits by itself. A lost reply leaves its
/// effect unknown.
fn write_fault(error: pog.QueryError) -> store.Fault {
  case error {
    pog.QueryTimeout -> store.Unknown
    _ -> refused(error)
  }
}

/// Fault of a statement that did not run, that the server refused, or whose
/// reply was lost. A refused statement stores nothing.
fn refused(error: pog.QueryError) -> store.Fault {
  case error {
    pog.ConnectionUnavailable | pog.QueryTimeout -> store.Unavailable
    pog.UnexpectedArgumentCount(_, _)
    | pog.UnexpectedArgumentType(_, _)
    | pog.UnexpectedResultType(_)
    | pog.ConstraintViolated(_, _, _) -> store.IncompatibleData
    // SQLSTATE classes 22 (data exception), 23 (integrity constraint
    // violation), and 42 (syntax error or access rule violation, which
    // includes a missing table) mean the schema or stored data does not match
    // this adapter. Other classes, such as lock, resource, and cancellation
    // errors, can pass on a later attempt.
    pog.PostgresqlError(code, _, _) ->
      case string.slice(code, 0, 2) {
        "22" | "23" | "42" -> store.IncompatibleData
        _ -> store.Unavailable
      }
  }
}

@external(erlang, "correio_postgres_ffi", "protect")
fn protect(function: fn() -> Result(a, store.Fault)) -> Result(a, store.Fault)
