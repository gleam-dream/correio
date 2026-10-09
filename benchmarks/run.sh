#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CORREIO_BENCHMARK_RESULTS="${CORREIO_BENCHMARK_RESULTS:-$PWD/benchmarks/results}"
mkdir -p "$CORREIO_BENCHMARK_RESULTS"
CORREIO_BENCHMARK_RESULTS="$(realpath "$CORREIO_BENCHMARK_RESULTS")"
export CORREIO_BENCHMARK_RESULTS
cd oracles/correio_fixture
gleam run -m benchmark
cd ../..
python3 benchmarks/report.py
