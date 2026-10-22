#!/usr/bin/env python3
"""Fresh-process checks for thread-time module creation; engines stay separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine', action='append', required=True, help='LABEL=/path/to/tpl')
p.add_argument('--runs', type=int, default=20)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if a.runs < 1:
    p.error('--runs must be positive')
source = Path(__file__).with_suffix('.pl').resolve()
quote = lambda s: "'"+str(s).replace("'","''")+"'"
report = dict(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), engines={})
for spec in a.engine:
    label,path = spec.split('=',1)
    exe = Path(path).resolve()
    env = dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
    entry = dict(executable=str(exe),executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                 library=env['TPL_LIBRARY_PATH'],cases={})
    for case in ['load_new','load_existing','module_new','module_existing','command_load','command_module']:
        expected = f'passed({case})\n'
        if case == 'command_load':
            expected = "Info: created module 'tmc_command'\n"+expected
        if case == 'command_module':
            expected = "Info: created module 'tmc_command_switch'\n"+expected
        rows = []
        goal = (f"consult({quote(source)}),"
                f"(catch(thread_module_creation_reproducer:run({case}),"
                "E,(writeq(E),nl,halt(1)))->halt;halt(1))")
        for trial in range(1,a.runs+1):
            try:
                r = subprocess.run([str(exe),'-g',goal],env=env,capture_output=True,text=True,timeout=5)
                row = dict(trial=trial,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr,
                           passed=r.returncode==0 and r.stdout==expected and not r.stderr)
            except subprocess.TimeoutExpired as e:
                def decoded(v):
                    return v.decode(errors='replace') if isinstance(v,bytes) else v or ''
                row = dict(trial=trial,timeout=True,passed=False,stdout=decoded(e.stdout),stderr=decoded(e.stderr))
            rows.append(row)
        entry['cases'][case] = rows
        print(label,case,sum(r['passed'] for r in rows),'/',len(rows),flush=True)
    report['engines'][label] = entry
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(report,indent=2)+'\n')
# This is a comparison runner: retained baseline crashes do not become passes.
