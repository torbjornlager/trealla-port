#!/usr/bin/env python3
"""Fixed fresh-process lifecycle batches; watchdogs and diagnostics stay test-only."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine',action='append',required=True);p.add_argument('--runs',type=int,default=30);p.add_argument('--output',type=Path,required=True);p.add_argument('--goal',default="consult('rpc_lifecycle_tests.pl'),(lifecycle_diagnostic_tests->halt;halt(1))");p.add_argument('--timeout',type=float,default=15);a=p.parse_args()
r={'runs':a.runs,'timeout_seconds':a.timeout,'goal':a.goal,'engines':{},'results':[]}
for spec in a.engine:
 label,path=spec.split('=',1);exe=Path(path).resolve();r['engines'][label]={'path':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}
 env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
 for trial in range(1,a.runs+1):
  t=time.monotonic()
  try:
   c=subprocess.run([str(exe),'-g',a.goal],env=env,text=True,capture_output=True,timeout=a.timeout)
   row={'engine':label,'trial':trial,'exit_code':c.returncode,'stdout':c.stdout,'stderr':c.stderr,'passed':c.returncode==0 and 'all regressions passed' in c.stdout and not c.stderr}
  except subprocess.TimeoutExpired as e:
   def dec(v):return v.decode(errors='replace') if isinstance(v,bytes) else v or ''
   row={'engine':label,'trial':trial,'timeout':True,'passed':False,'stdout':dec(e.stdout),'stderr':dec(e.stderr)}
  row['seconds']=round(time.monotonic()-t,3);row['last_stage']=next((x for x in reversed(row['stdout'].splitlines()) if x.startswith('stage(')),None)
  if row['passed']:
   out=row.pop('stdout');row['stdout_sha256']=hashlib.sha256(out.encode()).hexdigest();row['stdout_lines']=len(out.splitlines());row['stdout_tail']='\n'.join(out.splitlines()[-6:])+'\n';row['success_trace_compacted']=True
  r['results'].append(row);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(r,indent=2)+'\n')
  print(label,trial,'PASS' if row['passed'] else 'FAIL',row.get('exit_code'),row['last_stage'],flush=True)
