from pathlib import Path
import os,subprocess,tempfile,shutil,json,signal,time
ROOT=Path(__file__).resolve().parents[2];OUT=Path(__file__).resolve().parent;ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
env=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'));rows=[]
def run(label,cwd):
 cmd=[str(ENGINE/'tpl'),'-g',"consult('tests.pl'),(catch(run_test_group(sandbox),E,(writeq(E),nl,fail))->halt;halt(1))"]
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
 rows.append(dict(label=label,command=cmd,exit_code=rc));print(label,rc,flush=True)
with tempfile.TemporaryDirectory(prefix='callback-sandbox-control-') as temp:
 d=Path(temp)
 for f in ROOT.glob('*.pl'):shutil.copy2(f,d/f.name)
 for name in ['rpc.pl','sandbox_policy.pl','isolation.pl']:(d/name).write_bytes(subprocess.check_output(['git','show','HEAD:'+name],cwd=ROOT))
 run('sandbox-original-control',d)
run('sandbox-repaired-control',ROOT)
(OUT/'sandbox-controls.json').write_text(json.dumps(rows,indent=2)+'\n')
