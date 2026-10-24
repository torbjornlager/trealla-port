"""Fixed captured native comparisons; no engine or runtime source changes."""
from pathlib import Path
import os,sys,subprocess,socket,time,signal,json,hashlib,importlib.util
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
SWI=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
NODE=ROOT.parent/'trinity-demonstrator/prolog/web_prolog/node.pl'
ENGINES={'pinned':ROOT/'.build/trealla-v3.13.10/tpl','v3.14.10':Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl'}
spec=importlib.util.spec_from_file_location('wire',OUT/'analyze_wire.py');wire=importlib.util.module_from_spec(spec);spec.loader.exec_module(wire)
ROWS=[]
def port():
 with socket.socket()as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def state():
 files=subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True).splitlines()
 return {'sources':{f:sha(ROOT/f)for f in files if (ROOT/f).is_file()},'binaries':{str(p):sha(p)for p in [*ENGINES.values(),SWI,Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]},'live_processes':subprocess.check_output(['ps','-p','55051,42134,30612','-o','pid=,command='],text=True)}
BEFORE=state();(OUT/'before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
def stop(p):
 if p.poll()is None:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=4)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
def client(exe,goal,log):
 cmd=[str(exe),'-g',f'({goal}->halt;halt(1))'];start=time.time()
 with log.open('w')as f:
  p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library')),stdout=f,stderr=f,start_new_session=True)
  try:rc=p.wait(timeout=30)
  except subprocess.TimeoutExpired:stop(p);rc='watchdog_timeout'
 return {'command':cmd,'exit_code':rc,'started_at':start,'ended_at':time.time()}
for trial in range(1,21):
 for prefixed in [False,True]:
  for name,exe in ENGINES.items():
   label=f'{name}-{"prefixed" if prefixed else "isolated"}-{trial:02}';folder=OUT/label;folder.mkdir(exist_ok=True);back=port();front=port();row={'label':label,'trial':trial,'engine':name,'prefixed':prefixed,'backend_port':back,'proxy_port':front,'prefixes':[]};logs=[];procs=[]
   try:
    goal=f"use_module(library(sgml)),use_module(library(option)),use_module('{NODE}'),set_setting(http:public_host,localhost),set_setting(http:public_port,{front}),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):{back}),tcp_listen(Socket,128),node:node({back},[tcp_socket(Socket),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
    log=(folder/'swi-node.log').open('w');logs.append(log);node=subprocess.Popen([str(SWI),'-f','none','-q','-g',goal],cwd=ROOT,stdout=log,stderr=log,start_new_session=True);procs.append(node)
    for _ in range(100):
     if node.poll()is not None:raise RuntimeError('SWI node exited at startup')
     try:
      with socket.create_connection(('127.0.0.1',back),timeout=.1):break
     except OSError:time.sleep(.05)
    else:raise RuntimeError('SWI readiness timeout')
    log=(folder/'proxy.log').open('w');logs.append(log);proxy=subprocess.Popen([sys.executable,str(OUT/'capture_proxy.py'),str(folder/'wire'),str(back),str(front)],stdout=log,stderr=log,start_new_session=True);procs.append(proxy)
    for _ in range(100):
     if proxy.poll()is not None:raise RuntimeError('proxy exited at startup')
     if '"ready": true' in (folder/'proxy.log').read_text():break
     time.sleep(.01)
    else:raise RuntimeError('proxy readiness timeout')
    if prefixed:
     for prefix,g in [('canonical',f'consult(distribution_tests),canonical_outbound_test({front})'),('named',f'consult(remote_named_tests),remote_named_tests:remote_named_live_test({front})'),('supervisor',f'consult(remote_supervisor_tests),remote_supervisor_tests:remote_supervisor_live_test({front})'),('alias',f'consult(remote_alias_tests),remote_alias_tests:remote_alias_live_test({front})')]:
      r=client(exe,g,folder/(prefix+'.log'));r['prefix']=prefix;row['prefixes'].append(r)
    row['target']=client(exe,f'consult(distribution_tests),sync_outbound_test({front}),sync_explicit_close_test({front})',folder/'target.log')
    row['node_exit_before_cleanup']=node.poll()
    # Graceful proxy shutdown saves connection metadata after both pumps stop.
    stop(proxy);stop(node)
   except Exception as e:row['harness_error']=repr(e)
   finally:
    for p in reversed(procs):stop(p)
    for log in logs:log.close()
   streams=[wire.analyze(f,f.name.endswith('c2s.bin'))for f in sorted((folder/'wire').glob('*.bin'))]
   (folder/'wire-analysis.json').write_text(json.dumps(streams,indent=2)+'\n');row['wire_errors']=[{'stream':s['file'],**e}for s in streams for e in s.get('errors',[])];row['incomplete_tails']=[{'stream':s['file'],**s['tail']}for s in streams if s.get('tail')];row['utf8_warning']='Illegal UTF-8' in (folder/'swi-node.log').read_text()
   ROWS.append(row);(OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(label,row.get('target',{}).get('exit_code'),'wire_errors',len(row['wire_errors']),'utf8_warning',row['utf8_warning'],row.get('harness_error',''),flush=True)
AFTER=state();AFTER['unchanged_from_batch_start']={k:AFTER[k]==BEFORE[k]for k in BEFORE};(OUT/'after.json').write_text(json.dumps(AFTER,indent=2)+'\n');print('COMPLETE',len(ROWS),flush=True)
