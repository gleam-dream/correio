#!/usr/bin/env bash
# A transaction connection cannot be supplied to the pool-only store API.
set -euo pipefail
adapter="$(cd "$(dirname "$0")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/correio-ownership.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/src"
cat > "$fixture/gleam.toml" <<TOML
name = "correio_ownership_fixture"
version = "0.1.0"
target = "erlang"
[dependencies]
correio_postgres = { path = "$adapter" }
pog = ">= 4.0.0 and < 5.0.0"
TOML
cp "$adapter/fixtures/nested_transaction.gleam.txt" "$fixture/src/correio_ownership_fixture.gleam"
if (cd "$fixture" && gleam check > check.log 2>&1); then
  cat "$fixture/check.log"
  echo 'FAIL: nested transaction connection was accepted' >&2
  exit 1
fi
if ! rg -q 'Type mismatch' "$fixture/check.log" || ! rg -Fq 'process.Name(pog.Message)' "$fixture/check.log" || ! rg -q 'Connection' "$fixture/check.log"; then
  cat "$fixture/check.log"
  echo 'FAIL: fixture did not reach expected ownership type error' >&2
  exit 1
fi
echo 'Pool ownership compiler fixture: transaction connection rejected.'
