import subprocess,os,json,time
from pathlib import Path
out=Path(__file__).resolve().parent
base=Path.home()/'.local/share/trinity-runtime-tests/setup-signal-repair-2026-10-23'
results=[]
for i in range(1,51):
 for name in ['candidate','unmodified']:
  exe=base/name/'tpl'; env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
  cmd=[str(exe),'-g',f"consult('{out.parent/'mutex-retention-standalone-2026-10-23/probe.pl'}'),(catch(mutex_retention_probe:run,E,(writeq(top_error(E)),nl,halt(3)))->halt;halt(4))"]
  try:
   p=subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=5)
   rc=p.returncode; log=p.stdout
  except subprocess.TimeoutExpired as e: rc='timeout';log=str(e.stdout)
  results.append(dict(engine=name,trial=i,exit_code=rc,output=log))
  (out/'mutex-results.json').write_text(json.dumps(results,indent=2)+'\n')
print({name:{str(rc):sum(r['engine']==name and r['exit_code']==rc for r in results) for rc in set(r['exit_code'] for r in results)} for name in ['candidate','unmodified']})
