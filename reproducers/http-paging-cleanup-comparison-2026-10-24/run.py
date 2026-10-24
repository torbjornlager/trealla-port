"""Fixed 100-trial fresh-process comparison per engine; no retry or installation."""
from pathlib import Path
import os,subprocess,json,hashlib,time,signal
OUT=Path(__file__).resolve().parent; ROOT=OUT.parents[1]
ENGINES={'pinned':ROOT/'.build/trealla-v3.13.10/tpl', 'v3.14.10':Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl'}
ROWS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def live():return subprocess.check_output(['ps','-p','55051,42134,30612','-o','pid=,command='],text=True)
def snapshot():
 files=[p for p in ROOT.rglob('*.pl') if '.build'not in p.parts and '.git'not in p.parts]+[ROOT/'README.md',ROOT/'tools/test.sh']
 return {'source_sha256':{str(p.relative_to(ROOT)):sha(p)for p in files},'engine_sha256':{k:sha(v)for k,v in ENGINES.items()},'live_processes':live(),'installed_swi_sha256':{str(p):sha(p)for p in [Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]}}
BEFORE=snapshot();(OUT/'before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
(OUT/'engines.json').write_text(json.dumps({k:{'executable':str(v),'library':str(v.parent/'library'),'version':subprocess.check_output([str(v),'-g','current_prolog_flag(version_data,V),writeq(V),nl,halt'],env=dict(os.environ,TPL_LIBRARY_PATH=str(v.parent/'library')),text=True).strip()}for k,v in ENGINES.items()},indent=2)+'\n')
for i in range(1,101):
 for engine,exe in ENGINES.items():
  label=f'{engine}-{i:03}';cmd=[str(exe),'-g',f"(catch((consult('{ROOT}/http_paging_cleanup_tests.pl'),http_paging_cleanup_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))"]
  start=time.monotonic()
  with (OUT/(label+'.log')).open('w')as log:
   p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library')),stdout=log,stderr=log,start_new_session=True)
   try:rc=p.wait(timeout=30)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
  text=(OUT/(label+'.log')).read_text(errors='replace');stages=[line for line in text.splitlines()if line.startswith('paging_stage(')]
  ROWS.append(dict(engine=engine,trial=i,command=cmd,exit_code=rc,seconds=round(time.monotonic()-start,3),log=label+'.log',last_stage=stages[-1]if stages else None,diagnostics=[line for line in text.splitlines()if line.startswith(('paging_failure(','page_assertion_failed(','registry_snapshot(','cache_snapshot('))]))
  (OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n')
  if rc!=0 or i%10==0:print(label,rc,ROWS[-1]['last_stage'],flush=True)
AFTER=snapshot();AFTER['unchanged_from_batch_start']={key:AFTER[key]==BEFORE[key]for key in BEFORE};(OUT/'after.json').write_text(json.dumps(AFTER,indent=2)+'\n')
summary={engine:{'trials':sum(r['engine']==engine for r in ROWS),'passed':sum(r['engine']==engine and r['exit_code']==0 for r in ROWS),'failed':[r for r in ROWS if r['engine']==engine and r['exit_code']!=0]}for engine in ENGINES}
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print('COMPLETE',json.dumps(summary),flush=True)
