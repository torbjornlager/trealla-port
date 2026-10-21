#!/usr/bin/env python3
"""Run each trial in a fresh process; select matching TPL_LIBRARY_PATH."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("tpl", type=Path)
parser.add_argument("--runs", type=int, default=20)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
if args.runs < 1:
    parser.error("--runs must be positive")
exe = args.tpl.resolve()
source = Path(__file__).with_suffix(".pl").resolve()
quoted = "'" + str(source).replace("'", "''") + "'"
goal = ("(catch((consult(" + quoted + "),module_map_reproducer:run),"
        "E,(writeq(E),nl,halt(2)))->writeln(module_map_passed),halt;halt(1))")
version = subprocess.run([str(exe), "--version"], capture_output=True, text=True,
                         timeout=10)
rows = []
for trial in range(1, args.runs + 1):
    started = time.monotonic()
    try:
        result = subprocess.run([str(exe), "-g", goal], capture_output=True,
                                text=True, timeout=15)
        output = result.stdout + result.stderr
        status = ("passed" if result.returncode == 0 and
                  "module_map_passed" in result.stdout.splitlines()
                  else "signal" if result.returncode < 0 else "failed")
        row = dict(trial=trial, status=status, returncode=result.returncode,
                   output=output)
    except subprocess.TimeoutExpired:
        row = dict(trial=trial, status="timeout", returncode=None)
    row["seconds"] = round(time.monotonic() - started, 4)
    rows.append(row)
counts = {status: sum(row["status"] == status for row in rows)
          for status in ("passed", "signal", "failed", "timeout")}
report = dict(executable=str(exe), version=version.stdout.strip() or version.stderr.strip(),
              sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
              library_path=os.environ.get("TPL_LIBRARY_PATH"),
              platform=platform.platform(), counts=counts, runs=rows)
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"executable": str(exe), "counts": counts}), flush=True)
raise SystemExit(0 if counts["passed"] == args.runs else 1)
