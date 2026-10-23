from pathlib import Path
import subprocess,os,json
out=Path(__file__).resolve().parent
base=Path.home()/'.local/share/trinity-runtime-tests/setup-signal-repair-2026-10-23'
results=[]
for name in ['candidate','unmodified']:
 exe=base/name/'tpl';env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
 cases=[('semantics',out/'setup-regressions.pl','setup_signal_regressions:run')]+[(m,out/'mutex-controls.pl',f'mutex_retention_controls:run({m})') for m in ['blocked','normal','body']]
 for label,file,goal in cases:
  cmd=[str(exe),'-g',f"consult('{file}'),(catch(({goal}),E,(writeq(E),nl,halt(3)))->halt;halt(4))"]
  p=subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
  r=dict(engine=name,case=label,exit_code=p.returncode,output=p.stdout);results.append(r);print(r,flush=True)
(out/'initial-checks.json').write_text(json.dumps(results,indent=2)+'\n')
