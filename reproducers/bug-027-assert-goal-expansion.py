#!/usr/bin/env python3
"""Compare a standalone assertion reproducer and bounded regressions in separate engines."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
from datetime import datetime, timezone

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', action='append', required=True, help='LABEL=/absolute/path/to/tpl')
parser.add_argument('--upstream-checks', action='append', default=[], help='Engine LABEL with matching upstream tests/sundry tree')
parser.add_argument('--runs', type=int, default=20)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
root = Path(__file__).resolve().parents[1]
repro = root/'reproducers/bug-027-assert-goal-expansion.pl'
checks = root/'reproducers/bug-027-assert-goal-expansion-tests.pl'
quote = lambda p: "'"+str(p).replace("'","''")+"'"
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
report = dict(started_at=datetime.now(timezone.utc).isoformat(), platform=platform.platform(),
              inputs={p.name:digest(p) for p in [repro,checks]}, engines={})

def run(exe, goal=None, source=None, cwd=root):
    env = os.environ.copy()
    env['TPL_LIBRARY_PATH'] = str(exe.parent/'library')
    cmd = [str(exe), '-g', goal] if source is None else [str(exe), '-q', '-f', '-g', 'halt', str(source)]
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=60)
        return dict(returncode=r.returncode, stdout=r.stdout, stderr=r.stderr)
    except subprocess.TimeoutExpired:
        return dict(returncode=None, timeout=True)

for spec in args.engine:
    label, path = spec.split('=',1)
    exe = Path(path).resolve()
    entry = dict(executable=str(exe), executable_sha256=digest(exe),
                 library_path=str(exe.parent/'library'), trials=[], regressions=[])
    entry['version'] = run(exe, 'current_prolog_flag(version_data,V),writeq(V),nl,halt')
    report['engines'][label] = entry
    goal = f"consult({quote(repro)}),(catch(assert_goal_expansion_reproducer:run,E,(writeq(E),nl,fail))->halt;halt(1))"
    for n in range(1,args.runs+1):
        r = run(exe,goal)
        r['trial'] = n
        r['correct'] = r['returncode']==0 and r['stdout']=='first([a-a-a])\nground(ok)\nafter([a-a-b])\n' and not r['stderr']
        entry['trials'].append(r)
    entry['ground_controls'] = []
    for n in range(5):
        goal = f"consult({quote(repro)}),(assert_goal_expansion_reproducer:control->halt;halt(1))"
        r = run(exe,goal);r['correct'] = r['returncode']==0 and r['stdout']=='ground(ok)\n' and not r['stderr']
        entry['ground_controls'].append(r)
    print(label,'ground controls',sum(r['correct'] for r in entry['ground_controls']),'/5',flush=True)
    print(label,'standalone correct',sum(r['correct'] for r in entry['trials']),'/',args.runs,flush=True)
    for case in ['valid_a1','valid_z1','valid_a2','valid_z2','reject_a1','reject_z1','reject_a2','reject_z2']:
        goal=f"consult({quote(checks)}),(catch(assert_goal_expansion_checks:run({case}),E,(writeq(E),nl,fail))->halt;halt(1))"
        for n in range(1,4):
            r=run(exe,goal);r.update(case=case,trial=n)
            r['passed']=r['returncode']==0 and not r['stderr']
            entry['regressions'].append(r)
    print(label,'bounded regressions',sum(r['passed'] for r in entry['regressions']),'/24',flush=True)
    if label in args.upstream_checks:
        entry['port_groups']={}
        for group in ['isolation','sandbox','toplevel']:
            goal=f"consult({quote(root/'tests.pl')}),(catch(run_test_group({group}),E,(writeq(E),nl,fail))->halt;halt(1))"
            entry['port_groups'][group]=run(exe,goal)
        entry['upstream_tests']=[]
        for p in sorted((exe.parent/'tests/sundry').glob('*.pl')):
            text=p.read_text()
            selected=('asserta(' in text or 'assertz(' in text or 'goal_expansion(' in text or p.stem.startswith(('dcg','goal_expansion')) or p.stem in ['expand_term','meta_goal_module','meta_call_shares_terms','meta_qualify_call','term_variables_shared','backtrack_create_vars','listing_functor_vars'])
            if not selected:
                continue
            r=run(exe,source=p.relative_to(exe.parent),cwd=exe.parent)
            r['source']=str(p.relative_to(exe.parent));r['source_sha256']=digest(p)
            expected=p.with_suffix('.expected').read_text()
            r['passed']=r['returncode']==0 and r.get('stdout','').replace('\r\n','\n')==expected.replace('\r\n','\n')
            entry['upstream_tests'].append(r)
        print(label,'upstream selected',sum(r['passed'] for r in entry['upstream_tests']),'/',len(entry['upstream_tests']),flush=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
report['finished_at']=datetime.now(timezone.utc).isoformat()
args.output.write_text(json.dumps(report,indent=2)+'\n')
