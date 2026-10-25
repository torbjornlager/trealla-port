from pathlib import Path
import sys,subprocess,shutil,json,signal,os,time,socket,hashlib
from urllib.request import urlopen
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(BASE/'trinity-conformance/adapters'));import write_output as tests
STATE=Path.home()/'.local/share/trinity-local-nodes';NEW=STATE/'write-output-2026-10-25';NEW.mkdir(exist_ok=False)
old_script=(STATE/'n5/start.sh').read_text();old_source=STATE/'code-restart-2026-10-25/trealla-active-source';new_source=NEW/'trealla-active-source'
assert str(old_source) in old_script
shutil.copytree(old_source,new_source);shutil.copy2(BASE/'trealla-port/sandbox_policy.pl',new_source/'sandbox_policy.pl')
shutil.copy2(STATE/'n5/start.sh',NEW/'rollback-start.sh')
with urlopen('http://localhost:3060/node_info',timeout=5) as r:before=json.load(r)
protected=subprocess.check_output(['ps','-p','91992,91509,97669','-o','pid=,lstart=,command='],text=True)
engine=BASE/'trealla-port/.build/trealla-current/tpl';engine_hash=hashlib.sha256(engine.read_bytes()).hexdigest()
new_script=old_script.replace(str(old_source),str(new_source));(NEW/'start.sh').write_text(new_script);(NEW/'start.sh').chmod(0o755)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
preflight=new_script.replace('web_prolog_node(3062,',f'web_prolog_node({port},');(NEW/'preflight.sh').write_text(preflight);(NEW/'preflight.sh').chmod(0o755)
def start(script,log):
 with log.open('ab',buffering=0) as f:return subprocess.Popen([str(script)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
def ready(proc,url):
 for _ in range(100):
  if proc.poll() is not None:raise RuntimeError('backend exited')
  try:
   with urlopen(url+'/node_info',timeout=.5) as r:info=json.load(r)
   assert info==before;return
  except Exception:time.sleep(.1)
 raise RuntimeError('readiness timeout')
p=start(NEW/'preflight.sh',NEW/'preflight.log')
try:
 ready(p,f'http://localhost:{port}')
 rows=tests.checks(f'http://localhost:{port}','trealla');assert all(x['passed'] for x in rows)
 (OUT/'preflight.json').write_text(json.dumps(rows,indent=2)+'\n')
finally:p.terminate();p.wait(timeout=8)
old_pid=int((STATE/'n5/n5.pid').read_text());assert 'web_prolog_node(3062,' in subprocess.check_output(['ps','-p',str(old_pid),'-o','command='],text=True)
os.kill(old_pid,signal.SIGTERM)
for _ in range(80):
 try:os.kill(old_pid,0)
 except ProcessLookupError:break
 time.sleep(.1)
else:raise RuntimeError('old n5 did not stop')
shutil.copy2(NEW/'start.sh',STATE/'n5/start.sh');p=start(STATE/'n5/start.sh',STATE/'n5/n5.log');(STATE/'n5/n5.pid').write_text(str(p.pid)+'\n');ready(p,'http://localhost:3060')
rows=tests.checks('http://localhost:3060','trealla');assert all(x['passed'] for x in rows)
(OUT/'live-n5.json').write_text(json.dumps(rows,indent=2)+'\n')
assert subprocess.check_output(['ps','-p','91992,91509,97669','-o','pid=,lstart=,command='],text=True)==protected
assert hashlib.sha256(engine.read_bytes()).hexdigest()==engine_hash
(OUT/'deployment.json').write_text(json.dumps(dict(old_pid=old_pid,new_pid=p.pid,node_info=before,configuration_identical=True,engine_hash=engine_hash,engine_unchanged=True,protected_processes=protected,protected_processes_unchanged=True,active_source=str(new_source),sandbox_policy_sha256=hashlib.sha256((new_source/'sandbox_policy.pl').read_bytes()).hexdigest(),rollback=str(NEW/'rollback-start.sh')),indent=2)+'\n')
print('n5 updated and verified',p.pid,flush=True)
