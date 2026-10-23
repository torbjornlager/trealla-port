#!/usr/bin/env python3
"""Fixed fresh-process worker-scope batches; preserve every failure and log."""
import argparse,hashlib,json,os,signal,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine',action='append',required=True,help='LABEL=/path/to/tpl');p.add_argument('--runs',type=int,default=30);p.add_argument('--diagnostics',action='store_true');p.add_argument('--failure-diagnostics',action='store_true');p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2];a.output.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
result={'runs_per_engine':a.runs,'diagnostics':a.diagnostics,'failure_diagnostics':a.failure_diagnostics,'test_sha256':sha(root/'worker_scope_tests.pl'),'runtime_sha256':{f:sha(root/f) for f in ['actors.pl','parallel.pl','worker_cleanup.pl','isolation.pl']},'engines':{}}
for spec in a.engine:
 label,path=spec.split('=',1);exe=Path(path).resolve();env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
 env['WORKER_SCOPE_DIAGNOSTICS']='failure' if a.failure_diagnostics else '1' if a.diagnostics else '0'
 data={'executable':str(exe),'sha256':sha(exe),'library':env['TPL_LIBRARY_PATH'],'results':[]};result['engines'][label]=data
 for trial in range(1,a.runs+1):
  goal="(catch((consult('worker_scope_tests.pl'),worker_scope_tests:run),E,(writeq(E),nl,fail))->halt;halt(1))";cmd=[str(exe),'-g',goal];start=time.monotonic()
  proc=subprocess.Popen(cmd,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  timeout=False
  try:out,err=proc.communicate(timeout=20)
  except subprocess.TimeoutExpired:
   timeout=True;os.killpg(proc.pid,signal.SIGKILL);out,err=proc.communicate()
  (a.output/f'{label}-{trial:02d}.stdout').write_text(out)
  row=dict(trial=trial,exit_code=proc.returncode,timeout=timeout,seconds=round(time.monotonic()-start,3),passed=proc.returncode==0 and not err and 'Worker scopes: all regressions passed\n' in out,stdout=f'{label}-{trial:02d}.stdout',stderr_text=err,missing_unrelated='missing_unrelated' in out,command=cmd)
  data['results'].append(row);(a.output/'results.json').write_text(json.dumps(result,indent=2)+'\n')
  print(label,trial,'PASS' if row['passed'] else 'FAIL',row['exit_code'],out.splitlines()[-1:] if not row['passed'] else '',flush=True)
print('Summary:',{k:sum(x['passed'] for x in v['results']) for k,v in result['engines'].items()},flush=True)
