import os,sys,time,json,subprocess,signal,hashlib
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests')
ENGINES={'candidate':BASE/'receive-handoff-2026-10-23/upstream/tpl','unmodified':BASE/'trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl'}
results=[]
for mode,count in [('diagnostic',100),('original',50)]:
 source=ROOT/'supervisor_intensity_tests.pl' if mode=='diagnostic' else OUT/'original_tests.pl'
 for i in range(1,count+1):
  for name,engine in ENGINES.items():
   env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library'))
   cmd=[str(engine),'-g',"consult('"+str(source)+"'),(catch(supervisor_intensity_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
   start=time.time();label=f'{mode}-{name}-{i:03}'
   with (OUT/(label+'.log')).open('w') as log:
    p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
    try:rc=p.wait(timeout=30)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
   result=dict(mode=mode,engine=name,trial=i,exit_code=rc,seconds=round(time.time()-start,3),log=label+'.log',command=cmd)
   results.append(result);(OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
   if rc!=0 or i%10==0:print(label,rc,flush=True)
print('FINISHED',len(results),'runs;',sum(r['exit_code']!=0 for r in results),'nonzero',flush=True)
