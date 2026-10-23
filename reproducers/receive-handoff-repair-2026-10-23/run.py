#!/usr/bin/env python3
"""Fixed acceptance batches; exact binaries, process-group watchdogs, saved outcomes."""
import hashlib,json,os,signal,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
base=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/receive-handoff-2026-10-23')
results={}
def run(label,exe,goal,marker,limit=30):
 env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'),WORKER_SCOPE_DIAGNOSTICS='failure')
 cmd=[str(exe),'-g',goal];start=time.monotonic()
 p=subprocess.Popen(cmd,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:stdout,stderr=p.communicate(timeout=limit);expired=False
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGKILL);stdout,stderr=p.communicate();expired=True
 row=dict(command=cmd,engine_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),exit_code=p.returncode,timeout=expired,seconds=round(time.monotonic()-start,3),stdout=stdout,stderr=stderr,passed=p.returncode==0 and not expired and not stderr and marker in stdout and 'finding(' not in stdout)
 results[label]=row;(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
 print(label,'PASS' if row['passed'] else 'FAIL',flush=True)
 return row['passed']
def goal(file,entry):
 return f"(catch((consult('{file}'),{entry}),E,(writeq(E),nl,fail))->halt;halt(1))"
for engine in ['pinned','upstream']:
 exe=base/engine/'tpl'
 run(engine+'-primitive',exe,goal('reproducers/receive-handoff-repair-2026-10-23/primitive_tests.pl','receive_saved_primitive_tests:run'),'Saved receive primitive: all regressions passed')
 run(engine+'-handoff',exe,goal('receive_handoff_tests.pl','receive_handoff_tests:run'),'Receive handoff: all regressions passed')
 for mode,entry in [('adapter','run'),('native','run_native')]:
  for trial in range(1,6):
   run(f'{engine}-{mode}-{trial}',exe,goal('reproducers/receive-interruption-2026-10-23/probe.pl','receive_interruption_probe:'+entry),'probe_complete')
 for trial in range(1,101):
  run(f'{engine}-workers-{trial}',exe,goal('worker_scope_tests.pl','worker_scope_tests:run'),'Worker scopes: all regressions passed')
print('SUMMARY',sum(r['passed'] for r in results.values()),'/',len(results),flush=True)
