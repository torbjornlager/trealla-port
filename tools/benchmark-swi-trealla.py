#!/usr/bin/env python3
"""Compare the composed SWI and Trealla actor implementations."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import re
import statistics
import subprocess
from pathlib import Path


RESULT_RE = re.compile(
    r"BENCHMARK_RESULT\((?P<name>[a-z_]+),(?P<count>[0-9]+),(?P<us>[0-9]+)\)\."
)


def prolog_atom(path: Path) -> str:
    return "'" + str(path).replace("'", "''") + "'"


def command_version(command: list[str]) -> str:
    completed = subprocess.run(
        command, text=True, capture_output=True, check=True
    )
    return (completed.stdout + completed.stderr).strip().splitlines()[0]


def git_revision(repository: Path) -> str | None:
    completed = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def engine_command(
    engine: str,
    executable: Path,
    root: Path,
    swi_repository: Path,
    name: str,
    count: int,
) -> list[str]:
    benchmark = root / "Benchmarking" / "comparative.pl"
    if engine == "trealla":
        goal = (
            f"use_module({prolog_atom(root / 'web_prolog.pl')}),"
            f"use_module({prolog_atom(root / 'actors.pl')}),"
            f"consult({prolog_atom(benchmark)}),"
            f"benchmark_run({name},{count}),halt"
        )
        return [str(executable), "-q", "-g", goal]

    goal = (
        "use_module(library(web_prolog)),"
        f"consult({prolog_atom(benchmark)}),"
        f"benchmark_run({name},{count}),halt"
    )
    return [
        str(executable),
        "-q",
        "-p",
        f"library={swi_repository / 'prolog'}",
        "-g",
        goal,
    ]


def run_sample(
    command: list[str], expected_name: str, expected_count: int, timeout: float
) -> int:
    try:
        completed = subprocess.run(
            command, text=True, capture_output=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"benchmark exceeded the {timeout:g}-second timeout"
        ) from error
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        raise RuntimeError(
            f"benchmark exited with {completed.returncode}:\n{output.strip()}"
        )
    match = RESULT_RE.search(output)
    if match is None:
        raise RuntimeError(f"benchmark emitted no result:\n{output.strip()}")
    if match.group("name") != expected_name or int(match.group("count")) != expected_count:
        raise RuntimeError(f"unexpected benchmark result: {match.group(0)}")
    diagnostics = RESULT_RE.sub("", output).strip()
    if diagnostics:
        raise RuntimeError(f"benchmark emitted diagnostics:\n{diagnostics}")
    return int(match.group("us"))


def parse_args(root: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--lifecycle", type=int, default=100)
    parser.add_argument("--chain", type=int, default=1000)
    parser.add_argument("--ping-pong", type=int, default=10000)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument(
        "--tpl", type=Path, default=root / ".build/trealla-v3.13.10/tpl"
    )
    parser.add_argument("--swipl", type=Path, default=Path("/usr/local/bin/swipl"))
    parser.add_argument(
        "--swi-repository",
        type=Path,
        default=root.parent / "trinity-demonstrator",
    )
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    args = parse_args(root)
    if args.repetitions < 1:
        raise SystemExit("--repetitions must be positive")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be positive")
    for path in (args.tpl, args.swipl, args.swi_repository / "prolog"):
        if not path.exists():
            raise SystemExit(f"required path does not exist: {path}")

    executables = {"trealla": args.tpl.resolve(), "swi": args.swipl.resolve()}
    workloads = [
        ("lifecycle", args.lifecycle),
        ("chain", args.chain),
        ("ping_pong", args.ping_pong),
    ]
    samples: dict[str, dict[str, list[int]]] = {
        name: {"trealla": [], "swi": []} for name, _ in workloads
    }

    for name, count in workloads:
        commands = {
            engine: engine_command(
                engine,
                executable,
                root,
                args.swi_repository.resolve(),
                name,
                count,
            )
            for engine, executable in executables.items()
        }
        for engine in ("trealla", "swi"):
            run_sample(
                commands[engine], name, count, args.timeout
            )  # discarded warm-up
        for repetition in range(args.repetitions):
            order = ("trealla", "swi") if repetition % 2 == 0 else ("swi", "trealla")
            for engine in order:
                value = run_sample(commands[engine], name, count, args.timeout)
                samples[name][engine].append(value)
                print(f"{name} {count} {engine} {value} us", flush=True)

    results = []
    for name, count in workloads:
        trealla_median = statistics.median(samples[name]["trealla"])
        swi_median = statistics.median(samples[name]["swi"])
        results.append(
            {
                "name": name,
                "count": count,
                "samples_us": samples[name],
                "median_us": {"trealla": trealla_median, "swi": swi_median},
                "trealla_over_swi": trealla_median / swi_median,
            }
        )

    document = {
        "schema": 1,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
        },
        "repetitions": args.repetitions,
        "warmups_per_engine": 1,
        "engines": {
            "trealla": {
                "version": command_version([str(executables["trealla"]), "--version"]),
                "executable": str(executables["trealla"]),
                "revision": git_revision(root),
            },
            "swi": {
                "version": command_version([str(executables["swi"]), "--version"]),
                "executable": str(executables["swi"]),
                "repository": str(args.swi_repository.resolve()),
                "revision": git_revision(args.swi_repository.resolve()),
            },
        },
        "results": results,
    }

    rendered = json.dumps(document, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
        print(f"wrote {args.output}")
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
