"""Test-only fixed, explicit-commit comparison; never edits a runtime checkout."""
from pathlib import Path
import argparse,hashlib,json,os,signal,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
COMMITS={'original':'c472ecb9f1a30d80558d105a980be34c73014fe4',
         'repaired':'bf47aac87d899b80da05c320f43dbe8aa438e068'}
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args])
def preserve():
 files=git('ls-files','-z').decode().split('\0')
 tracked={f:sha(ROOT/f) for f in files if f and (ROOT/f).is_file()}
 executables=[Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl',ROOT/'.build/trealla-current/tpl',ENGINE/'tpl']
 return dict(tracked=tracked,engines={str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in executables},
             live=subprocess.check_output(['ps','-p','7072,42134,97669,97896','-o','pid,lstart,command'],text=True),
             library={str(p.relative_to(ENGINE/'library')):sha(p) for p in (ENGINE/'library').rglob('*') if p.is_file()},
             status=git('status','--short').decode())
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);parser.add_argument('--pilot',action='store_true');a=parser.parse_args()
 a.output.mkdir(parents=True,exist_ok=False);rows=[];before=preserve()
 env=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'))
 for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_CONFIG_FILE','WP_NATIVE_MODE','WP_NATIVE_STATE']:env.pop(key,None)
 provenance=dict(commits=COMMITS,engine=str(ENGINE/'tpl'),engine_revision=subprocess.check_output(['git','-C',str(ENGINE),'rev-parse','HEAD'],text=True).strip(),probe_sha256=sha(HERE/'cascade_probe.pl'),watchdog_seconds=30,rows=rows,inputs={})
 try:
  with tempfile.TemporaryDirectory(prefix='cascade-stages-') as temp:
   roots={}
   for label,commit in COMMITS.items():
    d=Path(temp)/label;d.mkdir();roots[label]=d
    paths=git('ls-tree','--name-only',commit).decode().splitlines()
    paths=[p for p in paths if p.endswith('.pl')]
    for f in paths:(d/f).write_bytes(git('show',commit+':'+f))
    (d/'cascade_probe.pl').write_bytes((HERE/'cascade_probe.pl').read_bytes())
    provenance['inputs'][label]={f:sha(d/f) for f in paths}
   assert provenance['inputs']['original']['tests.pl']==provenance['inputs']['repaired']['tests.pl'],'original assertion fixture differs'
   modes=[('observed',1)] if a.pilot else [('baseline',5),('observed',10)]
   for mode,count in modes:
    for trial in range(1,count+1):
     for label,d in roots.items():
      name=f'{mode}-{label}-{trial:02d}'
      goal="consult('tests.pl'),t145" if mode=='baseline' else "consult('cascade_probe.pl'),probe"
      command=[str(ENGINE/'tpl'),'-g',f'(catch(({goal}),E,(writeq(E),nl,fail))->halt;halt(1))']
      started=time.monotonic()
      with (a.output/(name+'.log')).open('w') as log:
       p=subprocess.Popen(command,cwd=d,env=env,stdout=log,stderr=log,start_new_session=True)
       try:rc=p.wait(timeout=30)
       except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
      row=dict(name=name,mode=mode,source=label,commit=COMMITS[label],trial=trial,exit_code=rc,seconds=round(time.monotonic()-started,3),command=command)
      rows.append(row);(a.output/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,rc,flush=True)
 finally:
  after=preserve();checks={k:before[k]==after[k] for k in before}
  (a.output/'preservation.json').write_text(json.dumps(dict(checks=checks,before=before,after=after),indent=2)+'\n')
  (a.output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
 if not all(checks.values()):raise SystemExit('preservation failure')
if __name__=='__main__':main()
