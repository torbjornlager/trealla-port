from pathlib import Path
import os,subprocess,json,time,signal,urllib.request,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];EXE=ROOT/'.build/trealla-v3.14.10/tpl';ROWS=[]
def run(name,cmd):
 start=time.monotonic()
 with (OUT/(name+'.log')).open('w')as log:
  p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(EXE.parent/'library')),stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 ROWS.append({'name':name,'command':cmd,'exit_code':rc,'seconds':round(time.monotonic()-start,3)});(OUT/'smoke-results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(name,rc,flush=True)
 return rc
assert run('public-n5-smoke',[str(EXE),'-g',f"consult('{OUT}/public-smoke.pl'),(catch(public_update_smoke:run,E,(writeq(E),nl,fail))->halt;halt(1))"])==0
versions={}
for port in [3060,3061,3062]:
 with urllib.request.urlopen(f'http://localhost:{port}/version',timeout=5)as r:versions[str(port)]=json.load(r);assert versions[str(port)]['trealla']=='3.14.10'
(OUT/'live-versions.json').write_text(json.dumps(versions,indent=2)+'\n')
