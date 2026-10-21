#!/usr/bin/env python3
"""Run the capture reproducer in fresh processes with matching Trealla libraries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tpl', type=Path)
parser.add_argument('--runs', type=int, default=20)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
exe = args.tpl.resolve()
source = Path(__file__).with_suffix('.pl').resolve()
env = os.environ.copy()
env['TPL_LIBRARY_PATH'] = str(exe.parent/'library')
quote = "'" + str(source).replace("'", "''") + "'"
goal = ("consult(" + quote + "),"
        "(catch(concurrent_output_capture:run,E,(writeq(E),nl,halt(2)))"
        "->halt;halt(1))")
version = subprocess.run([str(exe), '--version'], env=env, capture_output=True,
                         text=True, timeout=10)
rows = []
for n in range(1, args.runs+1):
    try:
        run = subprocess.run([str(exe), '-g', goal], env=env, capture_output=True,
                             text=True, timeout=15)
        status = ('reproduced' if run.returncode == 1 and
                  run.stdout.strip() == 'actual(betaomega,alpha)' and not run.stderr
                  else 'correct' if run.returncode == 0 and
                  run.stdout.strip() == 'actual(beta,alphaomega)' and not run.stderr
                  else 'unexpected')
        rows.append(dict(trial=n, status=status, returncode=run.returncode,
                         stdout=run.stdout, stderr=run.stderr))
    except subprocess.TimeoutExpired:
        rows.append(dict(trial=n, status='timeout', returncode=None))
counts = {status: sum(r['status'] == status for r in rows)
          for status in ('reproduced', 'correct', 'unexpected', 'timeout')}
report = dict(executable=str(exe), version=(version.stdout+version.stderr).strip(),
              executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
              reproducer_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              library_path=env['TPL_LIBRARY_PATH'], platform=platform.platform(),
              counts=counts, trials=rows)
args.output.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(counts))
raise SystemExit(0 if not counts['unexpected'] and not counts['timeout'] else 1)
