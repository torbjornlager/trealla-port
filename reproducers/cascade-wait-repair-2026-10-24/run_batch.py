"""Apply only the test repair to explicit runtime revisions in disposable trees."""
from pathlib import Path
import json,hashlib,os,subprocess,signal,tempfile,time
ROOT=Path(__file__).resolve().parents[2];HERE=Path(__file__).resolve().parent
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
COMMITS={'original':'c472ecb9f1a30d80558d105a980be34c73014fe4','repaired':'bf47aac87d899b80da05c320f43dbe8aa438e068'}
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args])
def preserve():
 before=json.loads((HERE/'before-edit.json').read_text())
 refs=Path(ROOT.parent/'trinity-demonstrator/docs/verification/swi-pinned-ci-2026-10-24/before.json')
 installed=json.loads(refs.read_text())['binaries']
 return dict(runtime={p:sha(ROOT/p) for p in before['runtime']},
  installed={str(p):dict(target=str(Path(p).resolve()),sha256=sha(p)) for p in installed},
  live=subprocess.check_output(['ps','-p','7072,42134,97669,97896','-o','pid,lstart,command'],text=True),
  engine=sha(ENGINE/'tpl'),library={str(p.relative_to(ENGINE/'library')):sha(p) for p in (ENGINE/'library').rglob('*') if p.is_file()})
def main():
 out=HERE/'fixed';out.mkdir(exist_ok=False);before=preserve();rows=[];env=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'))
 for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_CONFIG_FILE','WP_NATIVE_MODE','WP_NATIVE_STATE']:env.pop(key,None)
 provenance=dict(commits=COMMITS,engine=str(ENGINE/'tpl'),engine_revision=subprocess.check_output(['git','-C',str(ENGINE),'rev-parse','HEAD'],text=True).strip(),test_sha256=sha(ROOT/'tests.pl'),cleanup_control_sha256=sha(HERE/'monitor_scope_tests.pl'),sources={},watchdog_seconds=30,rows=rows)
 try:
  with tempfile.TemporaryDirectory(prefix='cascade-wait-repair-') as temp:
   roots={}
   for label,commit in COMMITS.items():
    d=Path(temp)/label;d.mkdir();roots[label]=d
    files=[p for p in git('ls-tree','--name-only',commit).decode().splitlines() if p.endswith('.pl')]
    for f in files:(d/f).write_bytes(git('show',commit+':'+f))
    (d/'tests.pl').write_bytes((ROOT/'tests.pl').read_bytes())
    (d/'monitor_scope_tests.pl').write_bytes((HERE/'monitor_scope_tests.pl').read_bytes())
    provenance['sources'][label]={f:sha(d/f) for f in files}
    for f in files:
     if f!='tests.pl':assert (d/f).read_bytes()==git('show',commit+':'+f)
   for mode,count,goal in [('isolated',20,"consult('tests.pl'),t145"),('sandbox',3,"consult('tests.pl'),run_test_group(sandbox)"),('cleanup',1,"consult('monitor_scope_tests.pl'),monitor_scope_tests")]:
    for trial in range(1,count+1):
     for label,d in roots.items():
      name=f'{mode}-{label}-{trial:02d}';cmd=[str(ENGINE/'tpl'),'-g',f'(catch(({goal}),E,(writeq(E),nl,fail))->halt;halt(1))'];start=time.monotonic()
      with (out/(name+'.log')).open('w') as log:
       p=subprocess.Popen(cmd,cwd=d,env=env,stdout=log,stderr=log,start_new_session=True)
       try:rc=p.wait(timeout=30)
       except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
      rows.append(dict(name=name,mode=mode,source=label,trial=trial,command=cmd,exit_code=rc,seconds=round(time.monotonic()-start,3)));print(name,rc,flush=True)
      (out/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
 finally:
  after=preserve();checks={k:before[k]==after[k] for k in before}
  original=json.loads((HERE/'before-edit.json').read_text());checks['runtime_equals_before_edit']=before['runtime']==original['runtime']
  (out/'preservation.json').write_text(json.dumps(dict(checks=checks,before=before,after=after),indent=2)+'\n');(out/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
 if not all(checks.values()) or any(r['exit_code']!=0 for r in rows):raise SystemExit(1)
if __name__=='__main__':main()
