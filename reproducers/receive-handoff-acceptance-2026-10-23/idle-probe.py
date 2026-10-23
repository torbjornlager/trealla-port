import subprocess,resource,json,time
from pathlib import Path
OUT=Path(__file__).resolve().parent
SWI='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl'
results=[]
for mode in ['native','adapter','native','adapter']:
 before=resource.getrusage(resource.RUSAGE_CHILDREN); start=time.time()
 r=subprocess.run([SWI,'-f','none','-q','-s',str(OUT/'idle-probe.pl'),'-g','run('+mode+'),halt'],capture_output=True,text=True,timeout=10)
 after=resource.getrusage(resource.RUSAGE_CHILDREN)
 results.append(dict(mode=mode,exit_code=r.returncode,wall_seconds=round(time.time()-start,4),cpu_seconds=round(after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime,4),stdout=r.stdout,stderr=r.stderr))
(OUT/'idle-probe.json').write_text(json.dumps(results,indent=2)+'\n');print(results)
