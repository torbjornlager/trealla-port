"""Bounded public-WebSocket comparison; fresh disposable native node per trial."""
import sys,os,json,subprocess,socket,time,importlib.util,argparse
from pathlib import Path
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('contracts',root.parent/'trinity-conformance/runner/run.py'); m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
p=argparse.ArgumentParser();p.add_argument('--engine',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--runs',type=int,default=3);p.add_argument('--source',action='store_true');a=p.parse_args()
rows=[]
for trial in range(1,a.runs+1):
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 url=f'http://127.0.0.1:{port}'; goal=f"consult(distribution),web_prolog:web_prolog_node({port},[bind_address('127.0.0.1'),node_url('{url}'),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
 row=dict(trial=trial,source=a.source,events=[]);log=a.output.with_name(a.output.stem+f'-{trial}-node.log')
 with log.open('w') as f:
  proc=subprocess.Popen([str(a.engine),'-g',goal],cwd=root,env=dict(os.environ,TPL_LIBRARY_PATH=str(a.engine.parent/'library')),stdout=f,stderr=f)
  try:
   for _ in range(100):
    if proc.poll() is not None:raise RuntimeError('node exited during startup')
    try:
     with socket.create_connection(('127.0.0.1',port),timeout=.1):break
    except OSError:time.sleep(.05)
   with m.Harness(m.Candidate(url.replace('http:','ws:')+'/ws','actor',15,None,None,False,())) as h:
    options='[session(true)]'
    if a.source:
     text=(root.parent/'trinity-demonstrator/examples/actors/06 ping-pong.pl').read_text()
     text=' '.join(line for line in text.splitlines() if not line.lstrip().startswith('%') and not line.lstrip().startswith('/**') and not line.lstrip().startswith('*/') and not line.lstrip().startswith('?-'))
     options="[session(true),src_text("+m.prolog_quote_atom(text)+")]"
    h.spawn_shell(options);row['stage']='shell_spawned'
    h.call("supervisor_spawn([child(waiter,[start(receive({stop -> true})),restart(temporary)])],Sup,[monitor(true)]),supervisor_count_children(Sup,Counts),supervisor_halt(Sup),receive({down(Sup,Sup,Reason)->true},[timeout(3),on_timeout(throw(missing_down))])")
    for _ in range(20):
     event=h.recv();row['events'].append(event)
     if event.get('type') in ['success','error','failure']:break
    row['stage']='reply';row['passed']=row['events'][-1]['type']=='success';h.halt()
  except Exception as e:row['error']=repr(e);row['passed']=False
  finally:
   row['node_exit_before_cleanup']=proc.poll()
   proc.terminate()
   try:proc.wait(timeout=3)
   except subprocess.TimeoutExpired:proc.kill();proc.wait()
   row['node_exit_after_cleanup']=proc.returncode
 rows.append(row);a.output.write_text(json.dumps(dict(engine=str(a.engine),results=rows),indent=2)+'\n');print(trial,row,flush=True)
