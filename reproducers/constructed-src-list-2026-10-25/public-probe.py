from pathlib import Path
import subprocess,tempfile,os,json,sys,signal,time,socket
root=Path('/Users/torbjorn.lager/Documents/GitHub/trealla-port');out=root/'reproducers/constructed-src-list-2026-10-25'
sys.path.insert(0,str(root.parent/'trinity-conformance/runner'))
from run import Candidate,Harness
sys.path.insert(0,str(root.parent/'trinity-conformance/adapters'))
from local_promises import free_port
engine=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine')
original=next(c['goal'] for c in json.loads((root.parent/'trinity-conformance/cases/portable-text-0.2.json').read_text())['cases'] if c['id']=='TXT-014')
deferred=original.replace('self(Parent),spawn(', 'Options=[src_list(Clauses),monitor(true)],self(Parent),spawn(').replace('P,[src_list(Clauses),monitor(true)])','P,Options)')
cases=[('original_TXT_014',original),('same_assertions_runtime_options_control',deferred),('literal_control','spawn(p(ok),P,[src_list([p(ok)]),monitor(true)]),receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(missing_child_down))])'),('outer_catch_runtime_source','catch((C=[p(ok)],spawn(true,P,[src_list(C)])),E,true)'),('invalid_runtime_list','O=[src_list(C)],catch(spawn(true,P,O),E,true),nonvar(E),var(C),var(P)')]
records=[]
with tempfile.TemporaryDirectory(prefix='trealla-src-list-public-') as tmp:
    tmp=Path(tmp)
    for name in subprocess.check_output(['git','-C',str(root),'ls-tree','--name-only','HEAD'],text=True).splitlines():
        if name.endswith('.pl'):(tmp/name).write_bytes(subprocess.check_output(['git','-C',str(root),'show','HEAD:'+name]))
    port=free_port();goal=f"use_module(web_prolog),use_module(distribution),web_prolog:web_prolog_node({port},[bind_address('127.0.0.1'),node_url('http://127.0.0.1:{port}'),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
    cmd=[str(engine/'tpl'),'-g',goal]
    with (out/'node.log').open('w') as log:
        proc=subprocess.Popen(cmd,cwd=tmp,env=dict(os.environ,TPL_LIBRARY_PATH=str(engine/'library')),stdout=log,stderr=log,start_new_session=True)
        try:
            for _ in range(150):
                if proc.poll() is not None:raise RuntimeError('fixture startup failed')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                except OSError:time.sleep(.05)
            else:raise TimeoutError('fixture startup')
            candidate=Candidate(f'ws://127.0.0.1:{port}/ws','actor',5,None,None,False,())
            for label,q in cases:
                with Harness(candidate) as h:
                    h.spawn_shell('[session(true)]')
                    try:
                        h.call(q,'[limit(1)]');answer=h.recv();records.append(dict(label=label,goal=q,reply=answer));print(label,answer,flush=True)
                    finally:h.halt()
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
            (out/'public-results.json').write_text(json.dumps(dict(revision=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),command=cmd,pid=proc.pid,stopped=proc.poll() is not None,records=records),indent=2)+'\n')
