"""Fixed post-repair comparison; original parity assertions and timeouts."""
from pathlib import Path
import subprocess,socket,os,time,json,hashlib,signal
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
ENGINES={'pinned':ROOT/'.build/trealla-v3.13.10/tpl','v3.14.10':Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl'}
SWI=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
ROWS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def state():
 files=subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True).splitlines()
 return {'tracked_sha256':{f:sha(ROOT/f)for f in files if (ROOT/f).is_file()},'binaries':{str(p):sha(p)for p in [*ENGINES.values(),SWI,Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]},'live_processes':subprocess.check_output(['ps','-p','55051,42134,30612','-o','pid=,command='],text=True)}
BEFORE=state();(OUT/'before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
def client(port,goal,label):
 cmd=[str(SWI),'-q','-s',str(ROOT/'swi_websocket_interop.pl'),'-g',f'({goal}->halt;halt(1))']
 start=time.time()
 with (OUT/(label+'.log')).open('w') as log:
  c=subprocess.Popen(cmd,cwd=ROOT,stdout=log,stderr=log,start_new_session=True)
  try:rc=c.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(c.pid,signal.SIGKILL);c.wait();rc='watchdog_timeout'
 return {'command':cmd,'exit_code':rc,'started_at':start,'ended_at':time.time()}
for i in range(1,21):
 for prefixed in [False,True]:
  for name,exe in ENGINES.items():
   label=f'{name}-{"prefixed" if prefixed else "fresh"}-{i:02}'
   with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
   goal=f"consult(distribution),consult('{OUT/'node_probe.pl'}'),parity_node_probe:run({port})"
   row={'trial':i,'engine':name,'prefixed':prefixed,'port':port,'label':label}
   started=time.time()
   with (OUT/(label+'-node.log')).open('w') as log:
    p=subprocess.Popen([str(exe),'-g',goal],cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library')),stdout=log,stderr=log,text=True,start_new_session=True)
    def mark(stage):row.setdefault('stages',[]).append({'stage':stage,'time':time.time()})
    try:
     for _ in range(100):
      if p.poll()is not None:raise RuntimeError('node exited during startup')
      try:
       with socket.create_connection(('127.0.0.1',port),timeout=.1):break
      except OSError:time.sleep(.05)
     else:raise RuntimeError('node readiness timeout')
     if prefixed:
      mark('before_protocol');row['prefix']=client(port,f'protocol_client_test({port})',label+'-protocol');mark('after_protocol')
     mark('before_parity');row['parity']=client(port,f'connection_thread_parity_test({port})',label+'-parity');mark('after_parity')
     # Diagnostic observation only after original client has finished.
     time.sleep(.3);mark('later')
     observation_deadline=time.monotonic()+5
     while 'history(' not in (OUT/(label+'-node.log')).read_text() and time.monotonic()<observation_deadline:time.sleep(.005)
     row['observation_completed']='history(' in (OUT/(label+'-node.log')).read_text()
    except Exception as error:row['error']=repr(error)
    finally:
     if p.poll()is None:
      os.killpg(p.pid,signal.SIGTERM)
      try:p.wait(timeout=3)
      except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()

   ROWS.append(row);(OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(label,row.get('parity',{}).get('exit_code'),row.get('error',''),flush=True)
AFTER=state();AFTER['unchanged_from_batch_start']={k:AFTER[k]==BEFORE[k]for k in BEFORE};(OUT/'after.json').write_text(json.dumps(AFTER,indent=2)+'\n');print('COMPLETE',len(ROWS),flush=True)
