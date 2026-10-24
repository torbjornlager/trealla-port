from pathlib import Path
import json,os,signal,subprocess,time,tempfile,shutil
ROOT=Path(__file__).resolve().parents[2];OUT=Path(__file__).resolve().parent
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
ENV=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'));ROWS=[]
def run(label,file,goal,cwd=ROOT,expected=0):
 command=[str(ENGINE/'tpl'),'-g',f"consult('{file}'),(catch(({goal}),E,(writeq(E),nl,fail))->halt;halt(1))"]
 start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(command,cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:code=p.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();code=124
 ROWS.append(dict(label=label,command=command,exit_code=code,expected=expected,seconds=round(time.monotonic()-start,3),passed=code==expected))
 (OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(label,code,flush=True)
run('callback-context','promise_callback_context_tests.pl','promise_callback_context_tests:run')
for label,file,goal in [('promise-correctness','rpc_promise_tests.pl','rpc_promise_tests'),('client-options','rpc_option_tests.pl','rpc_option_tests'),('promise-lifecycle','rpc_lifecycle_tests.pl','rpc_lifecycle_tests'),('promise-ownership','rpc_ownership_tests.pl','rpc_ownership_tests'),('synchronous-waits','synchronous_toplevel_tests.pl','synchronous_toplevel_tests:run')]:run(label,file,goal)
for group in ['isolation','profiles','sandbox']:run(group,'tests.pl',f'run_test_group({group})')
# Negative control is a disposable copy with only the two production changes
# restored to HEAD. Installed runtimes and the current checkout stay untouched.
with tempfile.TemporaryDirectory(prefix='promise-callback-negative-') as tmp:
 d=Path(tmp)
 for f in ROOT.glob('*.pl'):shutil.copy2(f,d/f.name)
 for name in ['rpc.pl','sandbox_policy.pl']:(d/name).write_bytes(subprocess.check_output(['git','show','HEAD:'+name],cwd=ROOT))
 run('original-negative-control','web_prolog.pl',"use_module(distribution),actors:make_ref(R),rpc:promise_transaction(rpc:new_promise_state(R,_)),actors:self(S),catch(rpc:yield(R,A,[timeout(0),on_timeout(('!'(S,probe),A=waiting))]),Error,true),rpc:promise_cleanup(R),writeq(Error),nl,(nonvar(Error)->throw(Error);true)",cwd=d,expected=1)
 text=(OUT/'original-negative-control.log').read_text()
 if 'existence_error(procedure' not in text or '!' not in text:raise RuntimeError('negative control did not reproduce the callback error')
if not all(r['passed'] for r in ROWS):raise SystemExit(1)
