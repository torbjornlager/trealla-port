#!/usr/bin/env python3
"""Exact-output checks for #1177 against an explicitly selected upstream build."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args(); engine=a.engine.resolve(); base=engine.parent
env=dict(os.environ,TPL_LIBRARY_PATH=str(base/'library'))
r={'engine':str(engine),'sha256':hashlib.sha256(engine.read_bytes()).hexdigest(),'results':[]}
for name,folder,count in [('thread_module_creation','misc',20)]+[(x,'sundry',1) for x in ['temporary_module','module_qualifier_errors','meta_goal_module','retract_module_scope','op_module_visibility']]:
    source=base/'tests'/folder/(name+'.pl')
    expected=source.with_suffix('.expected').read_text()
    for trial in range(1,count+1):
        try:
            c=subprocess.run([str(engine),'-q','-f','-g','halt',str(source)],cwd=base,env=env,capture_output=True,text=True,timeout=60)
            row=dict(test=name,trial=trial,exit_code=c.returncode,stdout=c.stdout,stderr=c.stderr,expected=expected,passed=c.returncode==0 and c.stdout==expected and not c.stderr)
        except subprocess.TimeoutExpired as e:
            dec=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
            row=dict(test=name,trial=trial,timeout=True,stdout=dec(e.stdout),stderr=dec(e.stderr),passed=False)
        r['results'].append(row)
        a.output.write_text(json.dumps(r,indent=2)+'\n')
    print(name,sum(x['passed'] for x in r['results'] if x['test']==name),'/',count,flush=True)
raise SystemExit(0 if all(x['passed'] for x in r['results']) else 1)
