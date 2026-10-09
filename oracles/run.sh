#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export CORREIO_ORACLE_RESULTS="${CORREIO_ORACLE_RESULTS:-$PWD/results}"
mkdir -p "$CORREIO_ORACLE_RESULTS"
CORREIO_ORACLE_RESULTS="$(realpath "$CORREIO_ORACLE_RESULTS")"
export CORREIO_ORACLE_RESULTS
mix deps.get --check-locked
python3 check_sources.py
python3 -m unittest test_comparison.py
mix run run.exs
cd correio_fixture
gleam run
cd ..
python3 compare.py "$CORREIO_ORACLE_RESULTS/upstream.json" "$CORREIO_ORACLE_RESULTS/correio.json"
