from pathlib import Path
import subprocess,os,json,signal,time
out=Path(__file__).resolve().parent;root=out.parents[1]
base=Path.home()/'.local/share/trinity-runtime-tests/setup-signal-repair-2026-10-23'
results=[]
for i in range(1,101):
 for name in ['candidate','unmodified']:
  exe=base/name/'tpl';env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
  label=f'{name}-{i:03}';cmd=[str(exe),'-g',f"consult('{out/'paging-tests.pl'}'),(catch(http_paging_cleanup_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
  start=time.monotonic()
  with (out/(label+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=root,env=env,stdout=log,stderr=log,start_new_session=True)
   try:rc=p.wait(timeout=30)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
  results.append(dict(engine=name,trial=i,exit_code=rc,seconds=round(time.monotonic()-start,3),command=cmd,log=label+'.log'))
  (out/'paging-results.json').write_text(json.dumps(results,indent=2)+'\n')
  if rc!=0 or i%20==0:print(label,rc,flush=True)
print('COMPLETE',len(results),'failures',sum(r['exit_code']!=0 for r in results),flush=True)
