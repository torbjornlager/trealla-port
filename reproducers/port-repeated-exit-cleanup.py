#!/usr/bin/env python3
"""Observe repeated exit requests during at_exit on separate Trealla builds."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', action='append', required=True, help='LABEL=/path/to/tpl')
parser.add_argument('--runs', type=int, default=20)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
source = Path(__file__).with_suffix('.pl').resolve()
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
quote = lambda p: "'"+str(p).replace("'", "''")+"'"
report = dict(started_at=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
              source=str(source), source_sha256=sha(source), engines={})
for spec in args.engine:
    label, value = spec.split('=', 1)
    exe = Path(value).resolve()
    env = dict(os.environ, TPL_LIBRARY_PATH=str(exe.parent/'library'))
    entry = dict(executable=str(exe), executable_sha256=sha(exe),
                 library_path=env['TPL_LIBRARY_PATH'], trials={})
    report['engines'][label] = entry
    def run(goal):
        try:
            r = subprocess.run([str(exe), '-g', goal], env=env, capture_output=True,
                               text=True, timeout=4)
            return dict(returncode=r.returncode, stdout=r.stdout, stderr=r.stderr)
        except subprocess.TimeoutExpired as error:
            return dict(returncode=None, timeout=True,
                        stdout=(error.stdout or b'').decode(errors='replace'),
                        stderr=(error.stderr or b'').decode(errors='replace'))
    entry['version'] = run('current_prolog_flag(version_data,V),writeq(V),nl,halt')
    git = subprocess.run(['git','-C',str(exe.parent),'rev-parse','HEAD'],capture_output=True,text=True)
    entry['source_revision'] = git.stdout.strip() if git.returncode == 0 else None
    for policy, expected_code, expected_output in [
        ('withdraw',1,'missing_cleanup(withdraw,second_request(true),reason_recorded(yes))\n'),
        ('retain',0,'completed(retain,second_request(false))\n')]:
        trials = []
        for n in range(1, args.runs+1):
            result = run(f'consult({quote(source)}),(repeated_exit_cleanup:run({policy})->halt;halt(1))')
            result.update(trial=n, matches_expected=(result['returncode']==expected_code
                          and result['stdout']==expected_output and not result['stderr']))
            trials.append(result)
        entry['trials'][policy] = trials
        print(label, policy, sum(r['matches_expected'] for r in trials), '/', args.runs,
              'matched expected observation', flush=True)
report['finished_at'] = datetime.now(timezone.utc).isoformat()
args.output.write_text(json.dumps(report,indent=2)+'\n')
# Exit success means every recorded observation matched its stated expectation.
raise SystemExit(0 if all(r['matches_expected'] for e in report['engines'].values()
                          for trials in e['trials'].values() for r in trials) else 1)
