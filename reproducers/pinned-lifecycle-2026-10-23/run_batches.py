#!/usr/bin/env python3
"""Bounded fresh-process diagnostics, sampling a stall before killing only that test."""
import argparse,hashlib,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--engine',action='append',required=True);p.add_argument('--case',required=True);p.add_argument('--iterations',type=int,default=10);p.add_argument('--runs',type=int,default=30);p.add_argument('--timeout',type=float,default=12);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
assert a.case in ['hard_cancel','delivery','full','standalone_minimal','standalone_concurrent','standalone_unlock_all']
if a.case=='standalone_unlock_all':
 # Exit-time mutex release under contention; primitives only.
 goal="consult('reproducers/pinned-lifecycle-2026-10-23/unlock_all_probe.pl'),"
 call=f"unlock_all_probe({a.iterations})"
elif a.case.startswith('standalone_'):
 # No Web Prolog source: only the primitives-only probe is consulted.
 goal="consult('reproducers/pinned-lifecycle-2026-10-23/standalone_cancel_probe.pl'),"
 call=f"standalone_cancel({a.case.split('_',1)[1]},{a.iterations})"
else:
 goal="consult('rpc_lifecycle_tests.pl'),consult('reproducers/pinned-lifecycle-2026-10-23/driver.pl'),"
 call='lifecycle_diagnostic_tests' if a.case=='full' else f'focused_lifecycle({a.case},{a.iterations})'
goal+=f"catch(({call}->halt;throw(test_goal_failed)),E,(writeq(test_exception(E)),nl,flush_output,halt(1)))"
r={'case':a.case,'iterations':a.iterations,'runs':a.runs,'timeout_seconds':a.timeout,'goal':goal,'engines':{},'results':[]}
a.output.parent.mkdir(parents=True,exist_ok=True)
for spec in a.engine:
 label,path=spec.split('=',1);exe=Path(path).resolve();r['engines'][label]={'path':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}
 env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
 for trial in range(1,a.runs+1):
  start=time.monotonic();c=subprocess.Popen([str(exe),'-g',goal],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  row={'engine':label,'trial':trial,'pid':c.pid}
  try:out,err=c.communicate(timeout=a.timeout)
  except subprocess.TimeoutExpired:
   row['timeout']=True
   sample=a.output.parent/f'{a.case}-{label}-{trial}-sample.txt'
   try:
    s=subprocess.run(['/usr/bin/sample',str(c.pid),'1','1','-file',str(sample)],capture_output=True,text=True,timeout=4)
    row['sample_exit_code']=s.returncode;row['sample_file']=sample.name if sample.exists() else None
   except subprocess.TimeoutExpired:row['sample_timeout']=True
   c.kill();out,err=c.communicate(timeout=3)
  row.update(exit_code=c.returncode,seconds=round(time.monotonic()-start,3),stderr=err)
  row['passed']=not row.get('timeout') and c.returncode==0 and 'all regressions passed' in out and not err
  row['last_stage']=next((x for x in reversed(out.splitlines()) if x.startswith('stage(')),None)
  row['stdout_sha256']=hashlib.sha256(out.encode()).hexdigest();row['stdout_lines']=len(out.splitlines())
  row['stdout_tail']='\n'.join(out.splitlines()[-8:])+'\n'
  if not row['passed']:row['stdout']=out
  r['results'].append(row);a.output.write_text(json.dumps(r,indent=2)+'\n')
  print(label,trial,'PASS' if row['passed'] else 'FAIL',row['exit_code'],row['last_stage'],flush=True)
