import subprocess,os,json,time
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests')
engines={'candidate':BASE/'receive-handoff-2026-10-23/upstream/tpl','unmodified':BASE/'trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl'}
results=[]
for name,engine in engines.items():
 for i in range(5):
  env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library'))
  cmd=[str(engine),'-g',"consult('"+str(OUT/'supervisor_intensity_probe.pl')+"'),(catch(supervisor_intensity_acceptance_probe:run,E,(writeq(E),nl,fail))->halt;halt(1))"]
  start=time.time()
  try:
   r=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,text=True,timeout=30);result=dict(engine=name,trial=i+1,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr,seconds=round(time.time()-start,3))
  except subprocess.TimeoutExpired as e:result=dict(engine=name,trial=i+1,exit_code='timeout',stdout=str(e.stdout),stderr=str(e.stderr))
  results.append(result);print(name,i+1,result['exit_code'],result['stdout'][-250:],flush=True)
  (OUT/'intensity-probe-results.json').write_text(json.dumps(results,indent=2)+'\n')
