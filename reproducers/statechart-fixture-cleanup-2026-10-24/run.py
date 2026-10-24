"""Fixed, fresh-process fixture-cleanup comparisons; no runtime installation."""
from pathlib import Path
import os,subprocess,json,hashlib,time,signal
OUT=Path(__file__).resolve().parent; ROOT=OUT.parents[1]
ENGINES={'pinned':ROOT/'.build/trealla-v3.13.10/tpl',
 'v3.14.10':Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl'}
ROWS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def live():return subprocess.check_output(['ps','-p','55051,42134,30612','-o','pid=,command='],text=True)
def sources():
 return {f:sha(ROOT/f) for f in subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True).splitlines() if (ROOT/f).is_file()}
BEFORE={'tracked_sha256':sources(),'engine_sha256':{k:sha(v)for k,v in ENGINES.items()},'live_processes':live(),
 'installed_swi_sha256':{str(p):sha(p)for p in [Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]}}
(OUT/'before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
for i in range(1,21):
 for suite,goal in [('policy','statechart_invocation_tests:behaviour_policy'),('full','statechart_invocation_tests:run')]:
  for engine,exe in ENGINES.items():
   label=f'{engine}-{suite}-{i:02}';cmd=[str(exe),'-g',f'consult(statechart_invocation_tests),(catch({goal},E,(writeq(E),nl,fail))->halt;halt(1))']
   start=time.monotonic()
   with (OUT/(label+'.log')).open('w') as log:
    p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library')),stdout=log,stderr=log,start_new_session=True)
    try:rc=p.wait(timeout=30)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
   ROWS.append(dict(engine=engine,suite=suite,trial=i,command=cmd,exit_code=rc,seconds=round(time.monotonic()-start,3),log=label+'.log'))
   (OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n')
   print(label,rc,flush=True)
AFTER={'tracked_sha256':sources(),'engine_sha256':{k:sha(v)for k,v in ENGINES.items()},'live_processes':live(),
 'installed_swi_sha256':{f:sha(Path(f))for f in BEFORE['installed_swi_sha256']}}
AFTER['unchanged_from_batch_start']={key:AFTER[key]==BEFORE[key] for key in BEFORE}
(OUT/'after.json').write_text(json.dumps(AFTER,indent=2)+'\n')
print('COMPLETE',len(ROWS),'failures',sum(r['exit_code']!=0 for r in ROWS),flush=True)
raise SystemExit(0 if all(r['exit_code']==0 for r in ROWS) else 1)
