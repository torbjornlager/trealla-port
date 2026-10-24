from pathlib import Path
import os,subprocess,tempfile,shutil,json,time,signal
ROOT=Path(__file__).resolve().parents[2];OUT=Path(__file__).resolve().parent;ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine';env=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'));rows=[]
with tempfile.TemporaryDirectory(prefix='callback-cascade-control-') as tmp:
 for name in ['original','repaired']:
  d=Path(tmp)/name;d.mkdir()
  for f in ROOT.glob('*.pl'):shutil.copy2(f,d/f.name)
  if name=='original':
   for f in ['rpc.pl','sandbox_policy.pl','isolation.pl']:(d/f).write_bytes(subprocess.check_output(['git','show','HEAD:'+f],cwd=ROOT))
  for i in range(5):
   label=f'cascade-{name}-{i+1}'
   cmd=[str(ENGINE/'tpl'),'-g',"consult('tests.pl'),(catch(t145,E,(writeq(E),nl,fail))->halt;halt(1))"]
   with (OUT/(label+'.log')).open('w') as log:
    p=subprocess.Popen(cmd,cwd=d,env=env,stdout=log,stderr=log,start_new_session=True)
    try:rc=p.wait(timeout=30)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
   rows.append(dict(label=label,exit_code=rc,command=cmd));print(label,rc,flush=True)
(OUT/'cascade-batch.json').write_text(json.dumps(rows,indent=2)+'\n')
