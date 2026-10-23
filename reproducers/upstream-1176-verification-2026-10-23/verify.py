#!/usr/bin/env python3
"""Bounded #1176 checks against an explicitly selected, unmodified engine."""
import argparse,hashlib,json,os,subprocess,tempfile,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2];here=Path(__file__).resolve().parent;engine=a.engine.resolve();base=engine.parent
q=lambda s:"'"+str(s).replace("'","''")+"'"
shim_dir=tempfile.TemporaryDirectory(prefix='trinity-1176-timeout-')
shim=Path(shim_dir.name)/'timeout'
shutil.copyfile(root/'reproducers/unlock-all-independent-verification-2026-10-23/timeout-shim.py',shim);shim.chmod(0o755)
env=dict(os.environ,TPL_LIBRARY_PATH=str(base/'library'),PATH=shim_dir.name+':'+os.environ['PATH'])
r={'engine':str(engine),'sha256':hashlib.sha256(engine.read_bytes()).hexdigest(),'results':[]}
def run(name,cmd,expected=None,marker=None,runs=1,cwd=root,check=None):
 for i in range(1,runs+1):
  try:
   c=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=65)
   ok=c.returncode==0 and not c.stderr
   if expected is not None:ok=ok and c.stdout==expected
   if marker:ok=ok and marker in c.stdout
   if check:ok=ok and check(c.stdout)
   row=dict(test=name,trial=i,exit_code=c.returncode,stdout=c.stdout,stderr=c.stderr,passed=ok)
  except subprocess.TimeoutExpired as e:
   dec=lambda v:v.decode(errors='replace') if isinstance(v,bytes) else v or ''
   row=dict(test=name,trial=i,timeout=True,stdout=dec(e.stdout),stderr=dec(e.stderr),passed=False)
  r['results'].append(row);a.output.write_text(json.dumps(r,indent=2)+'\n');print(name,i,row['passed'],flush=True)
def goal(s):return [str(engine),'-g',f"catch(({s}->halt;halt(1)),E,(writeq(E),nl,halt(1)))"]
for kind in ['full','selective','reexport','thread']:
 run('variant_'+kind,goal(f"consult({q(here/'import-variants.pl')}),import_variant({kind},{q(root/'reproducers/port-promise-callback-hang-2026-10-22/state-library.pl')})"),marker='all assertions passed',runs=5)
for file in ['actors.pl','rpc.pl']:
 def equal_tables(out):
  before=[x.removeprefix('stage(tables(before,') for x in out.splitlines() if x.startswith('stage(tables(before,')]
  after=[x.removeprefix('stage(tables(after,') for x in out.splitlines() if x.startswith('stage(tables(after,')]
  return len(before)==len(after)==1 and before==after and '[]' not in before[0]
 run('framework_table_'+file,goal(f"consult('reproducers/port-promise-callback-hang-2026-10-22/staged.pl'),import_tables({q(root/file)})"),runs=5,check=equal_tables)
run('promise_correctness',goal("consult('rpc_promise_tests.pl'),rpc_promise_tests"),marker='Promise/yield correctness: all regressions passed')
for name in ['use_module_state','reconsult_module','make_module_state','make_same_second','make_failed_load','runtime_consult_base']:
 f=base/'tests/sundry'/f'{name}.sh'
 run('engine_'+name,['sh',str(f)],expected=f.with_suffix('.expected').read_text(),runs=5 if name=='use_module_state' else 1,cwd=base)
