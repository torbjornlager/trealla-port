import sys,subprocess,json,time,os
from pathlib import Path
label,cwd,out,*cmd=sys.argv[1:]; out=Path(out);start=time.time()
with out.with_suffix('.log').open('w') as log:
 try:
  p=subprocess.run(cmd,cwd=cwd,env=os.environ,stdout=log,stderr=log,timeout=1800);rc=p.returncode
 except subprocess.TimeoutExpired:rc='timeout'
out.with_suffix('.json').write_text(json.dumps(dict(label=label,command=cmd,cwd=cwd,exit_code=rc,seconds=round(time.time()-start,3)),indent=2)+'\n')
print(label,rc,round(time.time()-start,2),flush=True)
