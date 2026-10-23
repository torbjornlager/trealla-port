import subprocess,os,json,time,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];META=json.loads((OUT/'before.json').read_text());results=[]
for i in range(1,101):
 for name in ['candidate','unmodified']:
  engine=Path(META['binaries'][name]['path']);env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library'))
  cmd=[str(engine),'-g',"consult('"+str(OUT/'phase1-tests-control.pl')+"'),(catch(http_paging_cleanup_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
  label=f'{name}-{i:03}';start=time.time()
  with (OUT/(label+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
   try:rc=p.wait(timeout=30)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
  results.append(dict(engine=name,trial=i,exit_code=rc,seconds=round(time.time()-start,3),command=cmd,log=label+'.log'))
  (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
  if rc!=0 or i%10==0:print(label,rc,flush=True)
print('FINISHED',len(results),'runs;',sum(r['exit_code']!=0 for r in results),'nonzero',flush=True)
