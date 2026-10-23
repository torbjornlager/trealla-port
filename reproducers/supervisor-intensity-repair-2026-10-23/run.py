import os,sys,time,json,subprocess,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests')
ENGINES={'candidate':BASE/'receive-handoff-2026-10-23/upstream/tpl','unmodified':BASE/'trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl'}
SWIPL=BASE/'swipl-09b6299/build/src/swipl'
def run(label,engine,cmd,timeout):
 env=dict(os.environ,TPL=str(engine),TPL_LIBRARY_PATH=str(engine.parent/'library'),SWIPL=str(SWIPL),TEST_PORT_BASE='45760')
 start=time.time()
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 r=dict(label=label,command=cmd,exit_code=rc,seconds=round(time.time()-start,3),log=label+'.log')
 (OUT/(label+'.json')).write_text(json.dumps(r,indent=2)+'\n');return r
if sys.argv[1]=='fixed':
 results=[]
 for i in range(1,101):
  for name,engine in ENGINES.items():
   cmd=[str(engine),'-g',"consult('"+str(ROOT/'supervisor_intensity_tests.pl')+"'),(catch(supervisor_intensity_tests:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
   r=run(f'fixed-{name}-{i:03}',engine,cmd,30);r.update(engine=name,trial=i);results.append(r)
   (OUT/'fixed-results.json').write_text(json.dumps(results,indent=2)+'\n')
   if r['exit_code']!=0 or i%10==0:print(r['label'],r['exit_code'],flush=True)
 print('FINISHED',len(results),'runs;',sum(r['exit_code']!=0 for r in results),'nonzero',flush=True)
elif sys.argv[1]=='control':
 results=[]
 for variant in ['original','repaired']:
  source=ROOT/'reproducers/supervisor-intensity-investigation-2026-10-23/original_tests.pl' if variant=='original' else ROOT/'supervisor_intensity_tests.pl'
  for i in range(1,6):
   for name,engine in ENGINES.items():
    cmd=[str(engine),'-g',"consult('"+str(source)+"'),consult('"+str(OUT/'delayed-notification-control.pl')+"'),(catch(intensity_delayed_notification_control:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
    r=run(f'control-{variant}-{name}-{i}',engine,cmd,15);r.update(variant=variant,engine=name,trial=i);results.append(r);print(r['label'],r['exit_code'],flush=True)
 (OUT/'control-results.json').write_text(json.dumps(results,indent=2)+'\n')
elif sys.argv[1]=='unit':
 for name,engine in ENGINES.items():
  r=run('unit-'+name,engine,['sh','tools/test.sh','unit'],900);print(r['label'],r['exit_code'],flush=True)
