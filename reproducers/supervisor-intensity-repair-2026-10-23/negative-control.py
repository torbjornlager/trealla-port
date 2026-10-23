import json,os,subprocess
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests')
source=ROOT/'reproducers/supervisor-intensity-investigation-2026-10-23/diagnostic-tests-control.pl'
engines={'candidate':BASE/'receive-handoff-2026-10-23/upstream/tpl','unmodified':BASE/'trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl'}
results=[]
for name,engine in engines.items():
 for i in range(1,6):
  goal="consult('"+str(source)+"'),consult('"+str(OUT/'delayed-notification-control.pl')+"'),(catch(intensity_delayed_notification_control:run,E,true),E==intensity_assertion_failed(extra_supervisor_down)->writeln(expected_zero_time_failure_confirmed),halt;halt(1))"
  cmd=[str(engine),'-g',goal]
  r=subprocess.run(cmd,env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library')),capture_output=True,text=True,timeout=15)
  results.append(dict(engine=name,trial=i,command=cmd,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr))
(OUT/'negative-control-results.json').write_text(json.dumps(results,indent=2)+'\n');print([(r['engine'],r['trial'],r['exit_code']) for r in results])
