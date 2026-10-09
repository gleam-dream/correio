"""Summarize measured operations without imposing machine-dependent thresholds."""

import collections
import json
import math
import os
import platform
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "oracles"))
from source_digest import source_digest


def percentile(values: list[int], percent: float) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * percent) - 1)]


def main() -> None:
    directory = Path(os.environ["CORREIO_BENCHMARK_RESULTS"])
    raw = json.loads((directory / "samples.json").read_text())
    summaries = []
    for observation in raw["observations"]:
        samples = observation["samples"]
        elapsed = observation["elapsed_us"] / 1_000_000
        counts = collections.Counter(sample["outcome"] for sample in samples)
        success = counts["accepted"] + counts["prepared"]
        refused = counts["refused"]
        errors = len(samples) - success - refused
        latencies = [sample["latency_us"] for sample in samples]
        summaries.append(
            {
                "case": observation["case"],
                "repetition": observation["repetition"],
                "concurrency": observation["concurrency"],
                "samples": len(samples),
                "elapsed_seconds": elapsed,
                "operations_per_second": len(samples) / elapsed,
                "successful_operations_per_second": success / elapsed,
                "refusals_per_second": refused / elapsed,
                "counts": dict(counts),
                "errors": errors,
                "latency_us": {
                    "p50": percentile(latencies, 0.5),
                    "p95": percentile(latencies, 0.95),
                    "p99": percentile(latencies, 0.99),
                },
            }
        )
    cpu = subprocess.check_output(["lscpu"], text=True)
    gleam = subprocess.check_output(["gleam", "--version"], text=True).strip()
    postgres = subprocess.check_output(["postgres", "--version"], text=True).strip()
    report = {
        "platform": platform.platform(),
        "cpu": cpu,
        "gleam": gleam,
        "postgres": postgres,
        "runtime": raw["runtime"],
        "configuration": raw["configuration"],
        "source": source_digest(Path(__file__).resolve().parents[1], (directory,)),
        "measurements": summaries,
        "latency_definition": "monotonic microseconds for one complete public operation; nearest-rank percentiles",
        "elapsed_definition": "wall duration from releasing prepared workers to receipt of all results",
    }
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [
        "# Benchmark measurements",
        "",
        f"- Runtime: {gleam}; OTP {raw['runtime']['otp']}; {raw['runtime']['schedulers_online']} schedulers.",
        f"- Source digest: `{report['source']['digest']}`.",
        "- Throughput includes measured operations only. Authentication refusals are shown separately.",
        "",
        "| Case | Repetition | Concurrency | Samples | Success/s | Refused/s | p50 µs | p95 µs | p99 µs | Errors |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for item in summaries:
        latency = item["latency_us"]
        lines.append(
            f"| {item['case']} | {item['repetition']} | {item['concurrency']} | {item['samples']} | {item['successful_operations_per_second']:.1f} | {item['refusals_per_second']:.1f} | {latency['p50']} | {latency['p95']} | {latency['p99']} | {item['errors']} |"
        )
    (directory / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    if any(item["errors"] for item in summaries):
        raise SystemExit(
            "Benchmark completed with operation errors; retained report includes them"
        )
    for item in summaries:
        if item["case"] == "postgres_same_challenge" and item["counts"] != {
            "accepted": 1,
            "refused": 23,
        }:
            raise SystemExit(
                "Contention correctness failed; this is not a throughput threshold"
            )


if __name__ == "__main__":
    main()
