from pathlib import Path
import os,json,subprocess,shutil,socket,time,signal,sys,hashlib
from urllib.request import urlopen
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');STATE=Path.home()/'.local/share/trinity-local-nodes';OLD=STATE/'portable-text-live-2026-10-25';NEW=STATE/'shared-shadow-dispatch-2026-10-25';OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(BASE/'trinity-conformance/runner'));import run as wire
NEW.mkdir();shutil.copy2(STATE/'n5/start.sh',NEW/'rollback.sh');shutil.copytree(OLD/'trealla-source',NEW/'trealla-source');shutil.copy2(BASE/'trealla-port/isolation.pl',NEW/'trealla-source/isolation.pl')
text='\n'.join('cd '+str(NEW/'trealla-source') if line.startswith('cd ') else line for line in (STATE/'n5/start.sh').read_text().splitlines())+'\n';start=NEW/'start.sh';start.write_text(text);start.chmod(0o755)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def ready(port,p):
 for _ in range(100):
  if p.poll() is not None:raise RuntimeError('startup exit')
  try:
   with urlopen(f'http://localhost:{port}/node_info',timeout=.5) as r:return json.load(r)
  except Exception:time.sleep(.1)
 raise RuntimeError('startup timeout')
def launch(path,log):
 with log.open('ab',buffering=0) as f:return subprocess.Popen([str(path)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
def check(port):
 source=(BASE/'trinity-demonstrator/examples/actors/06 ping-pong.pl').read_text();quote="'"+source.replace('\\','\\\\').replace('\r','\\r').replace('\n','\\n').replace('\t','\\t').replace("'","''")+"'"
 events=[]
 with wire.Harness(wire.Candidate(f'ws://localhost:{port}/ws','actor',10,None,f'http://localhost:{port}',False,())) as h:
  h.send(dict(command='transport_hello',version=1,io_ack=True,answer_terms=False));h.recv()
  h.spawn_shell('[session(true),src_text('+quote+')]');h.call('ping_pong,Outcome=ok','[template(Outcome),format(prolog),limit(1)]')
  for _ in range(60):
   e=h.recv();events.append(e)
   if e.get('type')=='io_request':h.send(dict(command='browser_io_reply',request_id=e['request_id'],status='ok'))
   if any(x.get('data')==['ok'] for x in events) and all(any(msg in str(x) for x in events) for msg in ['Ping finished.','Pong finished.']):break
  else:raise RuntimeError(events)
  h.halt()
 return events
with urlopen('http://localhost:3062/node_info') as r:info=json.load(r)
protected=subprocess.check_output(['ps','-p','8855,91509,97669','-o','pid=,lstart=,command='],text=True);exe=BASE/'trealla-port/.build/trealla-current/tpl';engine=sha(exe)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
pf=NEW/'preflight.sh';pf.write_text(text.replace('web_prolog_node(3062,',f'web_prolog_node({port},'));pf.chmod(0o755);p=launch(pf,NEW/'preflight.log')
try:assert ready(port,p)==info;events=check(port);(OUT/'preflight-events.json').write_text(json.dumps(events,indent=2)+'\n')
finally:
 if p.poll() is None:p.terminate();p.wait(timeout=10)
command=subprocess.check_output(['ps','-p','10267','-o','command='],text=True);assert str(OLD/'trealla-source') not in command # cwd is not in the command
assert 'web_prolog_node(3062,' in command
os.kill(10267,signal.SIGTERM)
for _ in range(80):
 if subprocess.run(['ps','-p','10267'],stdout=subprocess.DEVNULL).returncode:break
 time.sleep(.1)
else:raise RuntimeError('old backend did not stop')
shutil.copy2(start,STATE/'n5/start.sh');p=launch(STATE/'n5/start.sh',STATE/'n5/n5.log')
try:
 assert ready(3062,p)==info;events=check(3060);(STATE/'n5/n5.pid').write_text(str(p.pid)+'\n')
except Exception:
 if p.poll() is None:p.terminate();p.wait(timeout=10)
 shutil.copy2(NEW/'rollback.sh',STATE/'n5/start.sh');rollback=launch(STATE/'n5/start.sh',STATE/'n5/n5.log');ready(3062,rollback);(STATE/'n5/n5.pid').write_text(str(rollback.pid)+'\n');raise
assert protected==subprocess.check_output(['ps','-p','8855,91509,97669','-o','pid=,lstart=,command='],text=True);assert sha(exe)==engine
(OUT/'live-events.json').write_text(json.dumps(events,indent=2)+'\n');(OUT/'restart.json').write_text(json.dumps(dict(old_pid=10267,new_pid=p.pid,configuration_preserved=True,protected_processes=protected,engine_sha256=engine,isolation_sha256=sha(NEW/'trealla-source/isolation.pl'),snapshot=str(NEW)),indent=2)+'\n');print('n5 ping-pong passed; new PID',p.pid)
