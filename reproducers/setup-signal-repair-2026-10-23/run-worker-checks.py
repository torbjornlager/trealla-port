from pathlib import Path
import os,subprocess,json
out=Path(__file__).resolve().parent;root=out.parents[1];base=Path.home()/'.local/share/trinity-runtime-tests/setup-signal-repair-2026-10-23'
results=[]
for name in ['candidate','unmodified']:
 exe=base/name/'tpl';env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
 for module,goal in [('worker_scope_tests','worker_scope_tests:run'),('receive_handoff_tests','receive_handoff_tests:run' if name=='candidate' else 'receive_handoff_tests:semantics')]:
  cmd=[str(exe),'-g',f"(catch((consult('{root/(module+'.pl')}'),{goal}),E,(writeq(E),nl,fail))->halt;halt(1))"]
  try:
   p=subprocess.run(cmd,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30);rc=p.returncode;output=p.stdout
  except subprocess.TimeoutExpired as e:rc='timeout';output=str(e.stdout)
  result=dict(engine=name,goal=goal,command=cmd,exit_code=rc,output=output);results.append(result);print(result,flush=True)
(out/'worker-checks.json').write_text(json.dumps(results,indent=2)+'\n')
